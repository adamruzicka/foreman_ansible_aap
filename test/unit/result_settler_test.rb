# frozen_string_literal: true

require 'test_plugin_helper'

class ResultSettlerTest < ActiveSupport::TestCase
  test 'host task results drive existing successful and failed host selection' do
    invocation = FactoryBot.build(:job_invocation)
    invocation.task = FactoryBot.build(:some_task, started_at: Time.zone.now)
    successful = FactoryBot.build(:template_invocation, :with_task, :with_host, job_invocation: invocation)
    failed = FactoryBot.build(:template_invocation, :with_task, :with_host, job_invocation: invocation)
    invocation.template_invocations = [successful, failed]
    invocation.targeting.hosts = [successful.host, failed.host]
    invocation.targeting.mark_resolved!
    invocation.targeting.save!
    invocation.save!
    successful.run_host_job_task.update!(parent_task: invocation.task)
    failed.run_host_job_task.update!(parent_task: invocation.task)
    settler = ForemanAnsibleAap::ResultSettler.new(invocation.template_invocations.includes(:host))

    settler.success!(successful.host)
    settler.failure!(failed.host, diagnostic: 'AAP reported this host as unreachable')
    invocation.reload

    assert_equal [successful.host.id], invocation.succeeded_host_ids
    assert_equal [failed.host.id], invocation.failed_host_ids
    assert_equal 1, invocation.progress_report[:success]
    assert_equal 1, invocation.progress_report[:error]
    assert_equal 1, invocation.progress_report[:failed]
    assert_equal 100, invocation.progress_report[:progress]
    assert_equal '0', successful.template_invocation_events.find_by(event_type: 'exit').event
    assert_equal '1', failed.template_invocation_events.find_by(event_type: 'exit').event
    diagnostic = failed.template_invocation_events.find_by(event_type: 'stdout')
    assert_equal 'AAP reported this host as unreachable', diagnostic.event
  end
end
