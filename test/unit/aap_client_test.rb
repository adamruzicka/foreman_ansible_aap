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
      when %r{jobs/91/job_host_summaries/}
        { 'results' => [{ 'host_name' => 'node.example.test', 'failures' => 0, 'dark' => 0 }] }
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

  class IgnoredLaunchTransport < Transport
    def post(path, body)
      posts << [path, body]
      return {} if path == 'jobs/91/cancel/'

      {
        'id' => 91,
        'url' => '/api/controller/v2/jobs/91/',
        'ignored_fields' => { 'scm_branch' => 'foreman/prod/job-invocation-42' },
      }
    end
  end

  class FailingLaunchTransport < Transport
    attr_reader :launch_attempts

    def initialize(error)
      super()
      @error = error
      @launch_attempts = 0
    end

    def post(_path, _body)
      @launch_attempts += 1
      raise @error
    end
  end

  class MismatchedLaunchTransport < Transport
    def post(path, body)
      posts << [path, body]
      return {} if path == 'jobs/91/cancel/'

      {
        'id' => 91,
        'url' => '/api/controller/v2/jobs/91/',
        'scm_branch' => 'main',
        'limit' => body.fetch('limit'),
        'extra_vars' => body.fetch('extra_vars'),
      }
    end
  end

  class InvalidPreflightTransport < Transport
    def initialize(invalid_field)
      super()
      @invalid_field = invalid_field
    end

    def get(path)
      resource = super
      case @invalid_field
      when :project
        resource['project'] = 99 if path.match?(%r{job_templates/7/})
      when :inventory
        resource['inventory'] = 99 if path.match?(%r{job_templates/7/})
      when :playbook
        resource['playbook'] = 'unsafe.yml' if path.match?(%r{job_templates/7/})
      when :repository_url
        resource['scm_url'] = 'https://git.example.test/human-authored.git' if path.match?(%r{projects/9/})
      when :project_update
        resource['update_on_launch'] = false if path.match?(%r{projects/9/})
      when :inventory_update
        resource['results'] = [{ 'update_on_launch' => false }] if path.match?(%r{inventory_sources/})
      else
        resource[@invalid_field.to_s] = false if path.match?(%r{job_templates/7/})
      end
      resource
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
    assert_equal [{ host_name: 'node.example.test', successful: true }], client.host_summaries(91)
  end

  test 'rejects a controller endpoint without TLS' do
    assert_raises(ForemanAnsibleAap::AapClient::ConfigurationError) do
      ForemanAnsibleAap::AapClient.new(
        controller_url: 'http://aap.example.test', token: 'secret', ca_bundle: nil
      )
    end
  end

  test 'rejects every invalid fixed-resource or prompt-on-launch contract' do
    contract = {
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      playbook_path: 'generated/foreman.yml',
    }
    invalid_fields = %i[
      project inventory playbook repository_url project_update inventory_update
      ask_scm_branch_on_launch ask_limit_on_launch ask_variables_on_launch
    ]

    invalid_fields.each do |invalid_field|
      client = ForemanAnsibleAap::AapClient.new(
        controller_url: 'https://unused.example.test',
        token: 'secret',
        ca_bundle: nil,
        transport: InvalidPreflightTransport.new(invalid_field)
      )

      assert_raises(ForemanAnsibleAap::AapClient::ConfigurationError, invalid_field.to_s) do
        client.preflight!(contract)
      end
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

  test 'cancels and rejects a launch when AAP ignores a safety-critical field' do
    transport = IgnoredLaunchTransport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    error = assert_raises(ForemanAnsibleAap::AapClient::UnsafeLaunchError) do
      client.launch(
        job_template_id: 7,
        scm_branch: 'foreman/prod/job-invocation-42',
        limit: 'node.example.test',
        extra_vars: {
          foreman_instance_id: 'prod',
          foreman_job_invocation_id: 42,
        }
      )
    end

    assert_match(/ignored safety-critical launch fields: scm_branch/, error.message)
    assert_equal ['jobs/91/cancel/', {}], transport.posts.last
  end

  test 'classifies a definitive launch rejection without retrying it' do
    transport = FailingLaunchTransport.new(
      ForemanAnsibleAap::AapClient::DefinitiveRequestError.new('HTTP 400')
    )
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    error = assert_raises(ForemanAnsibleAap::AapClient::DefinitiveLaunchError) do
      client.launch(job_template_id: 7, scm_branch: 'safe-ref', limit: 'node', extra_vars: {})
    end

    assert_equal 'AAP rejected the launch: HTTP 400', error.message
    assert_equal 1, transport.launch_attempts
  end

  test 'cancels and rejects a launch when returned execution fields do not match the request' do
    transport = MismatchedLaunchTransport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    error = assert_raises(ForemanAnsibleAap::AapClient::UnsafeLaunchError) do
      client.launch(
        job_template_id: 7,
        scm_branch: 'foreman/prod/job-invocation-42',
        limit: 'node.example.test',
        extra_vars: { foreman_job_invocation_id: 42 }
      )
    end

    assert_match(/returned a different scm_branch/, error.message)
    assert_equal ['jobs/91/cancel/', {}], transport.posts.last
  end

  test 'warns that AAP might still be executing after an ambiguous launch without retrying it' do
    transport = FailingLaunchTransport.new(
      ForemanAnsibleAap::AapClient::AmbiguousRequestError.new('connection closed')
    )
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    error = assert_raises(ForemanAnsibleAap::AapClient::AmbiguousLaunchError) do
      client.launch(job_template_id: 7, scm_branch: 'safe-ref', limit: 'node', extra_vars: {})
    end

    assert_match(/AAP might still be executing/, error.message)
    assert_equal 1, transport.launch_attempts
  end
end
