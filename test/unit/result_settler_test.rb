# frozen_string_literal: true

require 'test_plugin_helper'

class ResultSettlerTest < ActiveSupport::TestCase
  test 'host outcomes are durable until waiting host tasks consume them' do
    invocation = FactoryBot.build(:job_invocation)
    successful = FactoryBot.build(:template_invocation, :with_task, :with_host, job_invocation: invocation)
    failed = FactoryBot.build(:template_invocation, :with_task, :with_host, job_invocation: invocation)
    invocation.template_invocations = [successful, failed]
    invocation.targeting.hosts = [successful.host, failed.host]
    invocation.targeting.mark_resolved!
    invocation.targeting.save!
    invocation.save!
    execution = ForemanAnsibleAap::Execution.create!(job_invocation: invocation)
    records = [successful, failed].map do |template_invocation|
      ForemanAnsibleAap::HostExecution.create!(
        execution: execution,
        host: template_invocation.host,
        template_invocation: template_invocation,
        preparation_state: 'prepared'
      )
    end
    settler = ForemanAnsibleAap::ResultSettler.new(records)

    settler.success!(successful.host)
    settler.failure!(failed.host, diagnostic: 'AAP reported this host as unreachable')

    assert_equal 'successful', records.first.reload.result_state
    assert_equal 'failed', records.last.reload.result_state
    assert_equal 'AAP reported this host as unreachable', records.last.result_error
    assert_equal '0', successful.template_invocation_events.find_by(event_type: 'exit').event
    assert_equal '1', failed.template_invocation_events.find_by(event_type: 'exit').event
    diagnostic = failed.template_invocation_events.find_by(event_type: 'stdout')
    assert_equal 'AAP reported this host as unreachable', diagnostic.event
  end
end
