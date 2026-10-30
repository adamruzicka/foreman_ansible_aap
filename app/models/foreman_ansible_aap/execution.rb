# frozen_string_literal: true

module ForemanAnsibleAap
  class Execution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_executions'

    belongs_to :job_invocation

    validates :job_invocation_id, uniqueness: true
  end
end
