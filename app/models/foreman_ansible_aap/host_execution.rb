# frozen_string_literal: true

module ForemanAnsibleAap
  class HostExecution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_host_executions'

    belongs_to :execution
    belongs_to :host, class_name: 'Host::Managed'
    belongs_to :template_invocation

    validates :host_id, uniqueness: { scope: :execution_id }
    validates :template_invocation_id, uniqueness: true
    validates :preparation_state, inclusion: { in: %w[pending prepared failed] }
    validates :result_state, inclusion: { in: %w[pending successful failed] }

    scope :prepared, -> { where(preparation_state: 'prepared') }
  end
end
