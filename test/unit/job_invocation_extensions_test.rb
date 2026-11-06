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
      aap_job_url: 'https://aap.example.test/api/controller/v2/jobs/91/',
      event_diagnostics: [{
        'external_id' => 'aap-job-91-event-7',
        'host_name' => 'delegate.example.test',
        'output' => 'delegated startup output',
        'timestamp' => '2026-10-30T09:00:00Z',
      }],
      output_incomplete: true,
      output_failure_diagnostic: 'AAP output page 2 was unavailable'
    )

    assert_equal execution, @invocation.reload.aap_execution
    assert_equal({
      job_id: 91,
      job_url: 'https://aap.example.test/api/controller/v2/jobs/91/',
      limitations: 'Host-filtered cancellation and peripheral task-based integrations are not supported for AAP jobs.',
      invocation_diagnostics: [{
        'external_id' => 'aap-job-91-event-7',
        'host_name' => 'delegate.example.test',
        'output' => 'delegated startup output',
        'timestamp' => '2026-10-30T09:00:00Z',
      }],
      output_incomplete: true,
      output_failure_diagnostic: 'AAP output page 2 was unavailable',
    }, @invocation.aap_diagnostics)
  end

  test 'AAP invocations reject invocation-scoped proxy and SSH controls' do
    unsupported_controls.each do |attribute, value|
      @invocation.public_send("#{attribute}=", value)

      assert_not @invocation.valid?, "expected #{attribute} to be rejected"
      assert_includes @invocation.errors[:base].join(' '), 'not supported by the AAP execution driver'

      @invocation.public_send("#{attribute}=", nil)
    end
  end

  test 'raw API parameters and invocation models share one unsupported-control policy' do
    @invocation.ssh_user = 'proxy-managed-user'
    model_messages = ForemanAnsibleAap::UnsupportedControls.new(@invocation).messages

    parameter_messages = ForemanAnsibleAap::UnsupportedControls.for_params(
      { ssh_user: 'proxy-managed-user' },
      aap: true
    ).messages

    assert_equal model_messages, parameter_messages
    assert_equal ['SSH user is not supported by the AAP execution driver'], parameter_messages
  end

  test 'raw parameters and invocation models permit the same inherited controls' do
    template = @invocation.pattern_template_invocations.first.template
    template.update!(execution_timeout_interval: 30)
    default_user = Setting[:remote_execution_effective_user]
    @invocation.pattern_template_invocations.first.effective_user = default_user
    @invocation.execution_timeout_interval = 30

    model_messages = ForemanAnsibleAap::UnsupportedControls.new(@invocation).messages
    parameter_messages = ForemanAnsibleAap::UnsupportedControls.for_params(
      {
        ssh: { effective_user: default_user },
        execution_timeout_interval: 30,
      },
      aap: true,
      template: template
    ).messages

    assert_empty model_messages
    assert_equal model_messages, parameter_messages
  end

  test 'AAP invocations reject an explicitly selected proxy' do
    @invocation.pattern_template_invocations.first.smart_proxy = FactoryBot.create(:smart_proxy)

    assert_not @invocation.valid?
    assert_includes @invocation.errors[:base].join(' '), 'selection is not supported by the AAP execution driver'
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

  test 'AAP invocations tolerate the template timeout but reject an invocation override' do
    template = @invocation.pattern_template_invocations.first.template
    template.update!(execution_timeout_interval: 30)
    @invocation.execution_timeout_interval = 30
    assert @invocation.valid?, @invocation.errors.full_messages.join(', ')

    @invocation.execution_timeout_interval = 60
    assert_not @invocation.valid?
    assert_includes @invocation.errors[:base].join(' '), 'Execution timeout'
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
