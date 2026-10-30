# frozen_string_literal: true

require 'test_plugin_helper'

class AggregateExecutionTest < ActiveSupport::TestCase
  Host = Struct.new(:name)

  class Record
    OPTIONAL_ATTRIBUTES = %i[
      aap_job_id aap_job_url aap_status cancellation_requested_at cancellation_sent_at
      commit_sha scm_ref
    ].freeze
    attr_reader :attributes

    def initialize
      @attributes = {}
    end

    def update!(attributes)
      @attributes.merge!(attributes)
    end

    def reload
      self
    end

    def method_missing(name, *arguments)
      return attributes[name] if arguments.empty? && attributes.key?(name)
      return 'pending' if name == :workflow_state && arguments.empty?
      return nil if arguments.empty? && OPTIONAL_ATTRIBUTES.include?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      name == :workflow_state || OPTIONAL_ATTRIBUTES.include?(name) || attributes.key?(name) || super
    end
  end

  Invocation = Struct.new(:id)

  class Renderer
    attr_reader :invocations

    def initialize
      @invocations = []
    end

    def render(invocation)
      @invocations << invocation
      "---\n- hosts: all\n"
    end
  end

  class FailingRenderer
    def render(_invocation)
      raise 'playbook syntax error before host execution'
    end
  end

  class Publisher
    attr_reader :publications

    def initialize
      @publications = []
    end

    def publish(attributes)
      @publications << attributes
      '7f83b1657ff1fc53b92dc18148a1d65dfa13514d'
    end
  end

  class AapClient
    attr_reader :preflights, :launches, :status_requests, :summary_requests, :cancellations

    def initialize(execution_record, trace = [], statuses: %w[queued waiting running successful], summaries: nil)
      @execution_record = execution_record
      @trace = trace
      @preflights = []
      @launches = []
      @status_requests = []
      @summary_requests = []
      @cancellations = []
      @statuses = statuses
      @summaries = summaries || [
        { host_name: 'node-1.example.test', successful: true },
        { host_name: 'node-2.example.test', successful: true },
      ]
    end

    def preflight!(contract)
      @preflights << contract
    end

    def launch(attributes)
      @launches << attributes
      { id: 91, url: 'https://aap.example.test/execution/jobs/playbook/91/' }
    end

    def job_status(job_id)
      assert_job_was_persisted
      @status_requests << job_id
      status = @statuses.shift
      @trace << "status_#{status}".to_sym
      status
    end

    def host_summaries(job_id)
      @summary_requests << job_id
      @summaries
    end

    def cancel!(job_id)
      @cancellations << job_id
      true
    end

    private

    def assert_job_was_persisted
      raise 'polled before persisting the AAP job' unless @execution_record.attributes[:aap_job_id] == 91
    end
  end

  class EventIngestor
    attr_reader :jobs

    def initialize(trace)
      @trace = trace
      @jobs = []
    end

    def ingest(job_id)
      @jobs << job_id
      @trace << :events
    end
  end

  class ResultSettler
    attr_reader :successful_hosts, :failed_hosts, :cancelled_hosts

    def initialize
      @successful_hosts = []
      @failed_hosts = []
      @cancelled_hosts = []
    end

    def success!(host)
      @successful_hosts << host
    end

    def failure!(host, diagnostic:, error: diagnostic)
      @failed_hosts << [host, diagnostic]
    end

    def cancelled!(host)
      @cancelled_hosts << host
    end
  end

  test 'cancellation before publication skips every external operation and cancels prepared hosts' do
    execution_record = Record.new
    execution_record.update!(cancellation_requested_at: Time.zone.now)
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    aap_client = AapClient.new(execution_record)
    settler = ResultSettler.new
    renderer = Renderer.new
    publisher = Publisher.new
    execution = build_execution(
      execution_record,
      hosts,
      aap_client,
      settler,
      renderer: renderer,
      publisher: publisher
    )

    result = execution.call

    assert_equal 'cancelled', result.state
    assert_empty aap_client.preflights
    assert_empty renderer.invocations
    assert_empty publisher.publications
    assert_empty aap_client.launches
    assert_equal hosts, settler.cancelled_hosts
  end

  test 'cancellation after publication preserves the immutable ref and prevents launch' do
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test')]
    aap_client = AapClient.new(execution_record)
    settler = ResultSettler.new
    publisher = Publisher.new
    execution = build_execution(execution_record, hosts, aap_client, settler, publisher: publisher)

    refute execution.advance.complete?
    refute execution.advance.complete?
    published_coordinates = execution_record.attributes.slice(:repository_url, :scm_ref, :commit_sha)
    execution_record.update!(cancellation_requested_at: Time.zone.now)

    result = execution.advance

    assert result.complete?
    assert_equal 'cancelled', result.result.state
    assert_equal 1, publisher.publications.size
    assert_equal published_coordinates, execution_record.attributes.slice(:repository_url, :scm_ref, :commit_sha)
    assert_empty aap_client.launches
    assert_equal hosts, settler.cancelled_hosts
  end

  test 'accepted cancellation polls through queued and running and preserves completed host outcomes' do
    execution_record = Record.new
    hosts = [
      Host.new('successful.example.test'),
      Host.new('failed.example.test'),
      Host.new('unfinished.example.test'),
    ]
    trace = []
    aap_client = AapClient.new(
      execution_record,
      trace,
      statuses: %w[queued running canceled],
      summaries: [
        { host_name: hosts[0].name, successful: true },
        { host_name: hosts[1].name, successful: false },
      ]
    )
    settler = ResultSettler.new
    event_ingestor = EventIngestor.new(trace)
    execution = build_execution(
      execution_record,
      hosts,
      aap_client,
      settler,
      event_ingestor: event_ingestor
    )
    3.times { refute execution.advance.complete? }
    execution_record.update!(cancellation_requested_at: Time.zone.now)

    refute execution.advance.complete?
    assert_equal [91], aap_client.cancellations
    refute execution.advance.complete?
    assert_equal [91], aap_client.cancellations
    result = execution.advance

    assert result.complete?
    assert_equal 'cancelled', result.result.state
    assert_equal [91, 91, 91], aap_client.status_requests
    assert_equal [91, 91, 91], event_ingestor.jobs
    assert_equal [hosts[0]], settler.successful_hosts
    assert_equal [[hosts[1], 'AAP reported a failed result for failed.example.test']], settler.failed_hosts
    assert_equal [hosts[2]], settler.cancelled_hosts
  end

  test 'cancellation requested while AAP is running sends one request and waits for canceled' do
    execution_record = Record.new
    host = Host.new('node-1.example.test')
    aap_client = AapClient.new(
      execution_record,
      statuses: %w[running canceled],
      summaries: []
    )
    settler = ResultSettler.new
    execution = build_execution(execution_record, [host], aap_client, settler)
    3.times { refute execution.advance.complete? }
    execution_record.update!(cancellation_requested_at: Time.zone.now)

    refute execution.advance.complete?
    assert_equal [91], aap_client.cancellations
    result = execution.advance

    assert result.complete?
    assert_equal 'cancelled', result.result.state
    assert_equal [91], aap_client.cancellations
    assert_equal [host], settler.cancelled_hosts
  end

  test 'cancellation after AAP is already terminal settles normally without a cancel request' do
    execution_record = Record.new
    host = Host.new('node-1.example.test')
    aap_client = AapClient.new(execution_record, statuses: ['successful'])
    settler = ResultSettler.new
    execution = build_execution(execution_record, [host], aap_client, settler)
    3.times { refute execution.advance.complete? }
    execution_record.update!(cancellation_requested_at: Time.zone.now)

    result = execution.advance

    assert result.complete?
    assert_equal 'successful', result.result.state
    assert_empty aap_client.cancellations
    assert_equal [host], settler.successful_hosts
    assert_empty settler.cancelled_hosts
  end

  test 'streams active output and performs a final catch-up before settling prepared hosts' do
    invocation = Invocation.new(42)
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    configuration = ForemanAnsibleAap::Configuration.new(
      controller_url: 'https://aap.example.test',
      service_token: 'controller-secret',
      ca_bundle: '/etc/pki/aap-ca.pem',
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      base_ref: 'main',
      playbook_path: 'generated/foreman.yml',
      instance_id: 'foreman-prod',
      git_username: 'foreman',
      git_password: 'git-secret'
    )
    renderer = Renderer.new
    publisher = Publisher.new
    trace = []
    aap_client = AapClient.new(execution_record, trace)
    event_ingestor = EventIngestor.new(trace)
    settler = ResultSettler.new

    result = ForemanAnsibleAap::AggregateExecution.new(
      job_invocation: invocation,
      execution_record: execution_record,
      prepared_hosts: hosts,
      configuration: configuration,
      dependencies: {
        renderer: renderer,
        publisher: publisher,
        aap_client: aap_client,
        event_ingestor: event_ingestor,
        result_settler: settler,
      }
    ).call

    assert_equal [invocation], renderer.invocations
    assert_equal 1, publisher.publications.size
    assert_equal({
      repository_url: 'https://git.example.test/generated.git',
      base_ref: 'main',
      ref: 'foreman/foreman-prod/job-invocation-42',
      path: 'generated/foreman.yml',
      content: "---\n- hosts: all\n",
      username: 'foreman',
      password: 'git-secret',
    }, publisher.publications.first)
    assert_equal 1, aap_client.preflights.size
    assert_equal({
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      playbook_path: 'generated/foreman.yml',
    }, aap_client.preflights.first)
    assert_equal 1, aap_client.launches.size
    assert_equal({
      job_template_id: 7,
      scm_branch: 'foreman/foreman-prod/job-invocation-42',
      limit: 'node-1.example.test,node-2.example.test',
      extra_vars: {
        foreman_instance_id: 'foreman-prod',
        foreman_job_invocation_id: 42,
      },
    }, aap_client.launches.first)
    assert_equal [91, 91, 91, 91], aap_client.status_requests
    assert_equal [91, 91, 91, 91], event_ingestor.jobs
    assert_equal %i[
      status_queued events
      status_waiting events
      status_running events
      status_successful events
    ], trace
    assert_equal [91], aap_client.summary_requests
    assert_equal hosts, settler.successful_hosts
    assert_equal({
      workflow_state: 'reconciled',
      repository_url: 'https://git.example.test/generated.git',
      scm_ref: 'foreman/foreman-prod/job-invocation-42',
      commit_sha: '7f83b1657ff1fc53b92dc18148a1d65dfa13514d',
      aap_job_id: 91,
      aap_job_url: 'https://aap.example.test/execution/jobs/playbook/91/',
      aap_status: 'successful',
    }, execution_record.attributes)
    assert_equal 91, result.job_id
  end

  test 'limits the aggregate launch to the successfully prepared subset' do
    execution_record = Record.new
    prepared_host = Host.new('node-2.example.test')
    aap_client = AapClient.new(execution_record)
    settler = ResultSettler.new

    build_execution(execution_record, [prepared_host], aap_client, settler).call

    assert_equal 1, aap_client.launches.size
    assert_equal 'node-2.example.test', aap_client.launches.first.fetch(:limit)
    assert_equal [prepared_host], settler.successful_hosts
  end

  test 'does no external or rendering work when no hosts were prepared' do
    execution_record = Record.new
    renderer = Renderer.new
    publisher = Publisher.new
    aap_client = AapClient.new(execution_record)

    result = ForemanAnsibleAap::AggregateExecution.new(
      job_invocation: Invocation.new(42),
      execution_record: execution_record,
      prepared_hosts: [],
      configuration: nil,
      dependencies: {
        renderer: renderer,
        publisher: publisher,
        aap_client: aap_client,
        event_ingestor: EventIngestor.new([]),
        result_settler: ResultSettler.new,
      }
    ).call

    assert_empty renderer.invocations
    assert_empty publisher.publications
    assert_empty aap_client.preflights
    assert_empty aap_client.launches
    assert_nil result.job_id
  end

  test 'preserves successful host summaries when the aggregate job fails' do
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    aap_client = AapClient.new(
      execution_record,
      statuses: ['failed'],
      summaries: [
        { host_name: 'node-1.example.test', successful: true },
        { host_name: 'node-2.example.test', successful: false },
      ]
    )
    settler = ResultSettler.new
    execution = build_execution(execution_record, hosts, aap_client, settler)

    error = assert_raises(ForemanAnsibleAap::AggregateExecution::ExecutionError) { execution.call }

    assert_equal 'AAP job 91 finished with status "failed"', error.message
    assert_equal [hosts.first], settler.successful_hosts
    assert_equal [[hosts.last, 'AAP reported a failed result for node-2.example.test']], settler.failed_hosts
    assert_equal [91], aap_client.summary_requests
  end

  test 'fails a prepared host missing from all final summaries with an inventory diagnostic' do
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test'), Host.new('missing.example.test')]
    aap_client = AapClient.new(
      execution_record,
      summaries: [{ host_name: 'node-1.example.test', successful: true }]
    )
    settler = ResultSettler.new

    error = assert_raises(ForemanAnsibleAap::AggregateExecution::ExecutionError) do
      build_execution(execution_record, hosts, aap_client, settler).call
    end

    assert_equal 'AAP host reconciliation failed for missing.example.test', error.message
    assert_equal [hosts.first], settler.successful_hosts
    assert_equal [[
      hosts.last,
      'AAP did not report a final host summary for missing.example.test; ' \
        'the host did not execute or was not present in the synchronized inventory',
    ]], settler.failed_hosts
  end

  test 'records an unscoped startup error on the aggregate and fails every prepared host' do
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    aap_client = AapClient.new(execution_record)
    settler = ResultSettler.new
    execution = build_execution(
      execution_record,
      hosts,
      aap_client,
      settler,
      renderer: FailingRenderer.new
    )

    error = assert_raises(RuntimeError) { execution.call }

    assert_equal 'playbook syntax error before host execution', error.message
    assert_empty settler.successful_hosts
    assert_equal hosts.map { |host| [host, nil] }, settler.failed_hosts
  end

  test 'host summary failure overrides a successful aggregate status' do
    execution_record = Record.new
    host = Host.new('node-1.example.test')
    aap_client = AapClient.new(
      execution_record,
      summaries: [{ host_name: host.name, successful: false }]
    )
    settler = ResultSettler.new

    error = assert_raises(ForemanAnsibleAap::AggregateExecution::ExecutionError) do
      build_execution(execution_record, [host], aap_client, settler).call
    end

    assert_equal 'AAP host reconciliation failed for node-1.example.test', error.message
    assert_empty settler.successful_hosts
    assert_equal [[host, 'AAP reported a failed result for node-1.example.test']], settler.failed_hosts
  end

  test 'ignores summaries outside the prepared Foreman target set' do
    execution_record = Record.new
    host = Host.new('node-1.example.test')
    aap_client = AapClient.new(
      execution_record,
      summaries: [
        { host_name: host.name, successful: true },
        { host_name: 'unexpected.example.test', successful: false },
      ]
    )
    settler = ResultSettler.new

    build_execution(execution_record, [host], aap_client, settler).call

    assert_equal [host], settler.successful_hosts
    assert_empty settler.failed_hosts
  end

  test 'uses original inventory identity when AAP reports delegated execution' do
    execution_record = Record.new
    original_host = Host.new('node-1.example.test')
    aap_client = AapClient.new(
      execution_record,
      summaries: [{
        host_name: original_host.name,
        delegated_host_name: 'delegate.example.test',
        successful: false,
      }]
    )
    settler = ResultSettler.new

    assert_raises(ForemanAnsibleAap::AggregateExecution::ExecutionError) do
      build_execution(execution_record, [original_host], aap_client, settler).call
    end

    assert_equal [[
      original_host,
      'AAP reported a failed result for node-1.example.test',
    ]], settler.failed_hosts
  end

  private

  def build_execution(
    execution_record,
    hosts,
    aap_client,
    settler,
    renderer: Renderer.new,
    publisher: Publisher.new,
    event_ingestor: EventIngestor.new([])
  )
    configuration = ForemanAnsibleAap::Configuration.new(
      controller_url: 'https://aap.example.test',
      service_token: 'controller-secret',
      ca_bundle: '/etc/pki/aap-ca.pem',
      job_template_id: 7,
      inventory_id: 8,
      project_id: 9,
      repository_url: 'https://git.example.test/generated.git',
      base_ref: 'main',
      playbook_path: 'generated/foreman.yml',
      instance_id: 'foreman-prod',
      git_username: 'foreman',
      git_password: 'git-secret'
    )

    ForemanAnsibleAap::AggregateExecution.new(
      job_invocation: Invocation.new(42),
      execution_record: execution_record,
      prepared_hosts: hosts,
      configuration: configuration,
      dependencies: {
        renderer: renderer,
        publisher: publisher,
        aap_client: aap_client,
        event_ingestor: event_ingestor,
        result_settler: settler,
      }
    )
  end
end
