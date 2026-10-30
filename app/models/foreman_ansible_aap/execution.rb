# frozen_string_literal: true

require 'json'

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation
    has_many :host_executions, dependent: :destroy

    validates :job_invocation_id, uniqueness: true
    validates :aggregate_state, inclusion: { in: %w[pending running successful failed skipped] }

    def event_diagnostics
      JSON.parse(self[:event_diagnostics].presence || '[]')
    end
  end
end
