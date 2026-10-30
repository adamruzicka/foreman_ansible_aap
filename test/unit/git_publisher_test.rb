# frozen_string_literal: true

require 'test_plugin_helper'
require 'open3'
require 'tmpdir'

class GitPublisherTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir('foreman-ansible-aap-publisher-test')
    @remote = File.join(@directory, 'generated.git')
    @source = File.join(@directory, 'source')

    git('init', '--bare', @remote)
    git('init', '-b', 'main', @source)
    File.write(File.join(@source, 'README.md'), "generated playbooks\n")
    git('-C', @source, 'add', 'README.md')
    git('-C', @source, '-c', 'user.name=Test', '-c', 'user.email=test@example.test',
      'commit', '-m', 'base')
    git('-C', @source, 'remote', 'add', 'origin', @remote)
    git('-C', @source, 'push', 'origin', 'main')
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory
  end

  test 'reuses matching generated content and refuses to overwrite a conflicting ref' do
    publisher = ForemanAnsibleAap::GitPublisher.new
    attributes = publication_attributes("---\n- hosts: all\n")

    first_sha = publisher.publish(attributes)
    advance_base_ref
    matching_sha = publisher.publish(attributes)

    assert_equal first_sha, matching_sha
    assert_equal first_sha, remote_ref_sha

    error = assert_raises(ForemanAnsibleAap::GitPublisher::PublicationError) do
      publisher.publish(publication_attributes("---\n- hosts: tampered\n"))
    end

    assert_match(/already exists with different content/, error.message)
    assert_equal first_sha, remote_ref_sha
  end

  test 'recovers an immutable matching ref when the push result is ambiguous' do
    publisher = ForemanAnsibleAap::GitPublisher.new
    wrapper_directory = File.join(@directory, 'bin')
    FileUtils.mkdir_p(wrapper_directory)
    real_git = '/usr/bin/git'
    push_log = File.join(@directory, 'pushes')
    wrapper = File.join(wrapper_directory, 'git')
    File.write(wrapper, <<~SCRIPT)
      #!/bin/sh
      if [ "$1" = "push" ]; then
        printf 'push\n' >> "$FOREMAN_AAP_TEST_PUSH_LOG"
        "#{real_git}" "$@"
        exit 1
      fi
      exec "#{real_git}" "$@"
    SCRIPT
    FileUtils.chmod(0o700, wrapper)

    previous_path = ENV.fetch('PATH')
    previous_log = ENV['FOREMAN_AAP_TEST_PUSH_LOG']
    ENV['PATH'] = "#{wrapper_directory}:#{previous_path}"
    ENV['FOREMAN_AAP_TEST_PUSH_LOG'] = push_log
    sha = publisher.publish(publication_attributes("---\n- hosts: all\n"))

    assert_equal remote_ref_sha, sha
    assert_equal ["push\n"], File.readlines(push_log)
  ensure
    ENV['PATH'] = previous_path if previous_path
    ENV['FOREMAN_AAP_TEST_PUSH_LOG'] = previous_log
  end

  private

  def publication_attributes(content)
    {
      repository_url: @remote,
      base_ref: 'main',
      ref: 'foreman/production/job-invocation-42',
      path: 'generated/foreman.yml',
      content: content,
      username: '',
      password: '',
    }
  end

  def remote_ref_sha
    git('--git-dir', @remote, 'rev-parse', 'refs/heads/foreman/production/job-invocation-42').strip
  end

  def advance_base_ref
    File.write(File.join(@source, 'README.md'), "generated playbooks, retained externally\n")
    git('-C', @source, 'add', 'README.md')
    git('-C', @source, '-c', 'user.name=Test', '-c', 'user.email=test@example.test',
      'commit', '-m', 'advance base')
    git('-C', @source, 'push', 'origin', 'main')
  end

  def git(*arguments)
    stdout, stderr, status = Open3.capture3('git', *arguments)
    raise stderr unless status.success?

    stdout
  end
end
