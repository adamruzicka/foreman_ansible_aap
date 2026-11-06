# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module ForemanAnsibleAap
  class AapClient
    class ConfigurationError < StandardError; end
    class RequestError < StandardError; end
    class DefinitiveRequestError < RequestError; end
    class AmbiguousRequestError < RequestError; end
    class HttpError < DefinitiveRequestError
      attr_reader :status

      def initialize(status)
        @status = Integer(status)
        super("AAP request failed with HTTP #{status}")
      end
    end
    class TransientError < RequestError; end
    class PermanentError < RequestError; end

    NETWORK_ERRORS = [
      Timeout::Error,
      SocketError,
      EOFError,
      IOError,
      SystemCallError,
      Net::OpenTimeout,
      Net::ReadTimeout,
    ].freeze
    class UnsafeLaunchError < StandardError; end
    class DefinitiveLaunchError < StandardError; end
    class AmbiguousLaunchError < StandardError; end

    SAFETY_CRITICAL_LAUNCH_FIELDS = %w[scm_branch limit extra_vars].freeze

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

      expect_identifier(template, 'project', contract.fetch(:project_id).to_s, 'Job Template Project')
      expect_identifier(template, 'inventory', contract.fetch(:inventory_id).to_s, 'Job Template inventory')
      expect(template, 'playbook', contract.fetch(:playbook_path), 'Job Template playbook')
      expect(project, 'scm_url', contract.fetch(:repository_url), 'Project repository')
      expect_update_on_launch(project, 'Project')
      unless inventory_sources.fetch('results').any? { |source| update_on_launch?(source) }
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
        'labels' => attributes.fetch(:labels, []),
        'extra_vars' => attributes.fetch(:extra_vars)
      )
      id = response.fetch('id')
      validate_launch_response!(response, attributes, id)
      { id: id, url: absolute_url(response.fetch('url')) }
    rescue DefinitiveRequestError => e
      raise DefinitiveLaunchError, "AAP rejected the launch: #{e.message}"
    rescue AmbiguousRequestError, KeyError, JSON::ParserError => e
      raise AmbiguousLaunchError,
        "AAP launch could not be confirmed or persisted; AAP might still be executing: #{e.message}"
    end

    def cancel(job_id)
      transport.post("jobs/#{job_id}/cancel/", {})
    end

    def job_status(job_id)
      observe("job #{job_id}", job_id: job_id) do
        transport.get("jobs/#{job_id}/").fetch('status')
      end
    end

    def cancel!(job_id)
      cancel(job_id)
      true
    end

    def job_events(job_id, after_id: nil)
      observe("output for AAP job #{job_id}") do
        path = "jobs/#{job_id}/job_events/?order_by=id&page_size=200"
        path = "#{path}&id__gt=#{after_id}" if after_id
        events = []

        while path
          page = transport.get(path)
          events.concat(page_results(page).map { |event| normalize_event(event) })
          path = next_page(page)
        end

        events
      end
    end

    def host_summaries(job_id)
      observe("host summaries for AAP job #{job_id}", job_id: job_id) do
        paginated_results("jobs/#{job_id}/job_host_summaries/?page_size=200").map do |summary|
          {
            host_name: summary.fetch('host_name') { summary.fetch('name') },
            successful: successful_summary?(summary),
          }
        end
      end
    end

    private

    attr_reader :transport

    def observe(label, job_id: nil)
      yield
    rescue HttpError => e
      raise classify_http_error(e, label, job_id: job_id)
    rescue AmbiguousRequestError => e
      raise TransientError, "AAP #{label} is temporarily unavailable: #{e.message}"
    rescue DefinitiveRequestError
      raise PermanentError, "AAP returned an invalid #{label} response"
    rescue *NETWORK_ERRORS => e
      raise TransientError, "AAP #{label} is temporarily unavailable: #{e.class}"
    rescue KeyError, TypeError, JSON::ParserError
      raise PermanentError, "AAP returned an invalid #{label} response"
    end

    def classify_http_error(error, label, job_id:)
      if error.status == 429 || error.status >= 500
        return TransientError.new("AAP #{label} failed with HTTP #{error.status}")
      end

      case error.status
      when 401
        PermanentError.new("AAP authentication failed while observing #{label}")
      when 403
        PermanentError.new("AAP authorization failed while observing #{label}")
      when 404
        PermanentError.new(job_id ? "AAP job #{job_id} no longer exists" : "AAP #{label} no longer exists")
      else
        PermanentError.new("AAP #{label} failed permanently with HTTP #{error.status}")
      end
    end

    def paginated_results(path)
      results = []
      while path
        page = transport.get(path)
        results.concat(page_results(page))
        path = next_page(page)
      end
      results
    end

    def page_results(page)
      results = page.fetch('results')
      raise TypeError unless results.is_a?(Array)

      results
    end

    def next_page(page)
      path = page['next']
      raise TypeError unless path.nil? || path.is_a?(String)

      path
    end

    # Older AAP exposes "update_on_launch" on projects; newer AAP renamed the
    # project field to "scm_update_on_launch". Inventory sources keep
    # "update_on_launch" in both.
    UPDATE_ON_LAUNCH_FIELDS = %w[update_on_launch scm_update_on_launch].freeze

    def expect_update_on_launch(resource, label)
      unless UPDATE_ON_LAUNCH_FIELDS.any? { |field| resource[field] == true }
        actual = UPDATE_ON_LAUNCH_FIELDS.map { |field| resource[field] }
        raise ConfigurationError, "#{label} update-on-launch is #{actual.inspect}, expected [true]"
      end
    end

    def update_on_launch?(resource)
      UPDATE_ON_LAUNCH_FIELDS.any? { |field| resource[field] == true }
    end

    def expect(resource, field, expected, label)
      actual = resource.fetch(field)
      return if actual == expected

      raise ConfigurationError, "#{label} is #{actual.inspect}, expected #{expected.inspect}"
    end

    def expect_identifier(resource, field, expected, label)
      actual = resource.fetch(field)
      actual_id = normalize_identifier(actual)
      expected_id = normalize_identifier(expected)
      return if actual_id && actual_id == expected_id

      raise ConfigurationError, "#{label} is #{actual.inspect}, expected #{expected.inspect}"
    end

    def normalize_identifier(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def validate_launch_response!(response, attributes, job_id)
      ignored_fields = response.fetch('ignored_fields', {})
      ignored_names = ignored_fields.respond_to?(:keys) ? ignored_fields.keys : Array(ignored_fields)
      unsafe_ignored_names = ignored_names.map(&:to_s) & SAFETY_CRITICAL_LAUNCH_FIELDS
      message = if unsafe_ignored_names.any?
                  "AAP ignored safety-critical launch fields: #{unsafe_ignored_names.join(', ')}"
                else
                  mismatched_launch_message(response, attributes)
                end
      return unless message

      cancellation_error = begin
        cancel(job_id)
        nil
      rescue StandardError => e
        e
      end
      message = "#{message}; cancellation request failed: #{cancellation_error.message}" if cancellation_error
      raise UnsafeLaunchError, message
    end

    def mismatched_launch_message(response, attributes)
      {
        'scm_branch' => attributes.fetch(:scm_branch),
        'limit' => attributes.fetch(:limit),
        'extra_vars' => attributes.fetch(:extra_vars),
      }.each do |field, expected|
        next unless response.key?(field)

        actual = response.fetch(field)
        if field == 'extra_vars'
          actual = JSON.parse(actual) if actual.is_a?(String)
          expected = JSON.parse(JSON.generate(expected))
          actual = JSON.parse(JSON.generate(actual))
        end
        return "AAP returned a different #{field} for the launched job" unless actual == expected
      end
      nil
    rescue JSON::ParserError
      'AAP returned invalid extra_vars for the launched job'
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
        start_line: event['start_line'],
        end_line: event['end_line'],
        counter: event['counter'],
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
        raise HttpError, response.code unless response.is_a?(Net::HTTPSuccess)

        response.body.blank? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise DefinitiveRequestError, "AAP returned invalid JSON: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout, IOError, SocketError, SystemCallError => e
        raise AmbiguousRequestError, "AAP connection failed: #{e.message}"
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
