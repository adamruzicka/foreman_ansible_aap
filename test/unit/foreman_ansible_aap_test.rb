# frozen_string_literal: true

require 'test_plugin_helper'

class ForemanAnsibleAapTest < ActiveSupport::TestCase
  test 'registers AAP resource identifiers as integer settings' do
    %w[aap_job_template_id aap_inventory_id aap_project_id].each do |name|
      definition = Foreman::SettingManager.settings.fetch(name)
      assert_equal :integer, definition[:type], name
    end
  end

  test 'registers the AAP adapter through the Foreman Ansible registry' do
    assert_equal ForemanAnsibleAap::ExecutionDriver,
      ForemanAnsible.execution_drivers.fetch(:aap)
  end

  test 'selects the AAP-owned aggregate action tree without a Smart Proxy fallback' do
    invocation = stub(ansible_execution_driver: 'aap')

    assert_equal Actions::ForemanAnsibleAap::RunHostsJob,
      ForemanAnsible::AnsibleProvider.execution_action(invocation)
  end
end
