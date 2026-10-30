# frozen_string_literal: true

require 'test_plugin_helper'

class AggregateExecutionTest < ActiveSupport::TestCase
  Host = Struct.new(:name)

  class Record
    attr_reader :attributes

    def initialize
      @attributes = {}
    end

    def update!(attributes)
      @attributes.merge!(attributes)
    end
  end

  class RemotePersistenceFailureRecord < Record
    def update!(attributes)
      raise 'database unavailable' if attributes.key?(:aap_job_id)

      super
    end
  end

  Invocation = Struct.new(:id)

  class Renderer
    attr_reader :invocations

    def initialize(trace = nil)
      @invocations = []
      @trace = trace
    end

    def render(invocation)
      @trace << :render if @trace
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

    def initialize(trace = nil)
      @publications = []
      @trace = trace
    end

    def publish(attributes)
      @trace << :publish if @trace
      @publications << attributes
      '7f83b1657ff1fc53b92dc18148a1d65dfa13514d'
    end
  end

  class AapClient
    attr_reader :preflights, :launches, :status_requests, :summary_requests

    def initialize(execution_record, trace = [], statuses: %w[queued waiting running successful], summaries: nil)
      @execution_record = execution_record
      @trace = trace
      @preflights = []
      @launches = []
      @status_requests = []
      @summary_requests = []
      @statuses = statuses
      @summaries = summaries || [
        { host_name: 'node-1.example.test', successful: true },
        { host_name: 'node-2.example.test', successful: true },
      ]
    end

    def preflight!(contract)
      @trace << :preflight
      @preflights << contract
    end

    def launch(attributes)
      @trace << :launch
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
    attr_reader :successful_hosts, :failed_hosts

    def initialize
      @successful_hosts = []
      @failed_hosts = []
    end

    def success!(host)
      @successful_hosts << host
    end

    def failure!(host, diagnostic:, error: diagnostic)
      @failed_hosts << [host, diagnostic]
    end
  end

  class SafetyFailureRenderer < Renderer
    def render(_invocation)
      raise ForemanAnsibleAap::PlaybookRenderer::RenderingError, 'render failed safely'
    end
  end

  class FailingPublisher < Publisher
    def publish(_attributes)
      raise ForemanAnsibleAap::GitPublisher::PublicationError, 'publication failed safely'
    end
  end

  class FailingLaunchClient < AapClient
    attr_reader :launch_attempts

    def initialize(execution_record, trace, error)
      super(execution_record, trace)
      @error = error
      @launch_attempts = 0
    end

    def launch(_attributes)
      @launch_attempts += 1
      raise @error
    end
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
      preflight launch
      status_queued events
      status_waiting events
      status_running events
      status_successful events
    ], trace
    assert_equal [91], aap_client.summary_requests
    assert_equal hosts, settler.successful_hosts
    assert_equal({
      repository_url: 'https://git.example.test/generated.git',
      scm_ref: 'foreman/foreman-prod/job-invocation-42',
      commit_sha: '7f83b1657ff1fc53b92dc18148a1d65dfa13514d',
      aap_job_id: 91,
      aap_job_url: 'https://aap.example.test/execution/jobs/playbook/91/',
    }, execution_record.attributes)
    assert_equal 91, result.job_id
  end

  test 'fails every prepared host with the same diagnostic after a definitive local or launch failure' do
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    failures = [
      [SafetyFailureRenderer.new, Publisher.new, AapClient.new(Record.new, []), /render failed safely/],
      [Renderer.new, FailingPublisher.new, AapClient.new(Record.new, []), /publication failed safely/],
      [
        Renderer.new,
        Publisher.new,
        FailingLaunchClient.new(
          Record.new,
          [],
          ForemanAnsibleAap::AapClient::DefinitiveLaunchError.new('launch rejected safely')
        ),
        /launch rejected safely/,
      ],
    ]

    failures.each do |renderer, publisher, aap_client, expected_message|
      settler = ResultSettler.new
      error = assert_raises(StandardError) do
        aggregate(
          hosts: hosts,
          renderer: renderer,
          publisher: publisher,
          aap_client: aap_client,
          settler: settler
        ).call
      end

      assert_match expected_message, error.message
      assert_equal hosts, settler.failed_hosts.map(&:first)
      assert_equal 1, settler.failed_hosts.map(&:last).uniq.size
    end
  end

  test 'preflights after preparation and before rendering or publication' do
    hosts = [Host.new('node-1.example.test')]
    trace = []
    record = Record.new

    aggregate(
      hosts: hosts,
      execution_record: record,
      renderer: Renderer.new(trace),
      publisher: Publisher.new(trace),
      aap_client: AapClient.new(record, trace)
    ).call

    assert_equal %i[preflight render publish launch], trace.first(4)
  end

  test 'fails hard with a prominent warning and one launch attempt after an ambiguous launch' do
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    aap_client = FailingLaunchClient.new(
      Record.new,
      [],
      ForemanAnsibleAap::AapClient::AmbiguousLaunchError.new(
        'AAP launch could not be confirmed; AAP might still be executing'
      )
    )
    settler = ResultSettler.new

    error = assert_raises(ForemanAnsibleAap::AapClient::AmbiguousLaunchError) do
      aggregate(hosts: hosts, aap_client: aap_client, settler: settler).call
    end

    assert_match(/AAP might still be executing/, error.message)
    assert_equal 1, aap_client.launch_attempts
    assert_equal hosts, settler.failed_hosts.map(&:first)
  end

  test 'treats failure to persist returned job coordinates as an ambiguous launch' do
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    record = RemotePersistenceFailureRecord.new
    aap_client = AapClient.new(record, [])
    settler = ResultSettler.new

    error = assert_raises(ForemanAnsibleAap::AapClient::AmbiguousLaunchError) do
      aggregate(
        hosts: hosts,
        execution_record: record,
        aap_client: aap_client,
        settler: settler
      ).call
    end

    assert_match(/could not be persisted/, error.message)
    assert_match(/AAP might still be executing/, error.message)
    assert_equal 1, aap_client.launches.size
    assert_empty aap_client.status_requests
    assert_equal hosts, settler.failed_hosts.map(&:first)
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
    assert_equal hosts.map { |host| [host, 'playbook syntax error before host execution'] }, settler.failed_hosts
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

  def build_execution(execution_record, hosts, aap_client, settler, renderer: Renderer.new)
    aggregate(
      hosts: hosts,
      execution_record: execution_record,
      renderer: renderer,
      aap_client: aap_client,
      settler: settler
    )
  end

  def aggregate(hosts:, execution_record: Record.new, renderer: Renderer.new, publisher: Publisher.new,
      aap_client: AapClient.new(Record.new, []), settler: ResultSettler.new)
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
        event_ingestor: EventIngestor.new([]),
        result_settler: settler,
      }
    )
  end
end
