# frozen_string_literal: true

module Actions
  module ForemanAnsibleAap
    class RunHostJob < Actions::EntryAction
      class PreparationError < StandardError; end

      Poll = Algebrick.atom

      # Preparation failures must remain durable even though the action raises to
      # expose the error on this host task.
      middleware.do_not_use Dynflow::Middleware::Common::Transaction
      include ::Actions::Helpers::WithContinuousOutput

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
        prepare!(record) if record.preparation_state == ::ForemanAnsibleAap::Lifecycle::Preparation::PENDING
        if record.preparation_state == ::ForemanAnsibleAap::Lifecycle::Preparation::FAILED
          raise PreparationError, record.preparation_error
        end

        finish_or_wait(record)
      end

      def live_output
        continuous_output.sort!
      end

      def humanized_output
        continuous_output.humanize
      end

      def continuous_output_providers
        super << self
      end

      def fill_continuous_output(continuous_output)
        task.template_invocation.template_invocation_events.order(:timestamp).find_each do |event|
          continuous_output.add_raw_output(event.as_raw_continuous_output)
        end
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
        when ::ForemanAnsibleAap::Lifecycle::Result::SUCCESSFUL
          nil
        when ::ForemanAnsibleAap::Lifecycle::Result::FAILED
          raise PreparationError, record.result_error
        when ::ForemanAnsibleAap::Lifecycle::Result::CANCELLED
          error! ::ForemanTasks::Task::TaskCancelledException.new(_('Task cancelled'))
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
        transition_preparation!(record, ::ForemanAnsibleAap::Lifecycle::Preparation::PREPARED)
      rescue StandardError => e
        message = e.message.presence || e.class.name
        transition_preparation!(record, ::ForemanAnsibleAap::Lifecycle::Preparation::FAILED, message)
        raise PreparationError, message
      end

      def transition_preparation!(record, state, error = nil)
        ::ForemanAnsibleAap::Lifecycle.transition!(
          record, :preparation_state, to: state, preparation_error: error
        )
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
