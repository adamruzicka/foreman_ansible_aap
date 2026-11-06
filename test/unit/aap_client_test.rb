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
          'organization' => 3,
          'playbook' => 'generated/foreman.yml',
          'ask_scm_branch_on_launch' => true,
          'ask_limit_on_launch' => true,
          'ask_variables_on_launch' => true,
        }
      when %r{labels/\?name=foreman$}
        { 'results' => [{ 'id' => 61, 'organization' => 3 }] }
      when %r{labels/\?name=foreman-instance-prod$}
        { 'results' => [{ 'id' => 62, 'organization' => 1 }] }
      when %r{labels/\?name=foreman-job-invocation-42$}
        { 'results' => [] }
      when %r{projects/9/}
        { 'scm_url' => 'https://git.example.test/generated.git', 'scm_update_on_launch' => true }
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
      return { 'id' => 63 } if path == 'labels/'

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

  class FailingObservationTransport < Transport
    def initialize(failure)
      super()
      @failure = failure
    end

    def get(path)
      gets << path
      raise @failure
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
        resource['scm_update_on_launch'] = false if path.match?(%r{projects/9/})
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
        'labels' => [],
        'extra_vars' => { foreman_job_invocation_id: 42 },
      },
    ]], transport.posts
    assert_equal 'successful', client.job_status(91)
    assert_equal [
      { host_name: 'node.example.test', successful: true },
      { host_name: 'unreachable.example.test', successful: false },
    ], client.host_summaries(91)
  end

  test 'preflights numeric AAP resource IDs stored as Foreman setting strings' do
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test',
      token: 'secret',
      ca_bundle: nil,
      transport: Transport.new
    )

    assert client.preflight!(
      job_template_id: '7',
      inventory_id: '8',
      project_id: '9',
      repository_url: 'https://git.example.test/generated.git',
      playbook_path: 'generated/foreman.yml'
    )
  end

  test 'rejects a controller endpoint without TLS' do
    assert_raises(ForemanAnsibleAap::AapClient::ConfigurationError) do
      ForemanAnsibleAap::AapClient.new(
        controller_url: 'http://aap.example.test', token: 'secret', ca_bundle: nil
      )
    end
  end

  test 'preflight accepts both project update-on-launch field names' do
    contract = {
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      playbook_path: 'generated/foreman.yml',
    }

    %w[update_on_launch scm_update_on_launch].each do |field|
      transport = Transport.new
      transport.define_singleton_method(:get) do |path|
        resource = super(path)
        if path.match?(%r{projects/9/})
          resource.delete('scm_update_on_launch')
          resource[field] = true
        end
        resource
      end

      assert build_client(transport).preflight!(contract), field
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

  test 'cancels one persisted AAP job through its job endpoint' do
    transport = Transport.new
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    assert client.cancel(91)

    assert_equal [['jobs/91/cancel/', {}]], transport.posts
  end

  test 'accepts an empty successful cancellation response' do
    response_class = Class.new(Net::HTTPAccepted) do
      def body
        ''
      end
    end
    response = response_class.new('1.1', '202', 'Accepted')
    http = mock('HTTPS connection')
    http.expects(:use_ssl=).with(true)
    http.expects(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
    http.expects(:request).returns(response)
    Net::HTTP.expects(:new).with('aap.example.test', 443).returns(http)
    transport = ForemanAnsibleAap::AapClient::HttpsTransport.new(
      controller_url: 'https://aap.example.test', token: 'secret', ca_bundle: nil
    )

    assert_equal({}, transport.post('jobs/91/cancel/', {}))
  end

  test 'classifies network failures, rate limiting, and server errors as transient observations' do
    failures = [
      Timeout::Error.new('timed out'),
      ForemanAnsibleAap::AapClient::HttpError.new(429),
      ForemanAnsibleAap::AapClient::HttpError.new(503),
    ]

    failures.each do |failure|
      client = build_client(FailingObservationTransport.new(failure))

      error = assert_raises(ForemanAnsibleAap::AapClient::TransientError) do
        client.job_status(91)
      end

      assert_match(/temporarily unavailable|HTTP (429|503)/, error.message)
    end
  end

  test 'classifies authentication, authorization, and deleted jobs as permanent observations' do
    expected_messages = {
      401 => 'AAP authentication failed while observing job 91',
      403 => 'AAP authorization failed while observing job 91',
      404 => 'AAP job 91 no longer exists',
    }

    expected_messages.each do |status, message|
      client = build_client(
        FailingObservationTransport.new(ForemanAnsibleAap::AapClient::HttpError.new(status))
      )

      error = assert_raises(ForemanAnsibleAap::AapClient::PermanentError) do
        client.job_status(91)
      end

      assert_equal message, error.message
    end
  end

  test 'classifies structurally invalid observation responses as permanent' do
    client = build_client(Transport.new)
    client_transport = client.instance_variable_get(:@transport)
    client_transport.define_singleton_method(:get) { |_path| { 'unexpected' => 'shape' } }

    error = assert_raises(ForemanAnsibleAap::AapClient::PermanentError) do
      client.job_status(91)
    end

    assert_equal 'AAP returned an invalid job 91 response', error.message

    invalid_page_client = build_client(Transport.new)
    invalid_page_transport = invalid_page_client.instance_variable_get(:@transport)
    invalid_page_transport.define_singleton_method(:get) do |_path|
      { 'results' => nil, 'next' => nil }
    end

    events_error = assert_raises(ForemanAnsibleAap::AapClient::PermanentError) do
      invalid_page_client.job_events(91)
    end

    assert_equal 'AAP returned an invalid output for AAP job 91 response', events_error.message
  end

  test 'resolves label names to AAP label IDs before launching' do
    transport = Transport.new
    client = build_client(transport)

    launched = client.launch(
      job_template_id: 7,
      scm_branch: 'foreman/prod/job-invocation-42',
      limit: 'node.example.test',
      labels: %w[foreman foreman-instance-prod foreman-job-invocation-42],
      extra_vars: {}
    )

    assert_equal({ id: 91, url: 'https://aap.example.test/api/controller/v2/jobs/91/' }, launched)
    # foreman exists in the template organization; foreman-instance-prod
    # exists only in another organization (so it is recreated); the
    # invocation label does not exist yet.
    assert_equal [
      ['labels/', { 'name' => 'foreman-instance-prod', 'organization' => 3 }],
      ['labels/', { 'name' => 'foreman-job-invocation-42', 'organization' => 3 }],
      [
        'job_templates/7/launch/',
        {
          'scm_branch' => 'foreman/prod/job-invocation-42',
          'limit' => 'node.example.test',
          'labels' => [61, 63, 63],
          'extra_vars' => {},
        },
      ],
    ], transport.posts
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
      ForemanAnsibleAap::AapClient::HttpError.new(400)
    )
    client = ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )

    error = assert_raises(ForemanAnsibleAap::AapClient::DefinitiveLaunchError) do
      client.launch(job_template_id: 7, scm_branch: 'safe-ref', limit: 'node', extra_vars: {})
    end

    assert_equal 'AAP rejected the launch: AAP request failed with HTTP 400', error.message
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

  test 'classifies a rate-limited or failing launch as ambiguous without retrying it' do
    transport = FailingLaunchTransport.new(
      ForemanAnsibleAap::AapClient::HttpError.new(503)
    )
    client = build_client(transport)

    error = assert_raises(ForemanAnsibleAap::AapClient::AmbiguousLaunchError) do
      client.launch(job_template_id: 7, scm_branch: 'safe-ref', limit: 'node', extra_vars: {})
    end

    assert_match(/AAP might still be executing/, error.message)
    assert_equal 1, transport.launch_attempts
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

  private

  def build_client(transport)
    ForemanAnsibleAap::AapClient.new(
      controller_url: 'https://unused.example.test', token: 'secret', ca_bundle: nil, transport: transport
    )
  end
end
