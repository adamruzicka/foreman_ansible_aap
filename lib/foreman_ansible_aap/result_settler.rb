# frozen_string_literal: true

module ForemanAnsibleAap
  class ResultSettler
    def initialize(template_invocations)
      @template_invocations = template_invocations.index_by { |invocation| invocation.host.name }
    end

    def success!(host)
      invocation = template_invocations.fetch(host.name)
      settle(invocation, exit_status: '0', task_result: 'success')
    end

    def failure!(host, diagnostic:)
      invocation = template_invocations.fetch(host.name)
      settle(invocation, exit_status: '1', task_result: 'error', diagnostic: diagnostic)
    end

    private

    attr_reader :template_invocations

    def settle(invocation, exit_status:, task_result:, diagnostic: nil)
      TemplateInvocationEvent.transaction do
        create_event(invocation, 'aap-host-summary-diagnostic', diagnostic, 'stdout') if diagnostic
        create_event(invocation, 'aap-host-summary-exit', exit_status, 'exit')
        invocation.run_host_job_task.update!(result: task_result)
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
