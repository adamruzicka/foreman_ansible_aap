# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostsJob < Actions::ActionWithSubPlans
      include Actions::RecurringAction

      Lifecycle = ::ForemanAnsibleAap::Lifecycle
      AggregateExecution = ::ForemanAnsibleAap::AggregateExecution

      middleware.use Actions::Middleware::BindJobInvocation
      middleware.do_not_use Dynflow::Middleware::Common::Transaction

      def queue
        ::ForemanRemoteExecution::DYNFLOW_QUEUE
      end

      def plan(job_invocation)
        job_invocation.task_group.save! if job_invocation.task_group.try(:new_record?)
        task.add_missing_task_groups(job_invocation.task_group) if job_invocation.task_group
        action_subject(job_invocation)
        job_invocation.targeting.resolve_hosts! unless job_invocation.targeting.resolved?
        plan_self(job_invocation_id: job_invocation.id)
      end

      def create_sub_plans
        current_batch.map do |host|
          template_invocation = job_invocation.pattern_template_invocation_for_host(host).deep_clone
          trigger(RunHostJob, job_invocation, host, template_invocation, execution_record)
        end
      end

      def run(event = nil)
        handle_event(event)
        coordinate_aggregate if preparation_complete? && !output[:aggregate_complete]
        try_to_finish || suspend_and_ping
      end

      def handle_event(event)
        case event
        when nil
          output[:total_count] ? resume : initiate
        when Ping
          tick
        when ::Dynflow::Action::Cancellable::Cancel
          cancel!
        when ::Dynflow::Action::Cancellable::Abort
          abort!
        end
      end

      # WithSubPlans retries all-plan failures by starting planning over. AAP host
      # preparation is intentionally run-phase work and must remain one attempt.
      def resume
        tick
      end

      def polling_interval
        output.fetch(:aap_polling_interval, 1)
      end

      def record_output(result)
        output.update(
          aap_job_id: result.job_id,
          aap_job_url: result.job_url,
          aap_commit_sha: result.commit_sha,
          aap_scm_ref: result.scm_ref,
          aap_output_incomplete: result.output_incomplete,
          aap_output_failure_diagnostic: result.output_failure_diagnostic
        )
      end

      # AAP cancellation belongs to the aggregate execution. Do not forward
      # Dynflow cancellation to the lightweight host tasks: they wait for the
      # authoritative aggregate outcome instead.
      def cancel!(_force = false)
        unless execution_record.cancellation_requested_at
          execution_record.update!(cancellation_requested_at: Time.zone.now)
        end
        output[:cancelled_timestamp] ||= Time.now.utc.iso8601
      end

      def abort!
        cancel!
      end

      def check_for_errors!
        case execution_record.aggregate_state
        when Lifecycle::Aggregate::FAILED
          raise AggregateExecution::ExecutionError,
            execution_record.aggregate_error
        when Lifecycle::Aggregate::CANCELLED
          raise ::ForemanTasks::Task::TaskCancelledException, _('Task cancelled')
        else
          super
        end
      end

      def total_count
        hosts.count
      end

      def batch_size
        total_count
      end

      def batch(from, size)
        hosts.offset(from).limit(size)
      end

      def hosts
        job_invocation.targeting.hosts.order("#{TargetingHost.table_name}.id")
      end

      def job_invocation
        @job_invocation ||= ::JobInvocation.find(input[:job_invocation_id])
      end

      def rescue_strategy
        ::Dynflow::Action::Rescue::Skip
      end

      private

      def coordinate_aggregate
        prepared_records = prepared_host_records
        if prepared_records.empty?
          skip_aggregate
          complete_aggregate
          return
        end

        execute_aggregate(prepared_records)
      rescue StandardError => e
        record_aggregate_failure(e)
        complete_aggregate
      end

      def prepared_host_records
        execution_record.host_executions.preparation_prepared.includes(:host, :template_invocation).to_a
      end

      def skip_aggregate
        Lifecycle.transition!(
          execution_record,
          :aggregate_state,
          to: ::ForemanAnsibleAap::Lifecycle::Aggregate::SKIPPED,
          aggregate_error: nil
        )
      end

      def record_aggregate_failure(error)
        Lifecycle.transition!(
          execution_record,
          :aggregate_state,
          to: ::ForemanAnsibleAap::Lifecycle::Aggregate::FAILED,
          aggregate_error: error.message
        )
        output[:aggregate_error] = error.message
      end

      def execute_aggregate(prepared_records)
        start_aggregate!
        step = AggregateExecution.new(
          job_invocation: job_invocation,
          execution_record: execution_record,
          prepared_hosts: prepared_records.map(&:host),
          configuration: configuration,
          dependencies: execution_dependencies(prepared_records)
        ).advance
        output[:aap_polling_interval] = step.retry_after || 1
        return unless step.complete?

        finish_aggregate!(step.result)
      end

      def start_aggregate!
        pending = Lifecycle::Aggregate::PENDING
        return unless execution_record.aggregate_state == pending

        Lifecycle.transition!(
          execution_record,
          :aggregate_state,
          to: ::ForemanAnsibleAap::Lifecycle::Aggregate::RUNNING,
          aggregate_error: nil
        )
      end

      def finish_aggregate!(result)
        Lifecycle.transition!(
          execution_record,
          :aggregate_state,
          to: aggregate_state_for(result),
          aggregate_error: nil
        )
        record_output(result)
        complete_aggregate
      end

      def aggregate_state_for(result)
        if result.state == Lifecycle::Result::CANCELLED
          Lifecycle::Aggregate::CANCELLED
        else
          Lifecycle::Aggregate::SUCCESSFUL
        end
      end

      def complete_aggregate
        output[:aggregate_complete] = true
        wake_host_tasks
      end

      def wake_host_tasks
        sub_plans(state: 'running').each do |plan|
          action_id = plan.root_plan_step.action_id
          action = world.persistence.load_actions(plan, [action_id]).first
          world.event(plan.id, action.run_step_id, RunHostJob::Poll, optional: true)
        end
      end

      def preparation_complete?
        records = host_execution_records
        records.size == total_count && records.none?(&:preparation_pending?)
      end

      def host_execution_records
        execution_record.host_executions.includes(:host, :template_invocation).to_a
      end

      def execution_record
        @execution_record ||= ::ForemanAnsibleAap::Execution.find_or_create_by!(job_invocation: job_invocation)
      end

      def configuration
        @configuration ||= ::ForemanAnsibleAap::Configuration.from_settings
      end

      def aap_client
        ::ForemanAnsibleAap::AapClient.new(
          controller_url: configuration.controller_url,
          token: configuration.service_token,
          ca_bundle: configuration.ca_bundle
        )
      end

      def execution_dependencies(host_executions)
        template_invocations = host_executions.map(&:template_invocation)
        {
          renderer: ::ForemanAnsibleAap::PlaybookRenderer.new,
          publisher: ::ForemanAnsibleAap::GitPublisher.new,
          aap_client: aap_client,
          event_ingestor: event_ingestor(execution_record, template_invocations),
          result_settler: ::ForemanAnsibleAap::ResultSettler.new(host_executions),
        }
      end

      def event_ingestor(execution_record, template_invocations)
        ::ForemanAnsibleAap::EventIngestor.new(
          execution_record: execution_record,
          template_invocations: template_invocations,
          aap_client: aap_client
        )
      end
    end
  end
end
