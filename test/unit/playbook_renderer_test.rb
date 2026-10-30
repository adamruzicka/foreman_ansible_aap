# frozen_string_literal: true

require 'test_plugin_helper'

class PlaybookRendererTest < ActiveSupport::TestCase
  test 'host-context rendering fails clearly instead of selecting an arbitrary target' do
    invocation = invocation_for('<%= @host.name %>')

    error = assert_raises(ForemanAnsibleAap::PlaybookRenderer::RenderingError) do
      ForemanAnsibleAap::PlaybookRenderer.new.render(invocation)
    end

    assert_includes error.message, 'Failed rendering template'
  end

  test 'host-varying fact inputs fail clearly without a current host' do
    invocation = invocation_for('echo <%= input("issue") %>') do |template|
      template.template_inputs << FactoryBot.build(
        :template_input,
        name: 'issue',
        input_type: 'fact',
        fact_name: 'issue'
      )
    end

    error = assert_raises(ForemanAnsibleAap::PlaybookRenderer::RenderingError) do
      ForemanAnsibleAap::PlaybookRenderer.new.render(invocation)
    end

    assert_includes error.message, 'Failed rendering template'
  end

  private

  def invocation_for(source)
    template = FactoryBot.create(
      :job_template,
      provider_type: 'Ansible',
      template: source
    )
    yield template if block_given?
    template.save!
    FactoryBot.create(:job_invocation).tap do |invocation|
      invocation.pattern_template_invocations << FactoryBot.create(
        :template_invocation,
        job_invocation: invocation,
        template: template
      )
    end
  end
end
