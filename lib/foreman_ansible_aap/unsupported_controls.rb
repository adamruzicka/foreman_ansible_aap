# frozen_string_literal: true

module ForemanAnsibleAap
  class UnsupportedControls
    CONTROL_ATTRIBUTES = {
      ssh_user: N_('Ssh user'),
      password: N_('Password'),
      key_passphrase: N_('Key passphrase'),
      effective_user_password: N_('Effective user password'),
      concurrency_level: N_('Concurrency level / proxy batching'),
    }.freeze

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
      CONTROL_ATTRIBUTES.filter_map do |attribute, label|
        next unless job_invocation.respond_to?(attribute)
        next if job_invocation.public_send(attribute).blank?

        _('%s is not supported by the AAP execution driver') % _(label)
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

      _('Smart proxy selection is not supported by the AAP execution driver')
    end

    def effective_user_message(invocation)
      effective_user = invocation.effective_user
      return if effective_user.blank? || effective_user == Setting[:remote_execution_effective_user]

      _('Effective user overrides are not supported by the AAP execution driver')
    end

    def provider_inputs_message(invocation)
      return if invocation.provider_input_values.none? { |value| value.value.present? }

      _('Ansible proxy provider options are not supported by the AAP execution driver')
    end

    def execution_timeout_message
      return unless job_invocation.respond_to?(:execution_timeout_interval)

      timeout = job_invocation.execution_timeout_interval
      inherited = template_invocations.filter_map { |invocation| invocation.template.execution_timeout_interval }
      return if timeout.blank? || inherited.include?(timeout)

      _('Execution timeout overrides are not supported because AAP owns the execution deadline')
    end
  end
end
