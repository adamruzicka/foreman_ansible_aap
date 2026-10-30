# frozen_string_literal: true

module ForemanAnsibleAap
  class ResultSettler
    def initialize(host_executions)
      @host_executions = host_executions.index_by { |record| record.host.name }
    end

    def success!(host)
      record = host_executions.fetch(host.name)
      record.transaction do
        create_success_event(record)
        record.update!(result_state: 'successful', result_error: nil)
      end
    end

    def fail_all!(hosts, error)
      message = error.message.presence || error.class.name
      hosts.each do |host|
        host_executions.fetch(host.name).update!(
          result_state: 'failed',
          result_error: message
        )
      end
    end

    private

    attr_reader :host_executions

    def create_success_event(record)
      TemplateInvocationEvent.find_or_create_by!(
        template_invocation: record.template_invocation,
        external_id: 'aap-host-summary-exit'
      ) do |event|
        event.event = '0'
        event.event_type = 'exit'
        event.timestamp = Time.zone.now
      end
    end
  end
end
