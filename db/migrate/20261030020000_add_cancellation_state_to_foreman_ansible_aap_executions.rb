# frozen_string_literal: true

class AddCancellationStateToForemanAnsibleAapExecutions < ActiveRecord::Migration[7.0]
  def change
    change_table :foreman_ansible_aap_executions, bulk: true do |table|
      table.string :workflow_state, null: false, default: 'pending'
      table.datetime :cancellation_requested_at
      table.datetime :cancellation_sent_at
    end
  end
end
