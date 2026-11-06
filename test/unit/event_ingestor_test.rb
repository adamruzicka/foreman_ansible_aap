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

  test 'stores each stdout line as its own event so the output viewer numbers lines correctly' do
    stdout = "first line\n\nsecond line\n"

    ingest(AapClient.new([event(41, stdout, host_name: @host.name)]))

    assert_equal ['first line', '', 'second line'], output_events.map(&:event)
    assert_equal stdout, "#{output_events.map(&:event).join("\n")}\n"
  end

  test 'never wraps a line in the middle of an ANSI escape sequence' do
    stdout = "\e[0;32m#{'x' * 300}\e[0m"

    ingest(AapClient.new([event(41, stdout, host_name: @host.name)]))

    stored = output_events.map(&:event)
    assert stored.all? { |chunk| chunk.length <= 255 }
    # no event may end in the middle of an escape sequence
    assert_not stored.any? { |chunk| chunk.match?(/\e\[[0-9;]*\z/) }
    assert_equal stdout, stored.join
  end

  test 'renders exactly one blank line before heading events, matching AAP output' do
    ingest(AapClient.new([
      event(41, "Identity added: /runner/artifacts/86/ssh_key_data (root@ip-10-0-168-24)\r\n", host_name: nil),
      event(42, "\r\n\e[1;35mPLAY [all] *****\e[0m\r\n\r\n", host_name: nil),
      event(43, "\r\n\e[1;36mTASK [Gathering Facts] ***\e[0m\r\n", host_name: nil),
      event(44, "\r\n\r\nPLAY RECAP *****\r\nip-10-0-167-36 : ok=3 changed=1\r\n", host_name: nil),
    ]))

    assert_equal [
      'Identity added: /runner/artifacts/86/ssh_key_data (root@ip-10-0-168-24)',
      '',
      "\e[1;35mPLAY [all] *****\e[0m",
      '',
      "\e[1;36mTASK [Gathering Facts] ***\e[0m",
      '',
      'PLAY RECAP *****',
      'ip-10-0-167-36 : ok=3 changed=1',
    ], output_events.map(&:event)
  end

  test 'stored timestamps strictly increase so the output viewer cannot reorder lines' do
    base = '2026-11-05T18:44:30.640301Z'
    ingest(AapClient.new([
      event(41, "first\n", host_name: @host.name, timestamp: base),
      event(42, "second\nthird\n", host_name: @host.name, timestamp: base),
      event(43, "fourth\n", host_name: @host.name, timestamp: base),
    ]))

    timestamps = output_events.map(&:timestamp)
    assert_equal timestamps.sort, timestamps
    assert_equal timestamps.uniq, timestamps
  end

  test 'fans hostless playbook events out to every host invocation' do
    other_host = FactoryBot.create(:host, name: 'other.example.test')
    other_invocation = FactoryBot.create(:template_invocation, job_invocation: @job_invocation, host: other_host)

    ingest(AapClient.new([
      event(41, "PLAY [all] *****\n", host_name: nil),
      event(42, "TASK [Gathering Facts] ***\n", host_name: nil),
      event(43, 'ok: [node.example.test]', host_name: @host.name),
    ]), invocations: [@template_invocation, other_invocation])

    node_output = output_events(@template_invocation).map(&:event)
    other_output = output_events(::TemplateInvocation.find_by(host: other_host)).map(&:event)
    assert_equal ['', 'PLAY [all] *****', '', 'TASK [Gathering Facts] ***', 'ok: [node.example.test]'], node_output
    assert_equal ['', 'PLAY [all] *****', '', 'TASK [Gathering Facts] ***'], other_output
    assert_equal 43, @execution.reload.event_cursor

    # a restart must not duplicate the fanned-out events
    ingest(AapClient.new([event(42, "TASK [Gathering Facts] ***\n", host_name: nil)]),
           invocations: [@template_invocation, other_invocation])

    assert_equal 5, output_events(@template_invocation).count
  end

  test 'orders output by AAP event counter even when events arrive across separate polls' do
    # job 94 pattern: the hostname result (counter 15) was visible in the
    # first poll, while the earlier Hello result (counter 9) only arrived in
    # the second poll; counter-encoded timestamps keep the display order
    ingest(AapClient.new([event(126, "ok: hostname\r\n", host_name: @host.name, counter: 15)]))
    ingest(AapClient.new([event(129, "ok: Hello\r\n", host_name: @host.name, counter: 9)]))

    assert_equal ['ok: Hello', 'ok: hostname'], output_events.map(&:event)
  end

  test 'fans the play recap out keeping only the invoking host recap line' do
    other_host = FactoryBot.create(:host, name: 'other.example.test')
    other_invocation = FactoryBot.create(:template_invocation, job_invocation: @job_invocation, host: other_host)
    # the :host factory sequences hostname, so the actual names may differ from
    # the requested ones; build the recap from the real names
    recap = "\r\nPLAY RECAP *****\r\n" \
            "\e[0;32m#{@host.name}\e[0m : \e[0;32mok=4\e[0m changed=0\r\n" \
            "\e[0;31m#{other_host.name}\e[0m : \e[0;31mok=2\e[0m failed=1\r\n"

    ingest(AapClient.new([event(41, recap, host_name: nil)]),
           invocations: [@template_invocation, other_invocation])

    assert_equal [
      '',
      'PLAY RECAP *****',
      "\e[0;32m#{@host.name}\e[0m : \e[0;32mok=4\e[0m changed=0",
    ], output_events.map(&:event)

    assert_equal [
      '',
      'PLAY RECAP *****',
      "\e[0;31m#{other_host.name}\e[0m : \e[0;31mok=2\e[0m failed=1",
    ], other_invocation.template_invocation_events.order(:timestamp, :id).map(&:event)
  end

  test 'does not drop lower-id events that follow a higher-id event in line order' do
    # job 94 pattern: event 132 (start_line 13) is persisted before events
    # 128/126/130 (start_line 16/18/21); the cursor must not make the ingestor
    # treat the later-line, lower-id events as already ingested
    ingest(AapClient.new([
      event(132, "ok: => { \"World\" }\r\n", host_name: @host.name, start_line: 13, end_line: 16),
      event(128, "\r\nTASK [debug] ***\r\n", host_name: nil, start_line: 16, end_line: 18),
      event(126, "ok: => { \"hostname\" }\r\n", host_name: @host.name, start_line: 18, end_line: 21),
      event(130, "\r\nPLAY RECAP ***\r\n\r\n", host_name: nil, start_line: 21, end_line: 25),
    ]))

    assert_equal [
      'ok: => { "World" }',
      '',
      'TASK [debug] ***',
      'ok: => { "hostname" }',
      '',
      'PLAY RECAP ***',
    ], output_events.map(&:event)
    assert_equal 132, @execution.reload.event_cursor
  end

  test 'stores events in AAP output line order, which differs from event id order' do
    # real shape of AAP job 90: later-arriving events can address earlier
    # output lines, e.g. the facts result (start_line 5) got id 110 while
    # the TASK header after it (start_line 6) got id 114
    ingest(AapClient.new([
      event(108, "ok: => { \"Hello\" }\r\n", host_name: @host.name, start_line: 8, end_line: 11),
      event(109, "ok: World\r\n", host_name: @host.name, start_line: 11, end_line: 13),
      event(110, "ok: [node.example.test]\r\n", host_name: @host.name, start_line: 5, end_line: 6),
      event(114, "\r\nTASK [debug] ***\r\n", host_name: nil, start_line: 6, end_line: 8),
    ]))

    assert_equal [
      'ok: [node.example.test]',
      '',
      'TASK [debug] ***',
      'ok: => { "Hello" }',
      'ok: World',
    ], output_events.map(&:event)
  end

  test 'stores events in AAP event id order regardless of the order they were fetched' do
    ingest(AapClient.new([
      event(43, 'third', host_name: @host.name),
      event(41, 'first', host_name: @host.name),
      event(42, 'second', host_name: @host.name),
    ]))

    assert_equal %w[first second third], output_events.map(&:event)
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

  def ingest(client, invocations: [@template_invocation])
    ForemanAnsibleAap::EventIngestor.new(
      execution_record: @execution,
      template_invocations: invocations,
      aap_client: client
    ).ingest(91)
  end

  def output_events(invocation = @template_invocation)
    invocation.template_invocation_events.order(:timestamp, :id).to_a
  end

  def event(id, stdout, host_name:, remote_addr: nil, timestamp: nil, start_line: nil, end_line: nil, counter: nil)
    {
      id: id,
      stdout: stdout,
      timestamp: timestamp || format('2026-10-30T09:%02d:%02dZ', id / 60, id % 60),
      host_name: host_name,
      remote_addr: remote_addr,
      start_line: start_line,
      end_line: end_line,
      counter: counter,
    }
  end
end
