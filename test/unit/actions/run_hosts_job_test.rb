# frozen_string_literal: true

require 'test_plugin_helper'

module ForemanAnsibleAap
  class RunHostsJobTest < ActiveSupport::TestCase
    let(:hosts) { [stub(id: 1), stub(id: 2)] }
    let(:targeting) { stub(resolved?: true) }
    let(:job_invocation) do
      stub(
        id: 42,
        task_group: nil,
        targeting: targeting,
        job_category: 'Ansible Commands',
        description: 'Run Ansible'
      ).tap do |invocation|
        invocation.stubs(:task_id).returns(nil)
        invocation.stubs(:task_id=)
        invocation.stubs(:save!)
      end
    end
    let(:action) { Actions::ForemanAnsibleAap::RunHostsJob.allocate }

    test 'does not apply Foreman concurrency control while planning' do
      action.stubs(:task).returns(stub(add_missing_task_groups: nil))
      action.expects(:action_subject).with(job_invocation)
      action.expects(:plan_self).with(job_invocation_id: job_invocation.id)
      action.expects(:limit_concurrency_level!).never

      action.plan(job_invocation)
    end

    test 'plans every lightweight host task in one unbounded batch' do
      action.stubs(:hosts).returns(hosts)
      action.stubs(:current_batch).returns(hosts)
      action.stubs(:job_invocation).returns(job_invocation)
      execution_record = stub('execution record')
      action.stubs(:execution_record).returns(execution_record)
      template_invocation = stub(new_record?: true)
      job_invocation.stubs(:pattern_template_invocation_for_host)
                    .returns(stub(deep_clone: template_invocation))

      assert_equal 2, action.batch_size
      action.expects(:trigger).with do |action_class, invocation, host, planned_invocation, planned_execution|
        action_class == Actions::ForemanAnsibleAap::RunHostJob &&
          invocation == job_invocation &&
          hosts.include?(host) &&
          planned_invocation.new_record? &&
          execution_record == planned_execution
      end.twice

      assert_equal 2, action.create_sub_plans.size
    end

    test 'links each lightweight host task to its template invocation' do
      host = hosts.first
      template_invocation = mock('template invocation')
      template_invocation.expects(:host_id=).with(host.id)
      template_invocation.expects(:run_host_job_task_id=).with(7)
      template_invocation.expects(:save!)
      host_action = Actions::ForemanAnsibleAap::RunHostJob.allocate
      host_action.stubs(:task).returns(stub(id: 7))
      host_action.expects(:action_subject).with(
        host,
        job_category: job_invocation.job_category,
        description: job_invocation.description,
        job_invocation_id: job_invocation.id
      )
      host_action.expects(:link!).with(job_invocation)
      host_action.expects(:link!).with(template_invocation)
      execution_record = stub('execution record')
      host_execution = stub(id: 11)
      ::ForemanAnsibleAap::HostExecution.expects(:create!).with(
        execution: execution_record,
        host: host,
        template_invocation: template_invocation
      ).returns(host_execution)
      host_action.expects(:plan_self).with(host_execution_id: 11)

      host_action.plan(job_invocation, host, template_invocation, execution_record)
    end

    test 'exposes persisted AAP output through the host task live output interface' do
      raw_output = {
        'output_type' => 'stdout',
        'output' => 'live from AAP',
        'timestamp' => Time.zone.parse('2026-10-30T09:00:00Z').to_f,
      }
      relation = mock('template invocation events')
      relation.expects(:order).with(:timestamp).returns(relation)
      relation.expects(:find_each).yields(stub(as_raw_continuous_output: raw_output))
      host_action = Actions::ForemanAnsibleAap::RunHostJob.allocate
      host_action.stubs(:task).returns(
        stub(template_invocation: stub(template_invocation_events: relation))
      )

      assert_equal [raw_output], host_action.live_output
    end

    test 'records whole-job cancellation without forwarding it to lightweight host plans' do
      execution_record = mock('execution record')
      execution_record.stubs(:cancellation_requested_at).returns(nil)
      execution_record.expects(:update!).with do |attributes|
        attributes.keys == [:cancellation_requested_at] && attributes[:cancellation_requested_at].present?
      end
      action.stubs(:execution_record).returns(execution_record)
      action.stubs(:output).returns({})
      action.expects(:sub_plans).never

      action.cancel!
    end

    test 'exposes incomplete AAP output separately from host execution results' do
      aggregate_result = stub(
        job_id: 91,
        job_url: 'https://aap.example.test/jobs/91/',
        commit_sha: '7f83b165',
        scm_ref: 'foreman/prod/job-invocation-42',
        output_incomplete: true,
        output_failure_diagnostic: 'AAP output page 2 was unavailable'
      )
      action_output = mock('aggregate action output')
      action.stubs(:output).returns(action_output)
      action_output.expects(:update).with(
        aap_job_id: 91,
        aap_job_url: 'https://aap.example.test/jobs/91/',
        aap_commit_sha: '7f83b165',
        aap_scm_ref: 'foreman/prod/job-invocation-42',
        aap_output_incomplete: true,
        aap_output_failure_diagnostic: 'AAP output page 2 was unavailable'
      )

      action.record_output(aggregate_result)
    end
  end
end
