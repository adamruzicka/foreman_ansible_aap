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

    def failure!(host, diagnostic)
      invocation = template_invocations.fetch(host.name)
      timestamp = Time.zone.now
      TemplateInvocationEvent.transaction do
        TemplateInvocationEvent.create!(
          template_invocation: invocation,
          external_id: 'aap-integration-failure',
          event: diagnostic,
          event_type: 'stderr',
          timestamp: timestamp
        )
        TemplateInvocationEvent.create!(
          template_invocation: invocation,
          external_id: 'aap-host-summary-exit',
          event: '1',
          event_type: 'exit',
          timestamp: timestamp + 0.000001
        )
      end
    end

    private

    attr_reader :template_invocations
  end
end
