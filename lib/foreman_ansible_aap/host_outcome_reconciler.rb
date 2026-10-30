# frozen_string_literal: true

module ForemanAnsibleAap
  class HostOutcomeReconciler
    MISSING_SUMMARY_DIAGNOSTIC = lambda do |host|
      "AAP did not report a final host summary for #{host.name}; " \
        'the host did not execute or was not present in the synchronized inventory'
    end

    def initialize(prepared_hosts:, summaries:, result_settler:)
      @prepared_hosts = prepared_hosts
      @summaries = summaries.index_by { |summary| summary.fetch(:host_name) }
      @result_settler = result_settler
    end

    def call
      prepared_hosts.filter_map { |host| settle(host) }
    end

    private

    attr_reader :prepared_hosts, :summaries, :result_settler

    def settle(host)
      summary = summaries[host.name]
      return missing_summary(host) if summary.nil?
      if summary[:successful]
        result_settler.success!(host)
        return
      end

      result_settler.failure!(host, diagnostic: "AAP reported a failed result for #{host.name}")
      host.name
    end

    def missing_summary(host)
      result_settler.failure!(host, diagnostic: MISSING_SUMMARY_DIAGNOSTIC.call(host))
      host.name
    end
  end
end
