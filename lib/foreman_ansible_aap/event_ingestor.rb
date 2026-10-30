# frozen_string_literal: true

require 'json'

module ForemanAnsibleAap
  class EventIngestor
    OUTPUT_CHUNK_SIZE = 255

    def initialize(execution_record:, template_invocations:, aap_client:)
      @execution_record = execution_record
      @template_invocations = template_invocations.index_by { |invocation| invocation.host.name }
      @aap_client = aap_client
    end

    def ingest(job_id)
      aap_client.job_events(job_id, after_id: execution_record.event_cursor).each do |event|
        persist(job_id, event)
      end
    end

    private

    attr_reader :execution_record, :template_invocations, :aap_client

    def persist(job_id, event)
      execution_record.with_lock do
        event_id = Integer(event.fetch(:id))
        next if already_ingested?(event_id)

        template_invocation = template_invocations[event[:host_name]]
        persist_event(template_invocation, job_id, event)
        execution_record.update!(event_cursor: event_id)
      end
    end

    def already_ingested?(event_id)
      execution_record.event_cursor && event_id <= execution_record.event_cursor
    end

    def persist_event(template_invocation, job_id, event)
      return persist_host_output(template_invocation, job_id, event) if template_invocation

      persist_diagnostic(job_id, event)
    end

    def persist_host_output(template_invocation, job_id, event)
      chunks = event.fetch(:stdout, '').scan(/.{1,#{OUTPUT_CHUNK_SIZE}}/m)
      return if chunks.empty?

      timestamp = next_timestamp(template_invocation, event.fetch(:timestamp))
      ::TemplateInvocationEvent.insert_all( # rubocop:disable Rails/SkipsModelValidations
        output_rows(template_invocation, job_id, event, chunks, timestamp),
        unique_by: %i[template_invocation_id external_id]
      )
    end

    def output_rows(template_invocation, job_id, event, chunks, timestamp)
      chunks.each_with_index.map do |chunk, index|
        {
          template_invocation_id: template_invocation.id,
          external_id: "aap-job-#{job_id}-event-#{event.fetch(:id)}-chunk-#{index}",
          event: chunk,
          event_type: 'stdout',
          timestamp: timestamp + (index / 1_000_000.0),
        }
      end
    end

    def next_timestamp(template_invocation, remote_timestamp)
      timestamp = Time.zone.parse(remote_timestamp.to_s)
      latest = template_invocation.template_invocation_events.maximum(:timestamp)
      latest && timestamp <= latest ? latest + 0.000001 : timestamp
    end

    def persist_diagnostic(job_id, event)
      diagnostics = execution_record.event_diagnostics
      external_id = "aap-job-#{job_id}-event-#{event.fetch(:id)}"
      return if diagnostics.any? { |diagnostic| diagnostic['external_id'] == external_id }

      diagnostics << {
        'external_id' => external_id,
        'host_name' => event[:host_name],
        'output' => event.fetch(:stdout, ''),
        'timestamp' => event.fetch(:timestamp).to_s,
      }
      execution_record.update!(event_diagnostics: JSON.generate(diagnostics))
    end
  end
end
