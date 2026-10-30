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
      @result_settler = dependencies.fetch(:result_settler)
    end

    def call
      remote_job, commit_sha = start_remote_job
      finish_remote_job(remote_job)

      result(remote_job, commit_sha)
    rescue StandardError
      fail_prepared_hosts unless @host_outcomes_settled
      raise
    end

    private

    def start_remote_job
      preflight!
      playbook = renderer.render(job_invocation)
      commit_sha = publish(playbook)
      persist_artifact(commit_sha)
      remote_job = launch
      persist_remote_job(remote_job)
      [remote_job, commit_sha]
    end

    def finish_remote_job(remote_job)
      status = wait_for_terminal(remote_job.fetch(:id))
      failed_hosts = settle_hosts(remote_job.fetch(:id))
      unless status == SUCCESSFUL_STATUS
        raise ExecutionError, "AAP job #{remote_job.fetch(:id)} finished with status #{status.inspect}"
      end
      raise ExecutionError, "AAP host reconciliation failed for #{failed_hosts.join(', ')}" if failed_hosts.any?
    end

    def result(remote_job, commit_sha)
      Result.new(
        job_id: remote_job.fetch(:id),
        job_url: remote_job.fetch(:url),
        commit_sha: commit_sha,
        scm_ref: scm_ref
      )
    end

    attr_reader :job_invocation, :execution_record, :prepared_hosts, :configuration, :renderer,
      :publisher, :aap_client, :result_settler

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

    def wait_for_terminal(job_id)
      loop do
        status = normalize_status(aap_client.job_status(job_id))
        next if ACTIVE_STATUSES.include?(status)
        return status
      end
    end

    def settle_hosts(job_id)
      failed_hosts = HostOutcomeReconciler.new(
        prepared_hosts: prepared_hosts,
        summaries: aap_client.host_summaries(job_id),
        result_settler: result_settler
      ).call
      @host_outcomes_settled = true
      failed_hosts
    end

    def fail_prepared_hosts
      prepared_hosts.each do |host|
        result_settler.failure!(host, diagnostic: nil)
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
