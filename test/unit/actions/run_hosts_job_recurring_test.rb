# frozen_string_literal: true

require 'test_plugin_helper'

module ForemanAnsibleAap
  class RunHostsJobRecurringTest < ActiveSupport::TestCase
    setup do
      User.current = users(:admin)
      @original_driver = Setting[:ansible_execution_driver]
    end

    teardown do
      Setting[:ansible_execution_driver] = @original_driver
    end

    test 'each recurring occurrence locks the driver active when it is created' do
      Setting[:ansible_execution_driver] = 'aap'
      first_occurrence = build_invocation
      recurring_logic = ForemanTasks::RecurringLogic.new_from_cronline('* * * * *')
      recurring_logic.state = 'active'
      recurring_logic.save!

      recurring_logic.start_after(
        Actions::ForemanAnsibleAap::RunHostsJob,
        Time.zone.now,
        first_occurrence
      )

      assert_equal 1, recurring_logic.tasks.count
      first_task = recurring_logic.tasks.first
      assert_equal 'aap', first_occurrence.reload.ansible_execution_driver

      Setting[:ansible_execution_driver] = 'proxy'
      first_task.execution_plan.delay_record.plan

      assert_equal 2, recurring_logic.reload.tasks.count
      occurrences = JobInvocation.where(task_id: recurring_logic.tasks.select(:id))
      assert_equal 2, occurrences.count
      second_occurrence = occurrences.where.not(id: first_occurrence.id).sole
      assert_equal 'aap', first_occurrence.reload.ansible_execution_driver
      assert_equal 'proxy', second_occurrence.ansible_execution_driver
    end

    private

    def build_invocation
      host = FactoryBot.create(:host)
      targeting = FactoryBot.create(:targeting, user: User.current)
      targeting.mark_resolved!
      targeting.save!(validate: false)
      targeting.hosts << host
      template = FactoryBot.create(
        :job_template,
        provider_type: 'Ansible',
        template: "---\n- hosts: all\n  tasks: []\n"
      )

      FactoryBot.build(:job_invocation, targeting: targeting).tap do |invocation|
        invocation.description = 'Recurring AAP execution'
        invocation.pattern_template_invocations << FactoryBot.build(
          :template_invocation,
          template: template
        )
        invocation.save!
      end
    end
  end
end
