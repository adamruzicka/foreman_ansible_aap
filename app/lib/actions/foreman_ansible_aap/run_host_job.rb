# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostJob < Actions::EntryAction
      class PreparationError < StandardError; end

      Poll = Algebrick.atom

      # Preparation failures must remain durable even though the action raises to
      # expose the error on this host task.
      middleware.do_not_use Dynflow::Middleware::Common::Transaction

      def queue
        ::ForemanRemoteExecution::DYNFLOW_QUEUE
      end

      def resource_locks
        :link
      end

      def plan(job_invocation, host, template_invocation, execution_record)
        action_subject(host,
          job_category: job_invocation.job_category,
          description: job_invocation.description,
          job_invocation_id: job_invocation.id)

        template_invocation.host_id = host.id
        template_invocation.run_host_job_task_id = task.id
        template_invocation.save!

        link!(job_invocation)
        link!(template_invocation)

        plan_self(host_execution_id: create_host_execution(execution_record, host, template_invocation).id)
      end

      def run(_event = nil)
        record = host_execution.reload
        prepare!(record) if record.preparation_state == 'pending'
        raise PreparationError, record.preparation_error if record.preparation_state == 'failed'

        finish_or_wait(record)
      end

      def rescue_strategy
        ::Dynflow::Action::Rescue::Fail
      end

      private

      def create_host_execution(execution_record, host, template_invocation)
        ::ForemanAnsibleAap::HostExecution.create!(
          execution: execution_record,
          host: host,
          template_invocation: template_invocation
        )
      end

      def finish_or_wait(record)
        case record.result_state
        when 'successful'
          nil
        when 'failed'
          raise PreparationError, record.result_error
        else
          suspend
        end
      end

      def host_execution
        @host_execution ||= ::ForemanAnsibleAap::HostExecution.find(input.fetch(:host_execution_id))
      end

      def prepare!(record)
        verify_permissions(record.host, record.template_invocation)
        validate_local_preparation!(record.template_invocation)
        record.update!(preparation_state: 'prepared', preparation_error: nil)
      rescue StandardError => e
        message = e.message.presence || e.class.name
        record.update!(preparation_state: 'failed', preparation_error: message)
        raise PreparationError, message
      end

      def validate_local_preparation!(template_invocation)
        return if template_invocation.template.present?

        raise PreparationError, _('Could not use any template used in the job invocation')
      end

      def verify_permissions(host, template_invocation)
        verify_host_permission!(host)
        verify_template_permission!(template_invocation)
        verify_infrastructure_permission!(host)
        verify_invocation_permission!(host, template_invocation)
        true
      end

      def verify_host_permission!(host)
        return if User.current.can?(:view_hosts, host)

        raise PreparationError, _('User can not execute job on host %s') % host.name
      end

      def verify_template_permission!(template_invocation)
        return if User.current.can?(:view_job_templates, template_invocation.template)

        raise PreparationError, _('User can not execute this job template')
      end

      def verify_infrastructure_permission!(host)
        infra_facet = host.infrastructure_facet
        return unless infra_facet&.foreman_instance || infra_facet&.smart_proxy_id
        return if User.current.can?(:execute_jobs_on_infrastructure_hosts)

        raise PreparationError, _('User can not execute job on infrastructure host %s') % host.name
      end

      def verify_invocation_permission!(host, template_invocation)
        authorizer = Authorizer.new(User.current, collection: [template_invocation.id])
        return if authorizer.can?(:create_template_invocations, template_invocation)

        raise PreparationError, _('User can not execute this job template on %s') % host.name
      end
    end
  end
end
