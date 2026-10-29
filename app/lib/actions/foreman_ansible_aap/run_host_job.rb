# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostJob < Actions::EntryAction
      def queue
        ::ForemanRemoteExecution::DYNFLOW_QUEUE
      end

      def resource_locks
        :link
      end

      def plan(job_invocation, host, template_invocation)
        action_subject(host,
          job_category: job_invocation.job_category,
          description: job_invocation.description,
          job_invocation_id: job_invocation.id)

        template_invocation.host_id = host.id
        template_invocation.run_host_job_task_id = task.id
        template_invocation.save!

        link!(job_invocation)
        link!(template_invocation)
        plan_self
      end

      def run
      end

      def rescue_strategy
        ::Dynflow::Action::Rescue::Fail
      end
    end
  end
end
