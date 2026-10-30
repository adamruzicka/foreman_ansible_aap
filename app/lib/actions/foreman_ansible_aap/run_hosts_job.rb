# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostsJob < Actions::ActionWithSubPlans
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
        1
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
        return skip_aggregate if prepared_records.empty?

        execute_aggregate(prepared_records)
      rescue StandardError => e
        record_aggregate_failure(e)
      ensure
        output[:aggregate_complete] = true
        wake_host_tasks
      end

      def prepared_host_records
        host_execution_records.select { |record| record.preparation_state == 'prepared' }
      end

      def skip_aggregate
        execution_record.update!(aggregate_state: 'skipped', aggregate_error: nil)
      end

      def record_aggregate_failure(error)
        execution_record.update!(aggregate_state: 'failed', aggregate_error: error.message)
        output[:aggregate_error] = error.message
      end

      def execute_aggregate(prepared_records)
        execution_record.update!(aggregate_state: 'running', aggregate_error: nil)
        result = ::ForemanAnsibleAap::AggregateExecution.new(
          job_invocation: job_invocation,
          execution_record: execution_record,
          prepared_hosts: prepared_records.map(&:host),
          configuration: configuration,
          dependencies: execution_dependencies(prepared_records)
        ).call
        execution_record.update!(aggregate_state: 'successful', aggregate_error: nil)
        record_output(result)
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
        records.size == total_count && records.none? { |record| record.preparation_state == 'pending' }
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
