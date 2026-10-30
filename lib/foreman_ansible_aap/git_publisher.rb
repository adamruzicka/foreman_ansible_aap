# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'

module ForemanAnsibleAap
  class GitPublisher
    class PublicationError < StandardError; end

    def publish(attributes)
      validate_path!(attributes.fetch(:path))
      Dir.mktmpdir('foreman-ansible-aap') do |directory|
        environment = credential_environment(directory, attributes)
        repository = File.join(directory, 'repository')
        run(environment, 'git', 'clone', '--no-checkout', attributes.fetch(:repository_url), repository)
        run(environment, 'git', 'checkout', attributes.fetch(:base_ref), chdir: repository)
        write_playbook(repository, attributes.fetch(:path), attributes.fetch(:content))
        run(environment, 'git', 'add', '--', attributes.fetch(:path), chdir: repository)
        run(environment, 'git', '-c', 'user.name=Foreman AAP', '-c', 'user.email=foreman-aap@localhost',
          'commit', '-m', "Foreman Job Invocation #{attributes.fetch(:ref)}", chdir: repository)
        commit_sha = run(environment, 'git', 'rev-parse', 'HEAD', chdir: repository).strip
        run(environment, 'git', 'push', 'origin', "HEAD:refs/heads/#{attributes.fetch(:ref)}", chdir: repository)
        commit_sha
      end
    end

    private

    def validate_path!(path)
      pathname = Pathname.new(path)
      return unless pathname.absolute? || pathname.each_filename.include?('..')

      raise PublicationError, "Generated playbook path must stay inside the repository: #{path}"
    end

    def credential_environment(directory, attributes)
      askpass = File.join(directory, 'askpass')
      File.write(askpass, <<~'SCRIPT')
        #!/bin/sh
        case "$1" in
          *sername*) printf '%s\n' "$FOREMAN_AAP_GIT_USERNAME" ;;
          *) printf '%s\n' "$FOREMAN_AAP_GIT_PASSWORD" ;;
        esac
      SCRIPT
      FileUtils.chmod(0o700, askpass)
      {
        'GIT_ASKPASS' => askpass,
        'GIT_TERMINAL_PROMPT' => '0',
        'FOREMAN_AAP_GIT_USERNAME' => attributes.fetch(:username).to_s,
        'FOREMAN_AAP_GIT_PASSWORD' => attributes.fetch(:password).to_s,
      }
    end

    def write_playbook(repository, path, content)
      destination = File.join(repository, path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, content)
    end

    def run(environment, *command, chdir: nil)
      options = chdir ? { chdir: chdir } : {}
      stdout, stderr, status = Open3.capture3(environment, *command, **options)
      return stdout if status.success?

      raise PublicationError, "#{command.first(2).join(' ')} failed: #{stderr.strip}"
    end
  end
end
