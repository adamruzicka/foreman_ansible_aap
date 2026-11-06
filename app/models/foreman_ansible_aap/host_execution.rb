# frozen_string_literal: true

module ForemanAnsibleAap
  class HostExecution < ApplicationRecord
    self.table_name = 'foreman_ansible_aap_host_executions'

    belongs_to :execution
    belongs_to :host, class_name: 'Host::Managed'
    belongs_to :template_invocation

    validates :host_id, uniqueness: { scope: :execution_id }
    validates :template_invocation_id, uniqueness: true

    enum preparation_state: Lifecycle.enum_values(Lifecycle::Preparation::STATES), _prefix: :preparation
    enum result_state: Lifecycle.enum_values(Lifecycle::Result::STATES), _prefix: :result
  end
end
