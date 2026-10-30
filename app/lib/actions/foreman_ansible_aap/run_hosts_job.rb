# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostsJob < Actions::ActionWithSubPlans
      middleware.use Actions::Middleware::BindJobInvocation

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
          trigger(RunHostJob, job_invocation, host, template_invocation)
        end
      end

      def finalize
        invocation = job_invocation
        template_invocations = prepared_template_invocations(invocation)
        execution = ::ForemanAnsibleAap::AggregateExecution.new(
          job_invocation: invocation,
          execution_record: ::ForemanAnsibleAap::Execution.find_or_create_by!(job_invocation: invocation),
          prepared_hosts: template_invocations.map(&:host),
          configuration: configuration,
          dependencies: execution_dependencies(template_invocations)
        )
        result = execution.call
        record_output(result)
      end

      def record_output(result)
        output.update(
          aap_job_id: result.job_id,
          aap_job_url: result.job_url,
          aap_commit_sha: result.commit_sha,
          aap_scm_ref: result.scm_ref
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

      def prepared_template_invocations(invocation)
        invocation.template_invocations
                  .where.not(run_host_job_task_id: nil)
                  .includes(:host)
                  .to_a
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

      def execution_dependencies(template_invocations)
        {
          renderer: ::ForemanAnsibleAap::PlaybookRenderer.new,
          publisher: ::ForemanAnsibleAap::GitPublisher.new,
          aap_client: aap_client,
          result_settler: ::ForemanAnsibleAap::ResultSettler.new(template_invocations),
        }
      end
    end
  end
end
