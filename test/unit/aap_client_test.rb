# frozen_string_literal: true

require 'test_plugin_helper'

class AapClientTest < ActiveSupport::TestCase
  class Transport
    attr_reader :gets, :posts

    def initialize
      @gets = []
      @posts = []
    end

    def get(path)
      @gets << path
      case path
      when %r{job_templates/7/}
        {
          'project' => 9,
          'inventory' => 8,
          'playbook' => 'generated/foreman.yml',
          'ask_scm_branch_on_launch' => true,
          'ask_limit_on_launch' => true,
          'ask_variables_on_launch' => true,
        }
      when %r{projects/9/}
        { 'scm_url' => 'https://git.example.test/generated.git', 'update_on_launch' => true }
      when %r{inventories/8/inventory_sources/}
        { 'results' => [{ 'update_on_launch' => true }] }
      when %r{inventories/8/}
        { 'id' => 8 }
      when %r{jobs/91/job_host_summaries/.*page=2}
        {
          'next' => nil,
          'results' => [
            { 'host_name' => 'unreachable.example.test', 'failures' => 0, 'dark' => 0, 'unreachable' => true },
          ],
        }
      when %r{jobs/91/job_host_summaries/}
        {
          'next' => 'jobs/91/job_host_summaries/?page=2',
          'results' => [
            { 'host_name' => 'node.example.test', 'failures' => 0, 'dark' => 0 },
          ],
        }
      when %r{jobs/91/}
        { 'status' => 'successful' }
      end
    end

    def post(path, body)
      @posts << [path, body]
      { 'id' => 91, 'url' => '/api/controller/v2/jobs/91/' }
    end

    def absolute_url(path)
      "https://aap.example.test#{path}"
    end
  end

  class EventsTransport < Transport
    def get(path)
      gets << path
      case path
      when 'jobs/91/job_events/?order_by=id&page_size=200&id__gt=40'
        {
          'results' => [{
            'id' => 41,
            'stdout' => 'first page',
            'created' => '2026-10-30T09:00:00Z',
            'event_data' => { 'host' => 'node.example.test' },
          }],
          'next' => '/api/controller/v2/jobs/91/job_events/?id__gt=40&page=2',
        }
      when '/api/controller/v2/jobs/91/job_events/?id__gt=40&page=2'
        {
          'results' => [{
            'id' => 42,
            'stdout' => 'delegated output',
            'created' => '2026-10-30T09:00:01Z',
            'event_data' => {
              'host' => 'node.example.test',
              'remote_addr' => 'delegate.example.test',
            },
          }],
          'next' => nil,
        }
      end
    end
  end

  test 'preflights fixed resources and uses only the narrow launch fields' do
    transport = Transport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )
    contract = {
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      playbook_path: 'generated/foreman.yml',
    }

    assert client.preflight!(contract)
    launched = client.launch(
      job_template_id: 7,
      scm_branch: 'foreman/prod/job-invocation-42',
      limit: 'node.example.test',
      extra_vars: { foreman_job_invocation_id: 42 }
    )

    assert_equal({ id: 91, url: 'https://aap.example.test/api/controller/v2/jobs/91/' }, launched)
    assert_equal [[
      'job_templates/7/launch/',
      {
        'scm_branch' => 'foreman/prod/job-invocation-42',
        'limit' => 'node.example.test',
        'extra_vars' => { foreman_job_invocation_id: 42 },
      },
    ]], transport.posts
    assert_equal 'successful', client.job_status(91)
    assert_equal [
      { host_name: 'node.example.test', successful: true },
      { host_name: 'unreachable.example.test', successful: false },
    ], client.host_summaries(91)
  end

  test 'rejects a controller endpoint without TLS' do
    assert_raises(ForemanAnsibleAap::AapClient::ConfigurationError) do
      ForemanAnsibleAap::AapClient.new(
        controller_url: 'http://aap.example.test', token: 'secret', ca_bundle: nil
      )
    end
  end

  test 'returns every event page and attributes delegated output to the original inventory host' do
    transport = EventsTransport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    events = client.job_events(91, after_id: 40)

    assert_equal [41, 42], (events.map { |event| event.fetch(:id) })
    assert_equal ['node.example.test', 'node.example.test'], (events.map { |event| event.fetch(:host_name) })
    assert_equal ['first page', 'delegated output'], (events.map { |event| event.fetch(:stdout) })
    assert_equal [
      'jobs/91/job_events/?order_by=id&page_size=200&id__gt=40',
      '/api/controller/v2/jobs/91/job_events/?id__gt=40&page=2',
    ], transport.gets
  end

  test 'cancels one persisted AAP job through its job endpoint' do
    transport = Transport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    assert client.cancel!(91)

    assert_equal [['jobs/91/cancel/', {}]], transport.posts
  end
end
