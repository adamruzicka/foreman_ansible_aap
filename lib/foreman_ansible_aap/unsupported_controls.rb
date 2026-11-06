# frozen_string_literal: true

module ForemanAnsibleAap
  # Rejects unsupported execution controls on an (about-to-be-persisted)
  # JobInvocation model. Raw API parameters are covered by the sibling
  # UnsupportedParams; both share the MESSAGES catalogue.
  class UnsupportedControls
    MESSAGES = {
      ssh_user: N_('SSH user is not supported by the AAP execution driver'),
      password: N_('SSH password is not supported by the AAP execution driver'),
      key_passphrase: N_('SSH key passphrase is not supported by the AAP execution driver'),
      effective_user: N_('Effective user overrides are not supported by the AAP execution driver'),
      effective_user_password: N_('Effective user password is not supported by the AAP execution driver'),
      concurrency_level: N_('Concurrency / proxy batching is not supported by the AAP execution driver'),
      execution_timeout: N_('Execution timeout is owned by AAP and cannot be overridden by Foreman'),
      smart_proxy: N_('Smart proxy selection is not supported by the AAP execution driver'),
      provider_inputs: N_('Ansible proxy provider options are not supported by the AAP execution driver'),
    }.freeze
    MODEL_ATTRIBUTES = %i[ssh_user password key_passphrase effective_user_password concurrency_level].freeze
    FILTERED_CANCELLATION_MESSAGE = N_(
      'Host-filtered cancellation is not supported for a single aggregate AAP job; ' \
      'cancel the whole Job Invocation instead.'
    )

    def initialize(job_invocation, aap: nil)
      @job_invocation = job_invocation
      @aap = aap
    end

    def messages
      return [] unless aap_backed?

      invocation_control_messages + template_control_messages
    end

    def validate!
      return if messages.empty?

      raise ArgumentError, messages.join('; ')
    end

    private

    attr_reader :job_invocation, :aap

    def aap_backed?
      return aap unless aap.nil?

      job_invocation.respond_to?(:ansible_execution_driver) &&
        job_invocation.ansible_execution_driver.to_s == 'aap'
    end

    def invocation_control_messages
      MODEL_ATTRIBUTES.filter_map do |attribute|
        next unless job_invocation.respond_to?(attribute)
        next if job_invocation.public_send(attribute).blank?

        message(attribute)
      end
    end

    def template_control_messages
      messages = template_invocations.flat_map do |invocation|
        [
          smart_proxy_message(invocation),
          effective_user_message(invocation),
          provider_inputs_message(invocation),
        ].compact
      end
      (messages << execution_timeout_message).compact.uniq
    end

    def template_invocations
      return [] unless job_invocation.respond_to?(:pattern_template_invocations) &&
                       job_invocation.respond_to?(:template_invocations)

      (job_invocation.pattern_template_invocations.to_a +
        job_invocation.template_invocations.to_a).uniq
    end

    def smart_proxy_message(invocation)
      return if invocation.smart_proxy_id.blank?

      message(:smart_proxy)
    end

    def effective_user_message(invocation)
      effective_user = invocation.effective_user
      return if effective_user.blank? || effective_user == Setting[:remote_execution_effective_user]

      message(:effective_user)
    end

    def provider_inputs_message(invocation)
      return if invocation.provider_input_values.none? { |value| value.value.present? }

      message(:provider_inputs)
    end

    def execution_timeout_message
      return unless job_invocation.respond_to?(:execution_timeout_interval)

      timeout = job_invocation.execution_timeout_interval
      inherited = template_invocations.filter_map { |invocation| invocation.template.execution_timeout_interval }
      return if timeout.blank? || inherited.include?(timeout)

      message(:execution_timeout)
    end

    def message(control)
      _(MESSAGES.fetch(control))
    end
  end
end
