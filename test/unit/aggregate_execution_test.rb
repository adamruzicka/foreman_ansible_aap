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

    def initialize(execution_record, trace)
      @execution_record = execution_record
      @trace = trace
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
      status = @statuses.shift
      @trace << "status_#{status}".to_sym
      status
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
    attr_reader :successful_hosts

    def initialize
      @successful_hosts = []
    end

    def success!(host)
      @successful_hosts << host
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
end
