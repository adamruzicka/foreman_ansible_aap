# frozen_string_literal: true

class CreateForemanAnsibleAapExecutions < ActiveRecord::Migration[7.0]
  def change
    create_table :foreman_ansible_aap_executions do |table|
      table.references :job_invocation, null: false, foreign_key: true,
        index: { unique: true, name: 'index_aap_executions_on_job_invocation_id' }
      table.string :repository_url
      table.string :scm_ref
      table.string :commit_sha
      table.bigint :aap_job_id
      table.string :aap_job_url
      table.timestamps
    end
  end
end
