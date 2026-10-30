# frozen_string_literal: true

class AddObservationStateToForemanAnsibleAapExecutions < ActiveRecord::Migration[7.0]
  def change
    change_table :foreman_ansible_aap_executions, bulk: true do |table|
      table.string :aap_status
      table.integer :polling_failure_count, null: false, default: 0
      table.text :polling_failure_diagnostic
      table.boolean :output_incomplete, null: false, default: false
      table.text :output_failure_diagnostic
    end
  end
end
