# frozen_string_literal: true

require 'open3'
require 'minitest/autorun'

class DocumentationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SETUP_GUIDE = File.join(ROOT, 'docs', 'experimental-aap.md')
  LIVE_SCENARIO = File.join(ROOT, 'docs', 'aap-2.6-live-integration.md')
  EVIDENCE_HELPER = File.join(ROOT, 'script', 'aap-live-evidence')
  SETTING_NAMES = %w[
    ansible_execution_driver
    aap_controller_url
    aap_service_token
    aap_ca_bundle
    aap_job_template_id
    aap_inventory_id
    aap_project_id
    aap_repository_url
    aap_repository_base_ref
    aap_generated_playbook_path
    aap_instance_id
    aap_git_username
    aap_git_password
  ].map { |name| "`#{name}`" }.freeze
  PUBLIC_CONTRACT = [
    '`foreman_ansible >= 18.0, < 19`',
    '`foreman_remote_execution >= 17.2, < 18`',
    '`foreman/<instance-id>/job-invocation-<id>`',
    '`generated/foreman.yml`',
    '`foreman_instance_id`',
    '`foreman_job_invocation_id`',
  ].freeze
  SAFETY_WARNINGS = [
    'experimental and is not production-ready',
    'Smart Proxy driver remains the default',
    'must not contain secrets',
    'does not proactively detect every incompatible template',
    'must exactly equal the AAP `inventory_hostname`',
    'Ansible limit is not a security sandbox',
    'AAP might still be executing',
    'no automatic fallback',
    'not been validated against a live AAP 2.6 deployment',
  ].freeze
  LIVE_OBSERVATIONS = [
    'Project update-on-launch',
    'inventory update-on-launch',
    'exact primary-host limit',
    'partial preparation failure',
    'zero prepared hosts',
    'missing inventory host',
    'mixed host outcomes',
    'restart Foreman',
    'failed-host rerun',
    'delegated task',
    'whole-job cancellation',
    'ambiguous launch',
    'Do not mark the POC production-ready',
  ].freeze

  def test_setup_guide_documents_the_public_configuration_contract
    assert_mentions SETUP_GUIDE, SETTING_NAMES + PUBLIC_CONTRACT
  end

  def test_setup_guide_states_the_experimental_boundary_and_required_safety_warnings
    assert_mentions SETUP_GUIDE, SAFETY_WARNINGS
  end

  def test_live_scenario_is_standalone_and_covers_the_required_observations
    assert_mentions LIVE_SCENARIO, LIVE_OBSERVATIONS
  end

  def test_live_evidence_helper_has_valid_shell_syntax_and_a_usable_help_interface
    _stdout, stderr, status = Open3.capture3('bash', '-n', EVIDENCE_HELPER)
    assert status.success?, stderr

    stdout, stderr, status = Open3.capture3('bash', EVIDENCE_HELPER, '--help')
    assert status.success?, stderr
    assert_includes stdout, 'AAP_CONTROLLER_URL'
    assert_includes stdout, 'AAP_JOB_ID'
  end

  private

  def assert_mentions(path, expected_phrases)
    content = File.read(path).gsub(/\s+/, ' ')
    expected_phrases.each { |phrase| assert_includes content, phrase }
  end
end
