# frozen_string_literal: true

module ForemanAnsibleAap
  class AggregateExecution
    class ExecutionError < StandardError; end

    class PollingRetry < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        @retry_after = retry_after
        super(message)
      end
    end

    Result = Struct.new(
      :job_id,
      :job_url,
      :commit_sha,
      :scm_ref,
      :state,
      :output_incomplete,
      :output_failure_diagnostic,
      keyword_init: true
    )
    Step = Struct.new(:complete, :result, :retry_after, keyword_init: true) do
      alias_method :complete?, :complete
    end
    MAXIMUM_BACKOFF = 30

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
      @sleeper = dependencies.fetch(:sleeper, ->(duration) { sleep duration })
    end

    def call
      return Result.new(state: Lifecycle::Result::SUCCESSFUL) if prepared_hosts.empty?

      loop do
        step = advance
        return step.result if step.complete?

        sleeper.call(step.retry_after) if step.retry_after
      end
    end

    def advance
      execution_record.reload
      restore_launched_stage
      return finish_before_launch if cancellation_requested? && execution_value(:aap_job_id).nil?

      case execution_value(:workflow_state)
      when Lifecycle::Workflow::PENDING
        preflight!
        transition_workflow!(Lifecycle::Workflow::PREFLIGHTED)
        incomplete
      when Lifecycle::Workflow::PREFLIGHTED
        playbook = renderer.render(job_invocation)
        persist_artifact(publish(playbook))
        transition_workflow!(Lifecycle::Workflow::PUBLISHED)
        incomplete
      when Lifecycle::Workflow::PUBLISHED
        remote_job = launch
        persist_remote_job(remote_job)
        transition_workflow!(Lifecycle::Workflow::LAUNCHED)
        incomplete
      when Lifecycle::Workflow::LAUNCHED, Lifecycle::Workflow::POLLING
        observe_remote_job
      when Lifecycle::Workflow::RECONCILED
        complete(completed_state)
      else
        raise ExecutionError, "Unknown aggregate workflow state #{execution_value(:workflow_state).inspect}"
      end
    rescue PollingRetry => e
      incomplete(retry_after: e.retry_after)
    rescue AapClient::PermanentError => e
      diagnostic = "AAP integration permanently lost observability: #{e.message}"
      fail_prepared_hosts(diagnostic: diagnostic, error: diagnostic)
      raise ExecutionError, diagnostic
    rescue StandardError => e
      fail_prepared_hosts(diagnostic: nil, error: e.message) unless @host_outcomes_settled
      raise
    end

    private

    attr_reader :job_invocation, :execution_record, :prepared_hosts, :configuration, :renderer,
      :publisher, :aap_client, :event_ingestor, :result_settler, :sleeper

    def completed_result(state)
      Result.new(
        job_id: execution_value(:aap_job_id),
        job_url: execution_value(:aap_job_url),
        commit_sha: execution_value(:commit_sha),
        scm_ref: execution_value(:scm_ref),
        state: state,
        output_incomplete: execution_value(:output_incomplete) || false,
        output_failure_diagnostic: execution_value(:output_failure_diagnostic)
      )
    end

    def incomplete(retry_after: nil)
      Step.new(complete: false, retry_after: retry_after)
    end

    def complete(state)
      Step.new(complete: true, result: completed_result(state))
    end

    def completed_state
      if Lifecycle::AapStatus::CANCELLED.include?(execution_value(:aap_status))
        Lifecycle::Result::CANCELLED
      else
        Lifecycle::Result::SUCCESSFUL
      end
    end

    def restore_launched_stage
      return if execution_value(:aap_job_id).nil?
      return if Lifecycle::Workflow::LAUNCHED_STATES.include?(execution_value(:workflow_state))

      transition_workflow!(Lifecycle::Workflow::LAUNCHED)
    end

    def finish_before_launch
      prepared_hosts.each { |host| result_settler.cancelled!(host) }
      @host_outcomes_settled = true
      transition_workflow!(
        Lifecycle::Workflow::RECONCILED,
        aap_status: Lifecycle::AapStatus::CANCELLED_STATUS
      )
      complete(Lifecycle::Result::CANCELLED)
    end

    def observe_remote_job
      job_id = execution_value(:aap_job_id)
      status = poll_status(job_id)
      transition_workflow!(Lifecycle::Workflow::POLLING, aap_status: status)
      ingest_output(job_id)

      if Lifecycle::AapStatus::ACTIVE.include?(status)
        clear_polling_failures!
        request_remote_cancellation(job_id) if cancellation_requested?
        return incomplete
      end

      finish_terminal_job(job_id, status)
    end

    def poll_status(job_id)
      normalize_status(with_polling_retries { aap_client.job_status(job_id) })
    rescue PollingRetry
      request_remote_cancellation(job_id) if cancellation_requested?
      raise
    end

    def request_remote_cancellation(job_id)
      return if execution_value(:cancellation_sent_at)

      # Record intent before crossing the HTTP boundary. A crash can therefore
      # lose a cancellation request, but can never duplicate one.
      execution_record.update!(cancellation_sent_at: Time.zone.now)
      aap_client.cancel!(job_id)
    end

    def finish_terminal_job(job_id, status)
      cancelled = Lifecycle::AapStatus::CANCELLED.include?(status)
      failed_hosts = settle_hosts(job_id, cancelled: cancelled)
      clear_polling_failures!
      transition_workflow!(Lifecycle::Workflow::RECONCILED)
      return complete(Lifecycle::Result::CANCELLED) if cancelled
      unless status == Lifecycle::AapStatus::SUCCESSFUL
        raise ExecutionError, "AAP job #{job_id} finished with status #{status.inspect}"
      end
      raise ExecutionError, "AAP host reconciliation failed for #{failed_hosts.join(', ')}" if failed_hosts.any?

      complete(Lifecycle::Result::SUCCESSFUL)
    end

    def preflight!
      UnsupportedControls.new(job_invocation, aap: true).validate!
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
    rescue StandardError => e
      raise AapClient::AmbiguousLaunchError,
        "AAP job coordinates could not be persisted; AAP might still be executing: #{e.message}"
    end

    def settle_hosts(job_id, cancelled: false)
      summaries = with_polling_retries { aap_client.host_summaries(job_id) }
      failed_hosts = HostOutcomeReconciler.new(
        prepared_hosts: prepared_hosts,
        summaries: summaries,
        result_settler: result_settler,
        cancelled: cancelled
      ).call
      @host_outcomes_settled = true
      failed_hosts
    end

    def ingest_output(job_id)
      event_ingestor.ingest(job_id)
    rescue StandardError => e
      execution_record.update!(
        output_incomplete: true,
        output_failure_diagnostic: e.message
      )
    end

    def with_polling_retries
      yield
    rescue AapClient::TransientError => e
      failure_count = execution_value(:polling_failure_count).to_i + 1
      execution_record.update!(
        polling_failure_count: failure_count,
        polling_failure_diagnostic: e.message
      )
      raise PollingRetry.new(e.message, retry_after: [2**(failure_count - 1), MAXIMUM_BACKOFF].min)
    end

    def clear_polling_failures!
      execution_record.update!(polling_failure_count: 0, polling_failure_diagnostic: nil)
    end

    def fail_prepared_hosts(diagnostic:, error:)
      prepared_hosts.each do |host|
        next if result_settler.respond_to?(:settled?) && result_settler.settled?(host)

        result_settler.failure!(host, diagnostic: diagnostic, error: error)
      end
    end

    def execution_value(attribute)
      return execution_record.public_send(attribute) if execution_record.respond_to?(attribute)

      execution_record.attributes[attribute]
    end

    def normalize_status(status)
      status = status.fetch(:status) if status.respond_to?(:fetch) && status.is_a?(Hash)
      status.to_s
    end

    def cancellation_requested?
      execution_value(:cancellation_requested_at).present?
    end

    def transition_workflow!(state, **attributes)
      Lifecycle.transition!(execution_record, :workflow_state, to: state, **attributes)
    end

    def scm_ref
      @scm_ref ||= execution_value(:scm_ref) ||
                   "foreman/#{configuration.instance_id}/job-invocation-#{job_invocation.id}"
    end
  end
end
