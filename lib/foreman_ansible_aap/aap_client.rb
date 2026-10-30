# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module ForemanAnsibleAap
  class AapClient
    class ConfigurationError < StandardError; end
    class RequestError < StandardError; end

    def initialize(controller_url:, token:, ca_bundle:, transport: nil)
      @transport = transport || HttpsTransport.new(
        controller_url: controller_url,
        token: token,
        ca_bundle: ca_bundle
      )
    end

    def preflight!(contract)
      template = transport.get("job_templates/#{contract.fetch(:job_template_id)}/")
      project = transport.get("projects/#{contract.fetch(:project_id)}/")
      transport.get("inventories/#{contract.fetch(:inventory_id)}/")
      inventory_sources = transport.get("inventories/#{contract.fetch(:inventory_id)}/inventory_sources/")

      expect(template, 'project', contract.fetch(:project_id), 'Job Template Project')
      expect(template, 'inventory', contract.fetch(:inventory_id), 'Job Template inventory')
      expect(template, 'playbook', contract.fetch(:playbook_path), 'Job Template playbook')
      expect(project, 'scm_url', contract.fetch(:repository_url), 'Project repository')
      expect(project, 'update_on_launch', true, 'Project update-on-launch')
      unless inventory_sources.fetch('results').any? { |source| source['update_on_launch'] }
        raise ConfigurationError, 'Inventory requires an update-on-launch source'
      end
      %w[ask_scm_branch_on_launch ask_limit_on_launch ask_variables_on_launch].each do |field|
        expect(template, field, true, "Job Template #{field}")
      end

      true
    end

    def launch(attributes)
      response = transport.post(
        "job_templates/#{attributes.fetch(:job_template_id)}/launch/",
        'scm_branch' => attributes.fetch(:scm_branch),
        'limit' => attributes.fetch(:limit),
        'extra_vars' => attributes.fetch(:extra_vars)
      )
      id = response.fetch('id')
      { id: id, url: absolute_url(response.fetch('url')) }
    end

    def job_status(job_id)
      transport.get("jobs/#{job_id}/").fetch('status')
    end

    def job_events(job_id, after_id: nil)
      path = "jobs/#{job_id}/job_events/?order_by=id&page_size=200"
      path = "#{path}&id__gt=#{after_id}" if after_id
      events = []

      while path
        page = transport.get(path)
        events.concat(page.fetch('results').map { |event| normalize_event(event) })
        path = page['next']
      end

      events
    end

    def host_summaries(job_id)
      paginated_results("jobs/#{job_id}/job_host_summaries/?page_size=200").map do |summary|
        {
          host_name: summary['host_name'] || summary['name'],
          successful: successful_summary?(summary),
        }
      end
    end

    private

    attr_reader :transport

    def paginated_results(path)
      results = []
      while path
        page = transport.get(path)
        results.concat(page.fetch('results'))
        path = page['next']
      end
      results
    end

    def expect(resource, field, expected, label)
      actual = resource.fetch(field)
      return if actual == expected

      raise ConfigurationError, "#{label} is #{actual.inspect}, expected #{expected.inspect}"
    end

    def successful_summary?(summary)
      !summary['failed'] && !summary['unreachable'] &&
        summary.fetch('failures', 0).zero? && summary.fetch('dark', 0).zero?
    end

    def normalize_event(event)
      {
        id: event.fetch('id'),
        stdout: event.fetch('stdout', ''),
        timestamp: event.fetch('created'),
        host_name: event.fetch('event_data', {})['host'],
      }
    end

    def absolute_url(path)
      transport.absolute_url(path)
    end

    class HttpsTransport
      attr_reader :base_uri

      def initialize(controller_url:, token:, ca_bundle:)
        @base_uri = URI(controller_url)
        raise ConfigurationError, 'AAP controller URL must use HTTPS' unless base_uri.is_a?(URI::HTTPS)

        @token = token
        @ca_bundle = ca_bundle.presence
      end

      def get(path)
        request(Net::HTTP::Get, path)
      end

      def post(path, body)
        request(Net::HTTP::Post, path, body)
      end

      def absolute_url(path)
        URI.join(base_uri.to_s.end_with?('/') ? base_uri.to_s : "#{base_uri}/", path).to_s
      end

      private

      attr_reader :token, :ca_bundle

      def request(request_class, path, body = nil)
        uri = URI.join(base_uri.to_s.end_with?('/') ? base_uri.to_s : "#{base_uri}/", path)
        request = request_class.new(uri)
        request['Authorization'] = "Bearer #{token}"
        request['Accept'] = 'application/json'
        if body
          request['Content-Type'] = 'application/json'
          request.body = JSON.generate(body)
        end

        response = http_for(uri).request(request)
        raise RequestError, "AAP request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def http_for(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.ca_file = ca_bundle if ca_bundle
        end
      end
    end
  end
end
