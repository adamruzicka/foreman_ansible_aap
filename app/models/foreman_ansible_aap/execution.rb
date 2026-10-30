# frozen_string_literal: true

require 'json'

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation

    validates :job_invocation_id, uniqueness: true

    def event_diagnostics
      JSON.parse(self[:event_diagnostics].presence || '[]')
    end
  end
end
