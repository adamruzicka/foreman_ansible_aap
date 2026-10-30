# frozen_string_literal: true

module ForemanAnsibleAap
  class ResultSettler
    def initialize(template_invocations)
      @template_invocations = template_invocations.index_by { |invocation| invocation.host.name }
    end

    def success!(host)
      invocation = template_invocations.fetch(host.name)
      TemplateInvocationEvent.create!(
        template_invocation: invocation,
        external_id: 'aap-host-summary-exit',
        event: '0',
        event_type: 'exit',
        timestamp: Time.zone.now
      )
    end

    private

    attr_reader :template_invocations
  end
end
