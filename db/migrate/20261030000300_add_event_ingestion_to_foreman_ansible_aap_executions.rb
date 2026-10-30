# frozen_string_literal: true

class AddEventIngestionToForemanAnsibleAapExecutions < ActiveRecord::Migration[7.0]
  def change
    change_table :foreman_ansible_aap_executions, bulk: true do |table|
      table.bigint :event_cursor
      table.text :event_diagnostics, null: false, default: '[]'
    end
  end
end
