# frozen_string_literal: true

module ForemanAnsibleAap
  module Lifecycle
    module Aggregate
      PENDING = 'pending'
      RUNNING = 'running'
      SUCCESSFUL = 'successful'
      FAILED = 'failed'
      SKIPPED = 'skipped'
      CANCELLED = 'cancelled'
      STATES = [PENDING, RUNNING, SUCCESSFUL, FAILED, SKIPPED, CANCELLED].freeze
    end

    module Workflow
      PENDING = 'pending'
      PREFLIGHTED = 'preflighted'
      PUBLISHED = 'published'
      LAUNCHED = 'launched'
      POLLING = 'polling'
      RECONCILED = 'reconciled'
      STATES = [PENDING, PREFLIGHTED, PUBLISHED, LAUNCHED, POLLING, RECONCILED].freeze
      LAUNCHED_STATES = [LAUNCHED, POLLING, RECONCILED].freeze
    end

    module Preparation
      PENDING = 'pending'
      PREPARED = 'prepared'
      FAILED = 'failed'
      STATES = [PENDING, PREPARED, FAILED].freeze
    end

    module Result
      PENDING = 'pending'
      SUCCESSFUL = 'successful'
      FAILED = 'failed'
      CANCELLED = 'cancelled'
      STATES = [PENDING, SUCCESSFUL, FAILED, CANCELLED].freeze
    end

    module AapStatus
      ACTIVE = %w[new pending queued waiting running].freeze
      CANCELLED_STATUS = 'cancelled'
      CANCELLED = ['canceled', CANCELLED_STATUS].freeze
      SUCCESSFUL = 'successful'
    end

    STATES_BY_ATTRIBUTE = {
      aggregate_state: Aggregate::STATES,
      workflow_state: Workflow::STATES,
      preparation_state: Preparation::STATES,
      result_state: Result::STATES,
    }.freeze

    # Maps a state list (e.g. Aggregate::STATES) onto an ActiveRecord `enum`
    # values hash: { pending: 'pending', ... }
    def self.enum_values(states)
      states.index_by(&:to_sym)
    end

    # Transitions the given state column, guarding against typos before the
    # record's `enum` validation would raise anyway. Keeps the guard for plain
    # non-ActiveRecord doubles used in tests.
    def self.transition!(record, attribute, to:, **attributes)
      states = STATES_BY_ATTRIBUTE.fetch(attribute) do
        raise ArgumentError, "Unknown lifecycle attribute #{attribute.inspect}"
      end
      raise ArgumentError, "Invalid #{attribute} #{to.inspect}" unless states.include?(to)

      record.update!({ attribute => to }.merge(attributes))
    end
  end
end
