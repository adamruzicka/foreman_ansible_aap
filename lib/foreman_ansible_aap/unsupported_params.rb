# frozen_string_literal: true

module ForemanAnsibleAap
  # Rejects unsupported execution controls supplied as raw API creation
  # parameters, before a JobInvocation is instantiated. Shares its message
  # catalogue with UnsupportedControls so raw parameters and invocation
  # models enforce one policy.
  class UnsupportedParams
    PARAMETER_PATHS = {
      ssh_user: %i[ssh_user],
      password: %i[password],
      key_passphrase: %i[key_passphrase],
      effective_user: %i[ssh effective_user],
      effective_user_password: %i[ssh effective_user_password],
      concurrency_level: %i[concurrency_control concurrency_level],
      execution_timeout: %i[execution_timeout_interval],
    }.freeze

    def initialize(params, template: nil)
      @params = params
      @template = template
    end

    def messages
      messages = PARAMETER_PATHS.filter_map do |control, path|
        message(control) if unsupported_parameter?(control, params.dig(*path))
      end
      messages << message(:provider_inputs) if provider_params?
      messages
    end

    private

    attr_reader :params, :template

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

    def message(control)
      _(UnsupportedControls::MESSAGES.fetch(control))
    end
  end
end
