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
    end
  end
end
