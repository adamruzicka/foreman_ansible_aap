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
    attr_reader :preflights, :launches, :status_requests, :summary_requests

    def initialize(execution_record)
      @execution_record = execution_record
      @preflights = []
      @launches = []
      @status_requests = []
      @summary_requests = []
      @statuses = %w[queued waiting running successful]
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
      @statuses.shift
    end

    def host_summaries(job_id)
      @summary_requests << job_id
      [
        { host_name: 'node-1.example.test', successful: true },
        { host_name: 'node-2.example.test', successful: true },
      ]
    end

    private

    def assert_job_was_persisted
      raise 'polled before persisting the AAP job' unless @execution_record.attributes[:aap_job_id] == 91
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

    def fail_all!(hosts, error)
      @failed_hosts.concat(hosts.map { |host| [host, error] })
    end
  end

  class FailingRenderer
    def render(_invocation)
      raise ForemanAnsibleAap::PlaybookRenderer::RenderingError,
        'Host-specific template data is unavailable without a current host'
    end
  end

  test 'renders, publishes, and launches once before settling all prepared hosts' do
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
    aap_client = AapClient.new(execution_record)
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

  test 'limits the aggregate launch to the successfully prepared subset' do
    invocation = Invocation.new(42)
    execution_record = Record.new
    prepared_host = Host.new('node-2.example.test')
    configuration = configuration()
    renderer = Renderer.new
    publisher = Publisher.new
    aap_client = AapClient.new(execution_record)
    settler = ResultSettler.new

    ForemanAnsibleAap::AggregateExecution.new(
      job_invocation: invocation,
      execution_record: execution_record,
      prepared_hosts: [prepared_host],
      configuration: configuration,
      dependencies: {
        renderer: renderer,
        publisher: publisher,
        aap_client: aap_client,
        result_settler: settler,
      }
    ).call

    assert_equal 1, renderer.invocations.size
    assert_equal 1, publisher.publications.size
    assert_equal 1, aap_client.launches.size
    assert_equal 'node-2.example.test', aap_client.launches.first.fetch(:limit)
    assert_equal [prepared_host], settler.successful_hosts
  end

  test 'does no external or rendering work when no hosts were prepared' do
    invocation = Invocation.new(42)
    execution_record = Record.new
    renderer = Renderer.new
    publisher = Publisher.new
    aap_client = AapClient.new(execution_record)

    result = ForemanAnsibleAap::AggregateExecution.new(
      job_invocation: invocation,
      execution_record: execution_record,
      prepared_hosts: [],
      configuration: configuration,
      dependencies: {
        renderer: renderer,
        publisher: publisher,
        aap_client: aap_client,
        result_settler: ResultSettler.new,
      }
    ).call

    assert_empty renderer.invocations
    assert_empty publisher.publications
    assert_empty aap_client.preflights
    assert_empty aap_client.launches
    assert_nil result.job_id
  end

  test 'a host-context rendering failure is shared by all prepared hosts' do
    invocation = Invocation.new(42)
    execution_record = Record.new
    hosts = [Host.new('node-1.example.test'), Host.new('node-2.example.test')]
    settler = ResultSettler.new

    error = assert_raises(ForemanAnsibleAap::PlaybookRenderer::RenderingError) do
      ForemanAnsibleAap::AggregateExecution.new(
        job_invocation: invocation,
        execution_record: execution_record,
        prepared_hosts: hosts,
        configuration: configuration,
        dependencies: {
          renderer: FailingRenderer.new,
          publisher: Publisher.new,
          aap_client: AapClient.new(execution_record),
          result_settler: settler,
        }
      ).call
    end

    assert_includes error.message, 'without a current host'
    assert_equal hosts, settler.failed_hosts.map(&:first)
    assert(settler.failed_hosts.all? { |(_, failure)| failure == error })
  end

  private

  def configuration
    ForemanAnsibleAap::Configuration.new(
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
  end
end
