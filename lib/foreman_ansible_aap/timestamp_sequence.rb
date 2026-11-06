# frozen_string_literal: true

module ForemanAnsibleAap
  # Produces event timestamps that stay strictly ordered after everything
  # already stored for a template invocation. AAP output ordering is encoded
  # into synthetic timestamps (see EventIngestor), so both the ingestor and
  # the result settler must place new events after the latest stored line.
  module TimestampSequence
    MICROSECOND = Rational(1, 1_000_000)

    module_function

    # Returns a timestamp never earlier than `floor` and strictly later than
    # the invocation's latest stored event (when one exists).
    def next_after(template_invocation, floor)
      latest = template_invocation.template_invocation_events.maximum(:timestamp)
      latest ? [floor, latest + MICROSECOND].max : floor
    end
  end
end
