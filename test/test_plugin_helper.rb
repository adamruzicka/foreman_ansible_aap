# frozen_string_literal: true

# This calls the main test_helper in Foreman-core
require 'test_helper'
require 'dynflow/testing'

# Add plugin to FactoryBot's paths
FactoryBot.definition_file_paths << "#{ForemanTasks::Engine.root}/test/factories"
FactoryBot.definition_file_paths << "#{ForemanRemoteExecution::Engine.root}/test/factories"
FactoryBot.reload
