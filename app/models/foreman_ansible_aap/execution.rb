# frozen_string_literal: true

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation
    has_many :host_executions, dependent: :destroy

    validates :job_invocation_id, uniqueness: true
    validates :aggregate_state, inclusion: { in: %w[pending running successful failed skipped] }
  end
end
