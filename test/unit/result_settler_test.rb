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

  test 'cancellation is a durable host outcome with a cancelled exit event' do
    invocation = FactoryBot.create(:job_invocation, :with_template)
    template_invocation = invocation.pattern_template_invocations.first.deep_clone
    host = FactoryBot.create(:host)
    template_invocation.update!(host: host)
    execution = ForemanAnsibleAap::Execution.create!(job_invocation: invocation)
    record = ForemanAnsibleAap::HostExecution.create!(
      execution: execution,
      host: host,
      template_invocation: template_invocation,
      preparation_state: 'prepared'
    )

    ForemanAnsibleAap::ResultSettler.new([record]).cancelled!(host)

    assert_equal 'cancelled', record.reload.result_state
    assert_equal 'AAP job cancellation left this host unfinished', record.result_error
    assert_equal '1', template_invocation.template_invocation_events.find_by(event_type: 'exit').event
  end

  test 'exit and diagnostic events render after all stored output lines' do
    invocation = FactoryBot.create(:job_invocation, :with_template)
    template_invocation = invocation.pattern_template_invocations.first.deep_clone
    host = FactoryBot.create(:host)
    template_invocation.update!(host: host)
    execution = ForemanAnsibleAap::Execution.create!(job_invocation: invocation)
    record = ForemanAnsibleAap::HostExecution.create!(
      execution: execution,
      host: host,
      template_invocation: template_invocation,
      preparation_state: 'prepared'
    )
    # synthetic counter-based output timestamps can run past wall-clock time
    future = Time.zone.now + 5.minutes
    template_invocation.template_invocation_events.create!(
      external_id: 'aap-job-91-event-1-chunk-0',
      event: 'PLAY RECAP',
      event_type: 'stdout',
      timestamp: future
    )

    ForemanAnsibleAap::ResultSettler.new([record]).success!(host)

    exit_event = template_invocation.template_invocation_events.find_by(event_type: 'exit')
    assert exit_event.timestamp > future,
           'exit event must sort after synthetic output timestamps'
  end

  test 'does not corrupt a persisted host outcome when settlement is replayed after restart' do
    invocation = FactoryBot.build(:job_invocation)
    template_invocation = FactoryBot.build(
      :template_invocation, :with_task, :with_host, job_invocation: invocation
    )
    invocation.template_invocations = [template_invocation]
    invocation.save!
    execution = ForemanAnsibleAap::Execution.create!(job_invocation: invocation)
    record = ForemanAnsibleAap::HostExecution.create!(
      execution: execution,
      host: template_invocation.host,
      template_invocation: template_invocation,
      preparation_state: 'prepared'
    )

    ForemanAnsibleAap::ResultSettler.new([record]).success!(template_invocation.host)
    restarted_settler = ForemanAnsibleAap::ResultSettler.new([record.reload])
    restarted_settler.failure!(template_invocation.host, diagnostic: 'stale replay')

    events = template_invocation.template_invocation_events.reload
    assert_equal 1, events.where(external_id: 'aap-host-summary-exit').count
    assert_equal '0', events.find_by(external_id: 'aap-host-summary-exit').event
    assert_nil events.find_by(external_id: 'aap-host-summary-diagnostic')
    assert_equal 'successful', record.reload.result_state
    assert_nil record.result_error
  end
end
