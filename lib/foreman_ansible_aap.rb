# frozen_string_literal: true

require 'foreman_ansible'
require 'foreman_remote_execution'
require 'foreman_ansible_aap/execution_driver'
require 'foreman_ansible_aap/engine'

module ForemanAnsibleAap
end

ForemanAnsible.execution_drivers.register(:aap, ForemanAnsibleAap::ExecutionDriver)
