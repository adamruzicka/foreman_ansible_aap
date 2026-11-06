# frozen_string_literal: true

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation
    has_many :host_executions, dependent: :destroy

    validates :job_invocation_id, uniqueness: true

    enum aggregate_state: Lifecycle.enum_values(Lifecycle::Aggregate::STATES), _prefix: :aggregate
    enum workflow_state: Lifecycle.enum_values(Lifecycle::Workflow::STATES), _prefix: :workflow

    # Diagnostics are stored as a JSON array in a text column; the :json
    # attribute type handles encoding/decoding transparently.
    attribute :event_diagnostics, :json

    def event_diagnostics
      super || []
    end
  end
end
