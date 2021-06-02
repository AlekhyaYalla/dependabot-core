# frozen_string_literal: true

require "dependabot/file_updaters"
require "dependabot/file_updaters/base"
require "dependabot/errors"
require "dependabot/terraform/file_selector"
require "dependabot/shared_helpers"

module Dependabot
  module Terraform
    class FileUpdater < Dependabot::FileUpdaters::Base
      include FileSelector

      def self.updated_files_regex
        [/\.tf$/, /\.hcl$/]
      end

      def updated_dependency_files
        updated_files = []
        
        [*terraform_files, *terragrunt_files, *lock_file].each do |file|
          next unless file_changed?(file)
          
          updated_content = updated_terraform_file_content(file)
          raise "Content didn't change!" if updated_content == file.content

          updated_files << updated_file(file: file, content: updated_content)
        end
        updated_files.compact!

        raise "No files changed!" if updated_files.none?

        updated_files
      end
      
      private

      def updated_terraform_file_content(file)
        content = file.content.dup


        reqs = dependency.requirements.zip(dependency.previous_requirements).
               reject { |new_req, old_req| new_req == old_req }

        # Loop through each changed requirement and update the files and lockfile
        reqs.each do |new_req, old_req|
          raise "Bad req match" unless new_req[:file] == old_req[:file]
          next unless new_req.fetch(:file) == file.name

          case new_req[:source][:type]
          when "git"
            update_git_declaration(new_req, old_req, content, file.name)
          when "registry" 
            update_registry_declaration(new_req, old_req, content)
          when "provider"
            update_registry_declaration(new_req, old_req, content)
          when "lockfile"
            update_lockfile_declaration(new_req, old_req, content, file.name)
          else
            raise "Don't know how to update a #{new_req[:source][:type]} "\
                  "declaration!"
          end
        end

        content
      end

      def update_git_declaration(new_req, old_req, updated_content, filename)
        url = old_req.fetch(:source)[:url].gsub(%r{^https://}, "")
        tag = old_req.fetch(:source)[:ref]
        url_regex = /#{Regexp.quote(url)}.*ref=#{Regexp.quote(tag)}/

        declaration_regex = git_declaration_regex(filename)

        updated_content.sub!(declaration_regex) do |regex_match|
          regex_match.sub(url_regex) do |url_match|
            url_match.sub(old_req[:source][:ref], new_req[:source][:ref])
          end
        end
      end

      def update_registry_declaration(new_req, old_req, updated_content)
        regex = new_req[:source][:type] == "provider" ? provider_declaration_regex : registry_declaration_regex
        updated_content.sub!(regex) do |regex_match|
          regex_match.sub(/^\s*version\s*=.*/) do |req_line_match|
            req_line_match.sub(old_req[:requirement], new_req[:requirement])
          end
        end
      end

      def update_lockfile_declaration(new_req, old_req, updated_content, filename)
        return unless lock_file?(filename)

        provider_source = new_req[:source][:registry_hostname] + "/" + new_req[:source][:module_identifier]
        declaration_regex = lockfile_declaration_regex(provider_source)
        lockfile_dependency_removed = updated_content.sub(declaration_regex, "")

        copy_dir_to_temporary_directory do
          File.write(".terraform.lock.hcl", lockfile_dependency_removed)
          SharedHelpers.run_shell_command("terraform providers lock #{provider_source}")

          updated_lockfile = File.read(".terraform.lock.hcl")
          updated_dependency = updated_lockfile.scan(declaration_regex).first

          updated_content.sub!(declaration_regex, updated_dependency)
        end

      end

      def dependency
        # Terraform updates will only ever be updating a single dependency
        dependencies.first
      end

      def files_with_requirement
        filenames = dependency.requirements.map { |r| r[:file] }
        dependency_files.select { |file| filenames.include?(file.name) }
      end

      def check_required_files
        return if [*terraform_files, *terragrunt_files].any?

        raise "No Terraform configuration file!"
      end

      def provider_declaration_regex
        name = Regexp.escape(dependency.name)
        /
          ((source\s*=\s*["']#{name}["']|\s*#{name}\s*=\s*\{.*)
          (?:(?!^\}).)+)
        /mx
      end

      def registry_declaration_regex
        /
          (?<=\{)
          (?:(?!^\}).)*
          source\s*=\s*["']#{Regexp.escape(dependency.name)}["']
          (?:(?!^\}).)*
        /mx
      end

      def git_declaration_regex(filename)
        # For terragrunt dependencies there's not a lot we can base the
        # regex on. Just look for declarations within a `terraform` block
        return /terraform\s*\{(?:(?!^\}).)*/m if terragrunt_file?(filename)

        # For modules we can do better - filter for module blocks that use the
        # name of the dependency
        /
          module\s+["']#{Regexp.escape(dependency.name)}["']\s*\{
          (?:(?!^\}).)*
        /mx
      end

      def lockfile_declaration_regex(provider_source)
        /
          (?:(?!^\}).)*
          provider\s*["']#{Regexp.escape(provider_source)}["']\s*\{
          (?:(?!^\}).)*}
        /mx
      end

      def copy_dir_to_temporary_directory
        SharedHelpers.in_a_temporary_directory do
          dependency_files.each do |file|
            # Do not include the .terraform directory or .terraform.lock.hcl
            next if file.name.include?(".terraform")
            File.write(file.name, file.content)
          end
          yield
        end
      end

    end
  end
end

Dependabot::FileUpdaters.
  register("terraform", Dependabot::Terraform::FileUpdater)
