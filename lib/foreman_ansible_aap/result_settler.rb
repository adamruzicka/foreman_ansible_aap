# frozen_string_literal: true

module ForemanAnsibleAap
  class ResultSettler
    def initialize(host_executions)
      @host_executions = host_executions.index_by { |record| record.host.name }
    end

    def success!(host)
      record = host_executions.fetch(host.name)
      settle(record, exit_status: '0', result_state: 'successful')
    end

    def failure!(host, diagnostic:, error: diagnostic)
      record = host_executions.fetch(host.name)
      settle(record, exit_status: '1', result_state: 'failed', diagnostic: diagnostic, error: error)
    end

    def settled?(host)
      host_executions.fetch(host.name).result_state != 'pending'
    end

    private

    attr_reader :host_executions

    def settle(record, exit_status:, result_state:, diagnostic: nil, error: nil)
      record.with_lock do
        return unless record.result_state == 'pending'

        invocation = record.template_invocation
        create_event(invocation, 'aap-host-summary-diagnostic', diagnostic, 'stdout') if diagnostic
        create_event(invocation, 'aap-host-summary-exit', exit_status, 'exit')
        record.update!(result_state: result_state, result_error: error)
      end
    end

    def create_event(invocation, external_id, event, event_type)
      TemplateInvocationEvent.create!(
        template_invocation: invocation,
        external_id: external_id,
        event: event,
        event_type: event_type,
        timestamp: Time.zone.now
      )
    end
  end
end
