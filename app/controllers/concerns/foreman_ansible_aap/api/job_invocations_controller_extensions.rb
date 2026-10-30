# frozen_string_literal: true

module ForemanAnsibleAap
  module Api
    module JobInvocationsControllerExtensions
      def create
        messages = unsupported_aap_creation_controls
        if messages.any?
          render json: { error: { message: messages.join('; ') } }, status: :unprocessable_entity
        else
          super
        end
      end

      def cancel
        if params[:search].present? && @job_invocation.aap_backed?
          render json: {
            error: {
              message: _(UnsupportedControls::FILTERED_CANCELLATION_MESSAGE),
            },
          }, status: :unprocessable_entity
        else
          super
        end
      end

      private

      def unsupported_aap_creation_controls
        return [] unless aap_creation?

        invocation = params.fetch(:job_invocation, {})
        UnsupportedControls.for_params(invocation, aap: true, template: selected_template).messages
      end

      def aap_creation?
        return false unless Setting[:ansible_execution_driver].to_s == 'aap'

        selected_template&.provider_type == 'Ansible'
      end

      def selected_template
        invocation = params.fetch(:job_invocation, {})
        if invocation[:job_template_id].present?
          JobTemplate.authorized(:view_job_templates).find_by(id: invocation[:job_template_id])
        elsif invocation[:feature].present?
          RemoteExecutionFeature.find_by(label: invocation[:feature])&.job_template
        end
      end
    end
  end
end
