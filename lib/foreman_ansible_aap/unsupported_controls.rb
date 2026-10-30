# frozen_string_literal: true

module ForemanAnsibleAap
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
    PARAMETER_PATHS = {
      ssh_user: %i[ssh_user],
      password: %i[password],
      key_passphrase: %i[key_passphrase],
      effective_user: %i[ssh effective_user],
      effective_user_password: %i[ssh effective_user_password],
      concurrency_level: %i[concurrency_control concurrency_level],
      execution_timeout: %i[execution_timeout_interval],
    }.freeze
    MODEL_ATTRIBUTES = %i[ssh_user password key_passphrase effective_user_password concurrency_level].freeze
    FILTERED_CANCELLATION_MESSAGE = N_(
      'Host-filtered cancellation is not supported for a single aggregate AAP job; ' \
      'cancel the whole Job Invocation instead.'
    )

    def self.for_params(params, aap:, template: nil)
      new(nil, aap: aap, params: params, template: template)
    end

    def initialize(job_invocation, aap: nil, params: nil, template: nil)
      @job_invocation = job_invocation
      @aap = aap
      @params = params
      @template = template
    end

    def messages
      return [] unless aap_backed?

      params ? parameter_control_messages : invocation_control_messages + template_control_messages
    end

    def validate!
      return if messages.empty?

      raise ArgumentError, messages.join('; ')
    end

    private

    attr_reader :job_invocation, :aap, :params, :template

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

    def parameter_control_messages
      messages = PARAMETER_PATHS.filter_map do |control, path|
        value = params.dig(*path)
        message(control) if unsupported_parameter?(control, value)
      end
      messages << message(:provider_inputs) if provider_params?
      messages
    end

    def unsupported_parameter?(control, value)
      return false if value.blank?
      return value != Setting[:remote_execution_effective_user] if control == :effective_user
      if control == :execution_timeout && template
        inherited_timeout = template.execution_timeout_interval
        return inherited_timeout.blank? || value.to_i != inherited_timeout.to_i
      end

      true
    end

    def provider_params?
      provider_params = params[:ansible]
      provider_params.respond_to?(:values) && provider_params.values.any?(&:present?)
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
