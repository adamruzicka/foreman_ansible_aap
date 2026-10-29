# frozen_string_literal: true

require File.expand_path('lib/foreman_ansible_aap/version', __dir__)

Gem::Specification.new do |s|
  s.name        = 'foreman_ansible_aap'
  s.version     = ForemanAnsibleAap::VERSION
  s.metadata    = { 'is_foreman_plugin' => 'true' }
  s.license     = 'GPL-3.0'
  s.authors     = ['Foreman Ansible team']
  s.email       = ['foreman-dev@googlegroups.com']
  s.homepage    = 'https://github.com/theforeman/foreman_ansible_aap'
  s.summary     = 'Experimental Ansible Automation Platform execution driver for Foreman'
  # also update locale/gemspec.rb
  s.description = 'Adds an experimental Ansible Automation Platform execution driver to Foreman Ansible.'

  s.files = Dir['{app,config,db,lib,locale}/**/*'] + ['LICENSE', 'Rakefile', 'README.md']
  s.test_files = Dir['test/**/*']

  s.required_ruby_version = '>= 2.7', '< 4'

  s.add_development_dependency 'rdoc'
  s.add_dependency 'foreman_ansible', '>= 18.0', '< 19'
  s.add_dependency 'foreman_remote_execution', '>= 17.2', '< 18'
end
