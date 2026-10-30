# frozen_string_literal: true

require 'test_plugin_helper'

class LifecycleTest < ActiveSupport::TestCase
  Record = Struct.new(:attributes) do
    def update!(changes)
      attributes.merge!(changes)
    end
  end

  test 'transitions only to centralized states for each persisted lifecycle' do
    record = Record.new({})

    ForemanAnsibleAap::Lifecycle.transition!(
      record,
      :workflow_state,
      to: ForemanAnsibleAap::Lifecycle::Workflow::POLLING
    )

    assert_equal 'polling', record.attributes.fetch(:workflow_state)
    assert_raises(ArgumentError) do
      ForemanAnsibleAap::Lifecycle.transition!(record, :workflow_state, to: 'pollng')
    end
    assert_raises(ArgumentError) do
      ForemanAnsibleAap::Lifecycle.transition!(record, :unknown_state, to: 'pending')
    end
  end
end
