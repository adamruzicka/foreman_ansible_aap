# frozen_string_literal: true

require 'json'

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation
    has_many :host_executions, dependent: :destroy

    validates :job_invocation_id, uniqueness: true
    enum aggregate_state: Lifecycle.enum_values(Lifecycle::Aggregate::STATES), _prefix: :aggregate
    enum workflow_state: Lifecycle.enum_values(Lifecycle::Workflow::STATES), _prefix: :workflow

    def event_diagnostics
      JSON.parse(self[:event_diagnostics].presence || '[]')
    end
  end
end
