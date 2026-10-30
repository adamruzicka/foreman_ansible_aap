# frozen_string_literal: true

require 'test_plugin_helper'
require 'foreman_tasks/test_helpers'

module ForemanAnsibleAap
  class RunHostsJobPreparationIntegrationTest < ActiveSupport::TestCase
    include ForemanTasks::TestHelpers::WithInThreadExecutor

    setup do
      User.current = users(:admin)
    end

    test 'complete preparation success runs one aggregate job and succeeds every host task' do
      hosts = [FactoryBot.create(:host), FactoryBot.create(:host)]
      invocation = build_invocation(hosts)
      launches = stub_successful_external_work(hosts)

      task = trigger(invocation)

      assert_equal 'success', task.result
      assert_equal %w[success success], invocation.reload.template_invocation_tasks.order(:id).pluck(:result)
      assert_equal 1, launches.size
      assert_equal hosts.map(&:name).join(','), launches.first.fetch(:limit)
      execution = Execution.find_by!(job_invocation: invocation)
      assert_equal 1, execution.aap_job_id
      host_inputs = execution.host_executions.map do |record|
        record.template_invocation.input_values.pluck(:value)
      end
      assert_equal [%w[httpd], %w[httpd]], host_inputs
    end

    test 'a permission failure stays on its host while the prepared subset launches' do
      prepared_host = FactoryBot.create(:host)
      denied_host = FactoryBot.create(:host, :with_infrastructure_facet)
      setup_user('view', 'hosts')
      setup_user('view', 'job_templates')
      setup_user('create', 'template_invocations')
      invocation = build_invocation([prepared_host, denied_host])
      launches = stub_successful_external_work([prepared_host])

      trigger(invocation)

      records = Execution.find_by!(job_invocation: invocation).host_executions.index_by(&:host_id)
      assert_equal 'successful', records.fetch(prepared_host.id).result_state
      assert_equal 'failed', records.fetch(denied_host.id).preparation_state
      assert_includes records.fetch(denied_host.id).preparation_error, 'infrastructure host'
      assert_equal prepared_host.name, launches.first.fetch(:limit)
      assert_equal 'success', invocation.sub_task_for_host(prepared_host).result
      assert_equal 'error', invocation.sub_task_for_host(denied_host).result
    end

    test 'zero prepared hosts perform no aggregate work' do
      hosts = [FactoryBot.create(:host), FactoryBot.create(:host)]
      setup_user('view', 'job_templates')
      setup_user('create', 'template_invocations')
      invocation = build_invocation(hosts)
      Configuration.expects(:from_settings).never
      PlaybookRenderer.any_instance.expects(:render).never
      GitPublisher.any_instance.expects(:publish).never
      AapClient.any_instance.expects(:preflight!).never
      AapClient.any_instance.expects(:launch).never

      trigger(invocation)

      execution = Execution.find_by!(job_invocation: invocation)
      assert_equal 'skipped', execution.aggregate_state
      assert_nil execution.aap_job_id
      assert(execution.host_executions.all? { |record| record.preparation_state == 'failed' })
      assert_equal %w[error error], (hosts.map { |host| invocation.sub_task_for_host(host).result })
    end

    test 'host-context rendering failure fails every prepared host with one shared error' do
      hosts = [FactoryBot.create(:host), FactoryBot.create(:host)]
      invocation = build_invocation(hosts)
      Configuration.stubs(:from_settings).returns(configuration)
      AapClient.any_instance.expects(:preflight!).once
      PlaybookRenderer.any_instance.expects(:render).once.raises(
        PlaybookRenderer::RenderingError,
        'Failed rendering template without a current host: @host is unavailable'
      )
      GitPublisher.any_instance.expects(:publish).never
      AapClient.any_instance.expects(:launch).never

      trigger(invocation)

      execution = Execution.find_by!(job_invocation: invocation)
      assert_equal 'failed', execution.aggregate_state
      assert_includes execution.aggregate_error, 'without a current host'
      assert(execution.host_executions.all? { |record| record.result_state == 'failed' })
      assert(execution.host_executions.all? { |record| record.result_error == execution.aggregate_error })
      assert_equal %w[error error], (hosts.map { |host| invocation.sub_task_for_host(host).result })
    end

    private

    def trigger(invocation)
      triggered = ForemanTasks.trigger(Actions::ForemanAnsibleAap::RunHostsJob, invocation)
      raise triggered.error if triggered.respond_to?(:error)

      triggered.finished.wait(20)
      ForemanTasks::Task.find_by!(external_id: triggered.id)
    end

    def build_invocation(hosts)
      executor = User.current
      as_admin do
        targeting = FactoryBot.create(:targeting, user: executor)
        targeting.mark_resolved!
        targeting.save!(validate: false)
        targeting.hosts << hosts
        template = FactoryBot.build(
          :job_template,
          provider_type: 'Ansible',
          template: "---\n- hosts: all\n  tasks:\n    - debug: msg=<%= input('service') %>\n"
        )
        template.template_inputs << FactoryBot.build(
          :template_input,
          name: 'service',
          input_type: 'user'
        )
        template.save!
        template.then do
          FactoryBot.build(:job_invocation, targeting: targeting).tap do |invocation|
            invocation.description = 'AAP preparation integration'
            pattern = FactoryBot.build(
              :template_invocation,
              template: template
            )
            pattern.input_values << FactoryBot.build(
              :template_invocation_input_value,
              template_input: template.template_inputs.first,
              value: 'httpd'
            )
            invocation.pattern_template_invocations << pattern
            invocation.save!
          end
        end
      end
    end

    def stub_successful_external_work(hosts)
      launches = []
      Configuration.stubs(:from_settings).returns(configuration)
      PlaybookRenderer.any_instance.expects(:render).once.returns("---\n- hosts: all\n")
      GitPublisher.any_instance.expects(:publish).once.returns('a' * 40)
      AapClient.any_instance.expects(:preflight!).once
      AapClient.any_instance.expects(:launch).once.with do |attributes|
        launches << attributes
        true
      end.returns(id: 1, url: 'https://aap.example.test/jobs/1/')
      AapClient.any_instance.expects(:job_status).once.with(1).returns('successful')
      AapClient.any_instance.expects(:job_events).once.with(1, after_id: nil).returns([])
      AapClient.any_instance.expects(:host_summaries).once.with(1).returns(
        hosts.map { |host| { host_name: host.name, successful: true } }
      )
      launches
    end

    def configuration
      Configuration.new(
        controller_url: 'https://aap.example.test',
        service_token: 'controller-secret',
        ca_bundle: nil,
        job_template_id: 7,
        inventory_id: 8,
        project_id: 9,
        repository_url: 'https://git.example.test/generated.git',
        base_ref: 'main',
        playbook_path: 'generated/foreman.yml',
        instance_id: 'foreman-test',
        git_username: 'foreman',
        git_password: 'git-secret'
      )
    end
  end
end
