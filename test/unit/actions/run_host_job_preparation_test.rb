# frozen_string_literal: true

require 'test_plugin_helper'

module ForemanAnsibleAap
  class RunHostJobPreparationTest < ActiveSupport::TestCase
    include Dynflow::Testing

    setup do
      @admin = User.current
    end

    teardown do
      User.current = @admin
    end

    test 'records a permission failure on only the affected host task' do
      host_execution = build_host_execution
      User.current = FactoryBot.create(:user)
      action = action_for(host_execution)

      error = assert_raises(Actions::ForemanAnsibleAap::RunHostJob::PreparationError) do
        action.run
      end

      assert_includes error.message, "host #{host_execution.host.name}"
      assert_equal 'failed', host_execution.reload.preparation_state
      assert_includes host_execution.preparation_error, "host #{host_execution.host.name}"
    end

    test 'a successfully prepared host waits for its aggregate result' do
      host_execution = build_host_execution
      action = action_for(host_execution)
      action.expects(:suspend)

      action.run

      assert_equal 'prepared', host_execution.reload.preparation_state
      assert_equal 'pending', host_execution.result_state
    end

    test 'a shared failure after preparation fails the prepared host task' do
      host_execution = build_host_execution(
        preparation_state: 'prepared',
        result_state: 'failed',
        result_error: 'AAP preflight rejected the fixed project'
      )
      action = action_for(host_execution)

      error = assert_raises(Actions::ForemanAnsibleAap::RunHostJob::PreparationError) do
        action.run
      end

      assert_equal 'AAP preflight rejected the fixed project', error.message
      assert_equal 'prepared', host_execution.reload.preparation_state
    end

    test 'an unfinished host receives a cancellation outcome without becoming independently cancellable' do
      host_execution = build_host_execution(
        preparation_state: 'prepared',
        result_state: 'cancelled',
        result_error: 'AAP job cancellation left this host unfinished'
      )
      action = action_for(host_execution)

      assert_raises(ForemanTasks::Task::TaskCancelledException) { run_action(action) }
      refute Actions::ForemanAnsibleAap::RunHostJob < Dynflow::Action::Cancellable
    end

    private

    def action_for(host_execution)
      create_action(Actions::ForemanAnsibleAap::RunHostJob).tap do |action|
        action.input.update(host_execution_id: host_execution.id)
      end
    end

    def build_host_execution(attributes = {})
      host = FactoryBot.create(:host)
      invocation = FactoryBot.create(:job_invocation, :with_template)
      template_invocation = invocation.pattern_template_invocations.first.deep_clone
      template_invocation.update!(host: host)
      execution = Execution.create!(job_invocation: invocation)
      HostExecution.create!({
        execution: execution,
        host: host,
        template_invocation: template_invocation,
      }.merge(attributes))
    end
  end
end
