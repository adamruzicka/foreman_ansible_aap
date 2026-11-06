# frozen_string_literal: true

require 'test_plugin_helper'

module Api
  module V2
    class ForemanAnsibleAapJobInvocationsControllerTest < ActionController::TestCase
      tests JobInvocationsController

      setup do
        @invocation = FactoryBot.create(:job_invocation, :with_template, :with_task, :with_unplanned_host)
        @invocation.update!(ansible_execution_driver: 'aap')
        @execution = ForemanAnsibleAap::Execution.create!(
          job_invocation: @invocation,
          aap_job_id: 91,
          aap_job_url: 'https://aap.example.test/api/controller/v2/jobs/91/',
          event_diagnostics: [{
            'external_id' => 'aap-job-91-event-7',
            'output' => 'unmapped AAP output',
            'timestamp' => '2026-10-30T09:00:00Z',
          }],
          output_incomplete: true,
          output_failure_diagnostic: 'AAP output page 2 was unavailable'
        )
      end

      test 'authorized invocation detail includes persisted AAP diagnostics' do
        get :show, params: { id: @invocation.id, include_hosts: false }

        assert_response :success
        assert_equal({
          'job_id' => 91,
          'job_url' => 'https://aap.example.test/api/controller/v2/jobs/91/',
          'limitations' =>
            'Host-filtered cancellation and peripheral task-based integrations are not supported for AAP jobs.',
          'invocation_diagnostics' => [{
            'external_id' => 'aap-job-91-event-7',
            'output' => 'unmapped AAP output',
            'timestamp' => '2026-10-30T09:00:00Z',
          }],
          'output_incomplete' => true,
          'output_failure_diagnostic' => 'AAP output page 2 was unavailable',
        }, response.parsed_body.fetch('aap'))
      end

      test 'AAP diagnostics are protected by Job Invocation authorization' do
        user = FactoryBot.create(:user, admin: false)
        setup_user('view', 'job_invocations', 'user = current_user', user)

        get :show, params: { id: @invocation.id }, session: prepare_user(user)

        assert_response :not_found
        assert_not_includes response.body, @execution.aap_job_url
        assert_not_includes response.body, 'unmapped AAP output'
      end

      test 'host-filtered AAP cancellation is rejected without cancelling any task' do
        @invocation.task.expects(:cancel).never
        @invocation.task.expects(:abort).never

        post :cancel, params: { id: @invocation.id, search: 'name ~ example.test' }

        assert_response :unprocessable_entity
        assert_includes response.parsed_body.dig('error', 'message'), 'single aggregate AAP job'
      end

      test 'whole AAP cancellation continues through the existing Job Invocation interface' do
        @invocation.task.expects(:cancellable?).returns(true)
        @invocation.task.expects(:cancel).returns(true)
        JobInvocation.expects(:from_param).with(@invocation.id.to_s).returns(@invocation)

        post :cancel, params: { id: @invocation.id }

        assert_response :success
        assert response.parsed_body.fetch('cancelled')
      end

      test 'AAP host output and progress remain available through existing API fields' do
        host = @invocation.template_invocations.first.host
        @invocation.targeting.hosts << host unless @invocation.targeting.hosts.exists?(host.id)
        live_output = [{
          'output_type' => 'stdout',
          'output' => 'persisted AAP output',
          'timestamp' => Time.zone.parse('2026-10-30T09:00:00Z').to_f,
        }]
        ForemanTasks::Task.any_instance.stubs(:scheduled?).returns(false)
        ForemanTasks::Task.any_instance.stubs(:pending?).returns(false)
        ForemanTasks::Task.any_instance.stubs(:main_action).returns(stub(live_output: live_output))

        get :output, params: { job_invocation_id: @invocation.id, host_id: host.id }

        assert_response :success
        assert_equal live_output, response.parsed_body.fetch('output')
        assert response.parsed_body.fetch('complete')

        get :show, params: { id: @invocation.id, include_hosts: false }
        %w[succeeded failed pending cancelled].each do |field|
          assert response.parsed_body.key?(field), "expected progress field #{field}"
        end
      end

      test 'AAP creation rejects unsupported proxy options before triggering work' do
        template = FactoryBot.create(:job_template, provider_type: 'Ansible')
        old_driver = Setting[:ansible_execution_driver]
        Setting[:ansible_execution_driver] = 'aap'
        ForemanTasks.expects(:trigger).never

        post :create, params: {
          job_invocation: {
            job_category: template.job_category,
            job_template_id: template.id,
            targeting_type: 'static_query',
            search_query: 'name ~ example.test',
            ssh_user: 'proxy-managed-user',
            execution_timeout_interval: 30,
          },
        }

        assert_response :unprocessable_entity
        assert_includes response.parsed_body.dig('error', 'message'), 'SSH user'
        assert_includes response.parsed_body.dig('error', 'message'), 'Execution timeout'
      ensure
        Setting[:ansible_execution_driver] = old_driver
      end

      private

      def prepare_user(user)
        User.current = user
        set_session_user(user)
      end
    end
  end
end
