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
      events = aap_client.job_events(job_id, after_id: execution_record.event_cursor)
      return if events.empty?

      sort_events(events).each { |event| persist(job_id, event) }
      advance_cursor(events)
    end

    # AAP assigns event ids in arrival order, not output order, and events
    # from different callback streams interleave. AAP numbers events with a
    # `counter` in true output order (its own rendering order); start_line is
    # the fallback when the counter is absent. Because ids are persisted out
    # of order, the cursor records the highest id OBSERVED in a fetch (new AAP
    # events always get ids greater than every existing one); dedup relies on
    # the idempotent writes, not on the cursor.
    def sort_events(events)
      return events.sort_by { |event| [event.fetch(:counter), event.fetch(:id)] } if events.all? { |event| event[:counter] }
      return events.sort_by { |event| [event[:start_line], event[:end_line], event.fetch(:id)] } if events.all? { |event| event[:start_line] }

      events.sort_by { |event| event.fetch(:id) }
    end

    private

    attr_reader :execution_record, :template_invocations, :aap_client

    def advance_cursor(events)
      max_id = events.map { |event| Integer(event.fetch(:id)) }.max
      execution_record.with_lock do
        execution_record.update!(event_cursor: [execution_record.event_cursor.to_i, max_id].max)
      end
    end

    # Re-persisting an event is safe: host output uses insert_all with a
    # unique external_id and diagnostics check for an existing entry, so no
    # lock or cursor comparison is needed here.
    def persist(job_id, event)
      template_invocation = template_invocations[event[:host_name]]
      persist_event(template_invocation, job_id, event)
    end

    # Play-level events (play/task banners, the recap) carry no host in AAP,
    # but the per-host output view only reads that host's invocation events, so
    # they must be fanned out to every invocation to remain visible. Events for
    # hosts outside the invocation set (e.g. delegate targets) stay diagnostic.
    def persist_event(template_invocation, job_id, event)
      return persist_host_output(template_invocation, job_id, event) if template_invocation
      return fan_out_hostless_output(job_id, event) if event[:host_name].nil? && template_invocations.any?

      persist_diagnostic(job_id, event)
    end

    def fan_out_hostless_output(job_id, event)
      template_invocations.each_value do |invocation|
        persist_host_output(invocation, job_id, event)
      end
    end

    def persist_host_output(template_invocation, job_id, event)
      stdout = event.fetch(:stdout, '')
      chunks = split_stdout(stdout)
      return if chunks.empty?

      timestamp = event_timestamp(template_invocation, event)
      ::TemplateInvocationEvent.insert_all( # rubocop:disable Rails/SkipsModelValidations
        output_rows(template_invocation, job_id, event, chunks, timestamp),
        unique_by: %i[template_invocation_id external_id]
      )
    end

    HEADING_PATTERN = /\A(?:\e\[[0-9;]*m)*(?:PLAY \[|TASK \[|PLAY RECAP)/

    # The output viewer renders each stored event as one numbered line, so
    # chunks must align with the stdout's own line boundaries. AAP emits CRLF
    # line endings and shows a blank line before every play/task heading; both
    # are normalized so the rendered output matches AAP exactly. Lines longer
    # than OUTPUT_CHUNK_SIZE are wrapped, but never in the middle of an ANSI
    # escape sequence, which would render as garbage such as "[0;32m".
    def split_stdout(stdout)
      lines = stdout.gsub(/\r\n/, "\n").gsub(/\r/, "\n")
                   .sub(/\A\n+/, '').split("\n")
      lines.unshift('') if lines.first&.match?(HEADING_PATTERN)
      lines.flat_map { |line| wrap_line(line) }
    end

    def wrap_line(line)
      return [line] if line.length <= OUTPUT_CHUNK_SIZE

      chunks = []
      buffer = +''
      line.scan(/\e\[[0-9;]*[A-Za-z]|./m).each do |token|
        if buffer.length + token.length > OUTPUT_CHUNK_SIZE
          chunks << buffer
          buffer = +''
        end
        buffer << token
      end
      chunks << buffer
    end

    def output_rows(template_invocation, job_id, event, chunks, timestamp)
      chunks.each_with_index.map do |chunk, index|
        {
          template_invocation_id: template_invocation.id,
          external_id: "aap-job-#{job_id}-event-#{event.fetch(:id)}-chunk-#{index}",
          event: chunk,
          event_type: 'stdout',
          timestamp: timestamp + index / 1_000_000r,
        }
      end
    end

    # The AAP event counter is the authoritative output order and is stable
    # across polls, so it is encoded directly into the stored timestamp: a
    # late-arriving event with an earlier output position still sorts before
    # already-stored later lines. Events without a counter fall back to the
    # event timestamp, nudged past the latest stored line to stay monotonic.
    def event_timestamp(template_invocation, event)
      return next_timestamp(template_invocation, event.fetch(:timestamp)) unless event[:counter]

      execution_record.created_at + event.fetch(:counter).seconds
    end

    def next_timestamp(template_invocation, remote_timestamp)
      timestamp = Time.zone.parse(remote_timestamp.to_s).round(6)
      latest = template_invocation.template_invocation_events.maximum(:timestamp)
      latest && timestamp <= latest ? latest + 1r / 1_000_000r : timestamp
    end

    def persist_diagnostic(job_id, event)
      execution_record.with_lock do
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
end
