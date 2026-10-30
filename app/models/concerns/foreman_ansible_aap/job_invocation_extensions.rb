# frozen_string_literal: true

module ForemanAnsibleAap
  module JobInvocationExtensions
    extend ActiveSupport::Concern

    included do
      has_one :aap_execution,
        class_name: 'ForemanAnsibleAap::Execution',
        foreign_key: :job_invocation_id,
        inverse_of: :job_invocation,
        dependent: :destroy

      validate :reject_unsupported_aap_controls
    end

    def aap_backed?
      ansible_execution_driver.to_s == 'aap'
    end

    def aap_diagnostics
      execution = aap_execution
      return if !aap_backed? || execution&.aap_job_id.blank? || execution.aap_job_url.blank?

      {
        job_id: execution.aap_job_id,
        job_url: execution.aap_job_url,
        limitations: aap_limitations,
        invocation_diagnostics: execution.event_diagnostics,
        output_incomplete: execution.output_incomplete,
        output_failure_diagnostic: execution.output_failure_diagnostic,
      }
    end

    private

    def aap_limitations
      _('Host-filtered cancellation and peripheral task-based integrations are not supported for AAP jobs.')
    end

    def reject_unsupported_aap_controls
      ForemanAnsibleAap::UnsupportedControls.new(self).messages.each do |message|
        errors.add(:base, message)
      end
    end
  end
end
