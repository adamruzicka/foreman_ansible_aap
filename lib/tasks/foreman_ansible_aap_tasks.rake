# frozen_string_literal: true

namespace :test do
  desc 'Foreman Ansible AAP plugin tests'
  Rake::TestTask.new(:foreman_ansible_aap) do |task|
    test_dir = File.join(__dir__, '..', '..', 'test')
    task.libs << ['test', test_dir]
    task.pattern = "#{test_dir}/**/*_test.rb"
    task.test_files = [Rails.root.join('test/unit/foreman/access_permissions_test.rb')]
    task.verbose = false
    task.warning = false
  end
  Rake::Task[:foreman_ansible_aap].enhance ['db:test:prepare', 'db:migrate']
end

Rake::Task[:test].enhance ['test:foreman_ansible_aap']
