# frozen_string_literal: true

module ForemanAnsibleAap
  class Engine < ::Rails::Engine
    isolate_namespace ForemanAnsibleAap
    engine_name 'foreman_ansible_aap'

    initializer('foreman_ansible_aap.require_dynflow',
      before: 'foreman_tasks.initialize_dynflow') do
      ::ForemanTasks.dynflow.require!
      actions_path = File.join(ForemanAnsibleAap::Engine.root, 'app/lib/actions')
      ::ForemanTasks.dynflow.config.eager_load_paths << actions_path
    end

    # Add any db migrations
    initializer 'foreman_ansible_aap.load_app_instance_data' do |app|
      ForemanAnsibleAap::Engine.paths['db/migrate'].existent.each do |path|
        app.config.paths['db/migrate'] << path
      end
    end

    initializer 'foreman_ansible_aap.register_plugin', before: :finisher_hook do |app|
      app.reloader.to_prepare do
        require 'foreman_ansible_aap/register'
      end
    end

    config.to_prepare do
      ::JobInvocation.include ForemanAnsibleAap::JobInvocationExtensions
      ::Api::V2::JobInvocationsController.prepend(
        ForemanAnsibleAap::Api::JobInvocationsControllerExtensions
      )
    end
  end
end
