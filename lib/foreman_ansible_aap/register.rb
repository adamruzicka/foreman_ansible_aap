# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
Foreman::Plugin.register :foreman_ansible_aap do
  requires_foreman '>= 5.1'
  register_gettext

  extend_rabl_template 'api/v2/job_invocations/main',
    'foreman_ansible_aap/api/v2/job_invocations/aap'

  extend_page 'job_invocations/show' do |context|
    context.add_pagelet :main_tabs,
      id: :aap_diagnostics,
      name: N_('AAP diagnostics'),
      partial: 'foreman_ansible_aap/job_invocations/diagnostics',
      onlyif: ->(invocation, _) { invocation.aap_diagnostics.present? }
  end

  settings do
    category :ansible, N_('Ansible') do
      setting 'aap_controller_url', type: :string, default: '',
        full_name: N_('AAP controller URL'),
        description: N_('HTTPS base URL of the AAP 2.6 controller API, ending in /api/controller/v2/.')
      setting 'aap_service_token', type: :string, default: '', encrypted: true,
        full_name: N_('AAP service token'),
        description: N_('OAuth bearer token used by Foreman to launch and observe AAP jobs.')
      setting 'aap_ca_bundle', type: :string, default: '',
        full_name: N_('AAP CA bundle'),
        description: N_('CA bundle used to verify the AAP controller TLS certificate.')
      setting 'aap_job_template_id', type: :integer, default: nil,
        full_name: N_('AAP Job Template ID'), description: N_('Fixed AAP Job Template.')
      setting 'aap_inventory_id', type: :integer, default: nil,
        full_name: N_('AAP inventory ID'), description: N_('Fixed Foreman-synchronized AAP inventory.')
      setting 'aap_project_id', type: :integer, default: nil,
        full_name: N_('AAP Project ID'), description: N_('Fixed AAP Project containing generated playbooks.')
      setting 'aap_repository_url', type: :string, default: '',
        full_name: N_('AAP generated-playbook repository'),
        description: N_('Dedicated repository written by Foreman and read by the AAP Project.')
      setting 'aap_repository_base_ref', type: :string, default: 'main',
        full_name: N_('AAP repository base ref'), description: N_('Base ref for invocation artifacts.')
      setting 'aap_generated_playbook_path', type: :string, default: 'generated/foreman.yml',
        full_name: N_('AAP generated playbook path'),
        description: N_('Fixed playbook path selected by the Job Template.')
      setting 'aap_instance_id', type: :string, default: '',
        full_name: N_('Foreman AAP instance identifier'),
        description: N_('Stable namespace used in generated immutable refs.')
      setting 'aap_git_username', type: :string, default: '', encrypted: true,
        full_name: N_('AAP repository username'), description: N_('Encrypted Git publication username.')
      setting 'aap_git_password', type: :string, default: '', encrypted: true,
        full_name: N_('AAP repository password'), description: N_('Encrypted Git publication password or token.')
    end
  end
end
# rubocop:enable Metrics/BlockLength
