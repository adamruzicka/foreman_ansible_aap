# frozen_string_literal: true

module ForemanAnsibleAap
  module Api
    module JobInvocationsControllerExtensions
      CREATION_CONTROL_PATHS = {
        %i[ssh_user] => N_('SSH user is not supported by the AAP execution driver'),
        %i[password] => N_('SSH password is not supported by the AAP execution driver'),
        %i[key_passphrase] => N_('SSH key passphrase is not supported by the AAP execution driver'),
        %i[ssh effective_user] => N_('Effective user is not supported by the AAP execution driver'),
        %i[ssh effective_user_password] => N_('Effective user password is not supported by the AAP execution driver'),
        %i[concurrency_control concurrency_level] =>
          N_('Concurrency / proxy batching is not supported by the AAP execution driver'),
      }.freeze
      FILTERED_CANCELLATION_MESSAGE = N_(
        'Host-filtered cancellation is not supported for a single aggregate AAP job; ' \
        'cancel the whole Job Invocation instead.'
      )

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
              message: _(FILTERED_CANCELLATION_MESSAGE),
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
        messages = CREATION_CONTROL_PATHS.filter_map do |path, message|
          _(message) if invocation.dig(*path).present?
        end
        messages << _('Ansible proxy provider options are not supported by the AAP execution driver') if
          provider_inputs?(invocation)
        messages
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

      def provider_inputs?(invocation)
        invocation[:ansible].respond_to?(:values) && invocation[:ansible].values.any?(&:present?)
      end
    end
  end
end
