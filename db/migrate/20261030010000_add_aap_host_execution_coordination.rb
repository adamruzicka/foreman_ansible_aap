# frozen_string_literal: true

class AddAapHostExecutionCoordination < ActiveRecord::Migration[7.0]
  def change
    add_column :foreman_ansible_aap_executions, :aggregate_state, :string,
      null: false, default: 'pending'
    add_column :foreman_ansible_aap_executions, :aggregate_error, :text

    create_table :foreman_ansible_aap_host_executions do |table|
      table.references :execution, null: false,
        foreign_key: { to_table: :foreman_ansible_aap_executions },
        index: false
      table.references :host, null: false, foreign_key: true
      table.references :template_invocation, null: false, foreign_key: true,
        index: { unique: true, name: 'index_aap_host_executions_on_template_invocation_id' }
      table.string :preparation_state, null: false, default: 'pending'
      table.text :preparation_error
      table.string :result_state, null: false, default: 'pending'
      table.text :result_error
      table.timestamps
    end

    add_index :foreman_ansible_aap_host_executions, %i[execution_id host_id],
      unique: true, name: 'index_aap_host_executions_on_execution_and_host'
  end
end
