# frozen_string_literal: true

module ForemanAnsibleAap
  class AggregateExecution
    class ExecutionError < StandardError; end

    Result = Struct.new(:job_id, :job_url, :commit_sha, :scm_ref, keyword_init: true)
    ACTIVE_STATUSES = %w[new pending queued waiting running].freeze
    SUCCESSFUL_STATUS = 'successful'

    def initialize(job_invocation:, execution_record:, prepared_hosts:, configuration:, dependencies:)
      @job_invocation = job_invocation
      @execution_record = execution_record
      @prepared_hosts = prepared_hosts
      @configuration = configuration
      @renderer = dependencies.fetch(:renderer)
      @publisher = dependencies.fetch(:publisher)
      @aap_client = dependencies.fetch(:aap_client)
      @event_ingestor = dependencies.fetch(:event_ingestor)
      @result_settler = dependencies.fetch(:result_settler)
    end

    def call
      preflight!
      playbook = renderer.render(job_invocation)
      commit_sha = publish(playbook)
      persist_artifact(commit_sha)
      remote_job = launch
      persist_remote_job(remote_job)
      wait_for_success(remote_job.fetch(:id))
      settle_successful_hosts(remote_job.fetch(:id))

      result(remote_job, commit_sha)
    end

    private

    def result(remote_job, commit_sha)
      Result.new(
        job_id: remote_job.fetch(:id),
        job_url: remote_job.fetch(:url),
        commit_sha: commit_sha,
        scm_ref: scm_ref
      )
    end

    attr_reader :job_invocation, :execution_record, :prepared_hosts, :configuration, :renderer,
      :publisher, :aap_client, :event_ingestor, :result_settler

    def preflight!
      aap_client.preflight!(
        job_template_id: configuration.job_template_id,
        inventory_id: configuration.inventory_id,
        project_id: configuration.project_id,
        repository_url: configuration.repository_url,
        playbook_path: configuration.playbook_path
      )
    end

    def publish(playbook)
      publisher.publish(
        repository_url: configuration.repository_url,
        base_ref: configuration.base_ref,
        ref: scm_ref,
        path: configuration.playbook_path,
        content: playbook,
        username: configuration.git_username,
        password: configuration.git_password
      )
    end

    def persist_artifact(commit_sha)
      execution_record.update!(
        repository_url: configuration.repository_url,
        scm_ref: scm_ref,
        commit_sha: commit_sha
      )
    end

    def launch
      aap_client.launch(
        job_template_id: configuration.job_template_id,
        scm_branch: scm_ref,
        limit: prepared_hosts.map(&:name).join(','),
        extra_vars: {
          foreman_instance_id: configuration.instance_id,
          foreman_job_invocation_id: job_invocation.id,
        }
      )
    end

    def persist_remote_job(remote_job)
      execution_record.update!(
        aap_job_id: remote_job.fetch(:id),
        aap_job_url: remote_job.fetch(:url)
      )
    end

    def wait_for_success(job_id)
      loop do
        status = normalize_status(aap_client.job_status(job_id))
        event_ingestor.ingest(job_id)
        next if ACTIVE_STATUSES.include?(status)
        return if status == SUCCESSFUL_STATUS

        raise ExecutionError, "AAP job #{job_id} finished with status #{status.inspect}"
      end
    end

    def settle_successful_hosts(job_id)
      summaries = aap_client.host_summaries(job_id).index_by do |summary|
        summary.fetch(:host_name)
      end

      prepared_hosts.each do |host|
        summary = summaries[host.name]
        unless summary && summary[:successful]
          raise ExecutionError, "AAP did not report a successful result for #{host.name}"
        end

        result_settler.success!(host)
      end
    end

    def normalize_status(status)
      status = status.fetch(:status) if status.respond_to?(:fetch) && status.is_a?(Hash)
      status.to_s
    end

    def scm_ref
      @scm_ref ||= "foreman/#{configuration.instance_id}/job-invocation-#{job_invocation.id}"
    end
  end
end
