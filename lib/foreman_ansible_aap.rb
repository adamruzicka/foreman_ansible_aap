# frozen_string_literal: true

require 'foreman_ansible'
require 'foreman_remote_execution'
require 'foreman_ansible_aap/configuration'
require 'foreman_ansible_aap/host_outcome_reconciler'
require 'foreman_ansible_aap/aggregate_execution'
require 'foreman_ansible_aap/aap_client'
require 'foreman_ansible_aap/event_ingestor'
require 'foreman_ansible_aap/git_publisher'
require 'foreman_ansible_aap/playbook_renderer'
require 'foreman_ansible_aap/result_settler'
require 'foreman_ansible_aap/execution_driver'
require 'foreman_ansible_aap/engine'

module ForemanAnsibleAap
end

ForemanAnsible.execution_drivers.register(:aap, ForemanAnsibleAap::ExecutionDriver)
