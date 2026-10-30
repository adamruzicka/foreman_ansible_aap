# frozen_string_literal: true

module ForemanAnsibleAap
  class PlaybookRenderer
    class RenderingError < StandardError; end

    def render(job_invocation)
      template_invocation = job_invocation.pattern_template_invocations.first.deep_clone
      template_invocation.host = nil if template_invocation.respond_to?(:host=)
      renderer = InputTemplateRenderer.new(
        template_invocation.template,
        nil,
        template_invocation
      )
      rendered = renderer.render
      return rendered if rendered

      raise RenderingError, _('Failed rendering template: %s') % renderer.error_message
    end
  end
end
