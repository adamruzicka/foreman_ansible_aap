# frozen_string_literal: true

module ForemanAnsibleAap
  class ExecutionDriver
    class << self
      def execution_action(_job_invocation)
        ::Actions::ForemanAnsibleAap::RunHostsJob
      end

      def humanized_name
        N_('AAP (experimental)')
      end
    end
  end
end
