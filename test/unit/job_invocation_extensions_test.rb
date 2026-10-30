# frozen_string_literal: true

require 'test_plugin_helper'

class JobInvocationExtensionsTest < ActiveSupport::TestCase
  setup do
    template = FactoryBot.create(:job_template, provider_type: 'Ansible')
    @invocation = FactoryBot.build(:job_invocation)
    @invocation.pattern_template_invocations << FactoryBot.build(:template_invocation, template: template)
    @invocation.ansible_execution_driver = 'aap'
    @invocation.save!
  end

  test 'AAP invocations expose their persisted execution diagnostics' do
    execution = ForemanAnsibleAap::Execution.create!(
      job_invocation: @invocation,
      aap_job_id: 91,
      aap_job_url: 'https://aap.example.test/api/controller/v2/jobs/91/'
    )

    assert_equal execution, @invocation.reload.aap_execution
    assert_equal({
      job_id: 91,
      job_url: 'https://aap.example.test/api/controller/v2/jobs/91/',
      limitations: 'Host-filtered cancellation and peripheral task-based integrations are not supported for AAP jobs.',
    }, @invocation.aap_diagnostics)
  end

  test 'AAP invocations reject invocation-scoped proxy and SSH controls' do
    unsupported_controls.each do |attribute, value|
      @invocation.public_send("#{attribute}=", value)

      assert_not @invocation.valid?, "expected #{attribute} to be rejected"
      assert_includes @invocation.errors[:base].join(' '), attribute.to_s.humanize

      @invocation.public_send("#{attribute}=", nil)
    end
  end

  test 'AAP invocations reject an explicitly selected proxy' do
    @invocation.pattern_template_invocations.first.smart_proxy = FactoryBot.create(:smart_proxy)

    assert_not @invocation.valid?
    assert_includes @invocation.errors[:base].join(' '), 'Smart proxy selection'
  end

  test 'AAP invocations reject an explicit effective user override but tolerate the model default' do
    default_user = Setting[:remote_execution_effective_user]
    template_invocation = @invocation.pattern_template_invocations.first
    template_invocation.effective_user = default_user
    assert @invocation.valid?, @invocation.errors.full_messages.join(', ')

    template_invocation.effective_user = 'explicit-aap-override'
    assert_not @invocation.valid?
    assert_includes @invocation.errors[:base].join(' '), 'Effective user'
  end

  test 'AAP invocations reject proxy-only Ansible provider inputs' do
    @invocation.pattern_template_invocations.first.provider_input_values.build(
      name: 'tags', value: 'production'
    )

    assert_not @invocation.valid?
    assert_includes @invocation.errors[:base].join(' '), 'provider options'
  end

  test 'proxy-backed Ansible invocations retain their existing controls' do
    @invocation.ansible_execution_driver = 'proxy'
    @invocation.ssh_user = 'automation'
    @invocation.password = 'secret'
    @invocation.concurrency_level = 2

    assert @invocation.valid?, @invocation.errors.full_messages.join(', ')
  end

  test 'non-Ansible invocations retain their existing controls' do
    invocation = FactoryBot.build(:job_invocation, :with_template, ssh_user: 'automation')
    invocation.password = 'secret'

    assert invocation.valid?, invocation.errors.full_messages.join(', ')
  end

  private

  def unsupported_controls
    {
      ssh_user: 'automation',
      password: 'secret',
      key_passphrase: 'secret',
      effective_user_password: 'secret',
      concurrency_level: 2,
    }
  end
end
