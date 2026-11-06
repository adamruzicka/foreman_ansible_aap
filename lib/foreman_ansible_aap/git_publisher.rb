# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'

module ForemanAnsibleAap
  class GitPublisher
    class PublicationError < StandardError; end

    DETERMINISTIC_COMMIT_ENVIRONMENT = {
      'GIT_AUTHOR_DATE' => '2000-01-01T00:00:00Z',
      'GIT_COMMITTER_DATE' => '2000-01-01T00:00:00Z',
    }.freeze

    def publish(attributes)
      validate_path!(attributes.fetch(:path))
      validate_ref!(attributes.fetch(:ref))
      Dir.mktmpdir('foreman-ansible-aap') do |directory|
        environment = credential_environment(directory, attributes)
        repository = File.join(directory, 'repository')
        run(environment, 'git', 'clone', '--no-checkout', attributes.fetch(:repository_url), repository)
        run(environment, 'git', 'checkout', attributes.fetch(:base_ref), chdir: repository)
        write_playbook(repository, attributes.fetch(:path), attributes.fetch(:content))
        run(environment, 'git', 'add', '--', attributes.fetch(:path), chdir: repository)
        commit_environment = environment.merge(DETERMINISTIC_COMMIT_ENVIRONMENT)
        run(commit_environment, 'git', '-c', 'user.name=Foreman AAP', '-c', 'user.email=foreman-aap@localhost',
          'commit', '-m', "Foreman Job Invocation #{attributes.fetch(:ref)}", chdir: repository)
        commit_sha = run(environment, 'git', 'rev-parse', 'HEAD', chdir: repository).strip
        existing_sha = remote_ref_sha(environment, repository, attributes.fetch(:ref))
        if existing_sha
          return matching_existing_content!(
            environment, repository, attributes.fetch(:ref), existing_sha,
            attributes.fetch(:path), attributes.fetch(:content)
          )
        end

        begin
          run(environment, 'git', 'push', 'origin', "HEAD:refs/tags/#{attributes.fetch(:ref)}", chdir: repository)
          commit_sha
        rescue PublicationError
          # A concurrent publisher may have won the create-only race. Re-read the
          # immutable ref and accept it only when it contains the same artifact.
          existing_sha = remote_ref_sha(environment, repository, attributes.fetch(:ref))
          raise unless existing_sha

          matching_existing_content!(
            environment, repository, attributes.fetch(:ref), existing_sha,
            attributes.fetch(:path), attributes.fetch(:content)
          )
        end
      end
    end

    private

    def validate_path!(path)
      pathname = Pathname.new(path)
      return unless pathname.absolute? || pathname.each_filename.include?('..')

      raise PublicationError, "Generated playbook path must stay inside the repository: #{path}"
    end

    def validate_ref!(ref)
      return if ref.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}) &&
                !ref.include?('..') && !ref.end_with?('/') && !ref.include?('//') &&
                !ref.end_with?('.lock') && !ref.include?('.lock/')

      raise PublicationError, "Generated Git ref is invalid: #{ref.inspect}"
    end

    # Tag refs are fetched by AAP's default fetch refspec (unlike refs in
    # custom namespaces) and are not expected to move, which keeps the
    # per-invocation artifact immutable from AAP's point of view.
    TAG_REF = ->(ref) { "refs/tags/#{ref}" }

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
      relative = Pathname.new(destination).relative_path_from(Pathname.new(repository))
      relative.descend do |component|
        candidate = File.join(repository, component.to_s)
        raise PublicationError, "Generated playbook path contains a symbolic link: #{path}" if File.symlink?(candidate)
      end
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, content)
    end

    def remote_ref_sha(environment, repository, ref)
      output = run(environment, 'git', 'ls-remote', '--tags', 'origin', TAG_REF.call(ref), chdir: repository)
      output.split.first
    end

    def matching_existing_content!(environment, repository, ref, existing_sha, path, expected_content)
      run(environment, 'git', 'fetch', 'origin', TAG_REF.call(ref), chdir: repository)
      existing_content = begin
        run(environment, 'git', 'show', "FETCH_HEAD:#{path}", chdir: repository)
      rescue PublicationError
        raise_conflicting_ref!(ref)
      end
      return existing_sha if existing_content == expected_content

      raise_conflicting_ref!(ref)
    end

    def raise_conflicting_ref!(ref)
      raise PublicationError, "Generated Git ref #{ref} already exists with different content"
    end

    def run(environment, *command, chdir: nil)
      options = chdir ? { chdir: chdir } : {}
      stdout, stderr, status = Open3.capture3(environment, *command, **options)
      return stdout if status.success?

      raise PublicationError, "#{command.first(2).join(' ')} failed: #{stderr.strip}"
    end
  end
end
