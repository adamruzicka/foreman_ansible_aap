# frozen_string_literal: true

module ForemanAnsibleAap
  class ResultSettler
    def initialize(host_executions)
      @host_executions = host_executions.index_by { |record| record.host.name }
    end

    def success!(host)
      record = host_executions.fetch(host.name)
      settle(record, exit_status: '0', result_state: Lifecycle::Result::SUCCESSFUL)
    end

    def failure!(host, diagnostic:, error: diagnostic)
      record = host_executions.fetch(host.name)
      settle(record, exit_status: '1', result_state: Lifecycle::Result::FAILED, diagnostic: diagnostic, error: error)
    end

    def cancelled!(host)
      record = host_executions.fetch(host.name)
      settle(
        record,
        exit_status: '1',
        result_state: Lifecycle::Result::CANCELLED,
        error: 'AAP job cancellation left this host unfinished'
      )
    end

    def settled?(host)
      !host_executions.fetch(host.name).result_pending?
    end

    private

    attr_reader :host_executions

    def settle(record, exit_status:, result_state:, diagnostic: nil, error: nil)
      record.with_lock do
        return unless record.result_pending?

        invocation = record.template_invocation
        create_event(invocation, 'aap-host-summary-diagnostic', diagnostic, 'stdout') if diagnostic
        create_event(invocation, 'aap-host-summary-exit', exit_status, 'exit')
        Lifecycle.transition!(record, :result_state, to: result_state, result_error: error)
      end
    end

    def create_event(invocation, external_id, event, event_type)
      # AAP output lines carry synthetic timestamps (job anchor + event
      # counter), which can run past wall-clock time on short jobs; settle
      # events must always render after the host's output.
      timestamp = TimestampSequence.next_after(invocation, Time.zone.now)
      TemplateInvocationEvent.create!(
        template_invocation: invocation,
        external_id: external_id,
        event: event,
        event_type: event_type,
        timestamp: timestamp
      )
    end
  end
end
