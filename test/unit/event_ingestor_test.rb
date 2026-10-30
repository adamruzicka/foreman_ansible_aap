# frozen_string_literal: true

require 'test_plugin_helper'

class EventIngestorTest < ActiveSupport::TestCase
  class AapClient
    attr_reader :after_ids

    def initialize(events)
      @events = events
      @after_ids = []
    end

    def job_events(_job_id, after_id:)
      @after_ids << after_id
      @events
    end
  end

  setup do
    @job_invocation = FactoryBot.create(:job_invocation)
    @host = FactoryBot.create(:host, name: 'node.example.test')
    @template_invocation = FactoryBot.create(
      :template_invocation,
      job_invocation: @job_invocation,
      host: @host
    )
    @execution = ForemanAnsibleAap::Execution.create!(job_invocation: @job_invocation)
  end

  test 'persists mapped output and unmapped diagnostics exactly once across a restart' do
    first_client = AapClient.new(first_poll_events)

    ingest(first_client)

    assert_equal ['host output', 'delegated output'], output_events.map(&:event)
    assert_equal %w[
      aap-job-91-event-41-chunk-0
      aap-job-91-event-42-chunk-0
    ], output_events.map(&:external_id)
    assert_equal [
      {
        'external_id' => 'aap-job-91-event-43',
        'host_name' => 'outside.example.test',
        'output' => 'playbook diagnostic',
        'timestamp' => '2026-10-30T09:00:43Z',
      },
    ], @execution.reload.event_diagnostics
    assert_equal 1, @job_invocation.template_invocations.count
    assert_equal 43, @execution.event_cursor

    restarted_client = AapClient.new(restarted_poll_events)
    @execution = ForemanAnsibleAap::Execution.find(@execution.id)

    ingest(restarted_client)

    assert_equal [43], restarted_client.after_ids
    assert_equal ['host output', 'delegated output', 'after restart'], output_events.map(&:event)
    assert_equal 1, @execution.reload.event_diagnostics.size
    assert_equal 44, @execution.event_cursor
  end

  test 'splits long UTF-8 output into stable events accepted by the existing output table' do
    stdout = 'é' * 256

    ingest(AapClient.new([event(41, stdout, host_name: @host.name)]))

    assert_equal [255, 1], (output_events.map { |stored_event| stored_event.event.length })
    assert_equal stdout, output_events.map(&:event).join
    assert_equal %w[
      aap-job-91-event-41-chunk-0
      aap-job-91-event-41-chunk-1
    ], output_events.map(&:external_id)
  end

  private

  def first_poll_events
    [
      event(41, 'host output', host_name: @host.name),
      event(42, 'delegated output', host_name: @host.name, remote_addr: 'delegate.example.test'),
      event(43, 'playbook diagnostic', host_name: 'outside.example.test'),
      event(43, 'playbook diagnostic', host_name: 'outside.example.test'),
    ]
  end

  def restarted_poll_events
    [
      event(42, 'delegated output', host_name: @host.name),
      event(43, 'playbook diagnostic', host_name: 'outside.example.test'),
      event(44, 'after restart', host_name: @host.name),
    ]
  end

  def ingest(client)
    ForemanAnsibleAap::EventIngestor.new(
      execution_record: @execution,
      template_invocations: [@template_invocation],
      aap_client: client
    ).ingest(91)
  end

  def output_events
    @template_invocation.template_invocation_events.order(:timestamp).to_a
  end

  def event(id, stdout, host_name:, remote_addr: nil)
    {
      id: id,
      stdout: stdout,
      timestamp: "2026-10-30T09:00:#{id}Z",
      host_name: host_name,
      remote_addr: remote_addr,
    }
  end
end
