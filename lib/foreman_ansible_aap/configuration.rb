# frozen_string_literal: true

module ForemanAnsibleAap
  # Maps each Configuration field to the plugin setting that stores it.
  # The Struct members below are derived from these keys, so a field is
  # declared exactly once here and once in register.rb's settings block.
  CONFIGURATION_SETTING_NAMES = {
    controller_url: :aap_controller_url,
    service_token: :aap_service_token,
    ca_bundle: :aap_ca_bundle,
    job_template_id: :aap_job_template_id,
    inventory_id: :aap_inventory_id,
    project_id: :aap_project_id,
    repository_url: :aap_repository_url,
    base_ref: :aap_repository_base_ref,
    playbook_path: :aap_generated_playbook_path,
    instance_id: :aap_instance_id,
    git_username: :aap_git_username,
    git_password: :aap_git_password,
  }.freeze

  Configuration = Struct.new(*CONFIGURATION_SETTING_NAMES.keys, keyword_init: true) do
    class << self
      def from_settings
        new(**CONFIGURATION_SETTING_NAMES.transform_values { |setting| Setting[setting] })
      end
    end
  end
end
