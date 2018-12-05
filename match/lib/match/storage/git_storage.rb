require 'fastlane_core/command_executor'

require_relative '../module'
require_relative './interface'

module Match
  module Storage
    # Store the code signing identities in a git repo
    class GitStorage < Interface
      # User provided values
      attr_accessor :git_url
      attr_accessor :shallow_clone
      attr_accessor :skip_docs
      attr_accessor :branch
      attr_accessor :git_full_name
      attr_accessor :git_user_email
      attr_accessor :clone_branch_directly
      attr_accessor :type
      attr_accessor :platform

      def self.configure(params)
        return self.new(
          type: params[:type].to_s,
          platform: params[:platform].to_s,
          git_url: params[:git_url],
          shallow_clone: params[:shallow_clone],
          skip_docs: params[:skip_docs],
          branch: params[:git_branch],
          git_full_name: params[:git_full_name],
          git_user_email: params[:git_user_email],
          clone_branch_directly: params[:clone_branch_directly]
        )
      end

      def initialize(type: nil,
                     platform: nil,
                     git_url: nil,
                     shallow_clone: nil,
                     skip_docs: false,
                     branch: "master",
                     git_full_name: nil,
                     git_user_email: nil,
                     clone_branch_directly: false)
        self.git_url = git_url
        self.shallow_clone = shallow_clone
        self.skip_docs = skip_docs
        self.branch = branch
        self.git_full_name = git_full_name
        self.git_user_email = git_user_email
        self.clone_branch_directly = clone_branch_directly

        self.type = type if type
        self.platform = platform if platform
      end

      def additional_options
        return [
          FastlaneCore::ConfigItem.new(key: :git_url,
                                     env_name: "MATCH_GIT_URL",
                                     description: "URL to the git repo containing all the certificates",
                                     optional: false,
                                     short_option: "-r"),
          FastlaneCore::ConfigItem.new(key: :git_branch,
                                       env_name: "MATCH_GIT_BRANCH",
                                       description: "Specific git branch to use",
                                       default_value: 'master'),
          FastlaneCore::ConfigItem.new(key: :git_full_name,
                                     env_name: "MATCH_GIT_FULL_NAME",
                                     description: "git user full name to commit",
                                     optional: true,
                                     default_value: nil),
          FastlaneCore::ConfigItem.new(key: :git_user_email,
                                       env_name: "MATCH_GIT_USER_EMAIL",
                                       description: "git user email to commit",
                                       optional: true,
                                       default_value: nil),
          FastlaneCore::ConfigItem.new(key: :clone_branch_directly,
                                     env_name: "MATCH_CLONE_BRANCH_DIRECTLY",
                                     description: "Clone just the branch specified, instead of the whole repo. This requires that the branch already exists. Otherwise the command will fail",
                                     is_string: false,
                                     default_value: false),
          FastlaneCore::ConfigItem.new(key: :shallow_clone,
                                     env_name: "MATCH_SHALLOW_CLONE",
                                     description: "Make a shallow clone of the repository (truncate the history to 1 revision)",
                                     is_string: false,
                                     default_value: false)
        ]
      end

      def download
        # Check if we already have a functional working_directory
        return if @working_directory

        # No existing working directory, creating a new one now
        self.working_directory = Dir.mktmpdir

        command = "git clone '#{self.git_url}' '#{self.working_directory}'"
        if self.shallow_clone
          command << " --depth 1 --no-single-branch"
        elsif self.clone_branch_directly
          command += " -b #{self.branch.shellescape} --single-branch"
        end

        UI.message("Cloning remote git repo...")
        if self.branch && !self.clone_branch_directly
          UI.message("If cloning the repo takes too long, you can use the `clone_branch_directly` option in match.")
        end

        begin
          # GIT_TERMINAL_PROMPT will fail the `git clone` command if user credentials are missing
          FastlaneCore::CommandExecutor.execute(command: "GIT_TERMINAL_PROMPT=0 #{command}",
                                              print_all: FastlaneCore::Globals.verbose?,
                                          print_command: FastlaneCore::Globals.verbose?)
        rescue
          UI.error("Error cloning certificates repo, please make sure you have read access to the repository you want to use")
          if self.branch && self.clone_branch_directly
            UI.error("You passed '#{self.branch}' as branch in combination with the `clone_branch_directly` flag. Please remove `clone_branch_directly` flag on the first run for _match_ to create the branch.")
          end
          UI.error("Run the following command manually to make sure you're properly authenticated:")
          UI.command(command)
          UI.user_error!("Error cloning certificates git repo, please make sure you have access to the repository - see instructions above")
        end

        add_user_config(self.git_full_name, self.git_user_email)

        unless File.directory?(self.working_directory)
          UI.user_error!("Error cloning repo, make sure you have access to it '#{self.git_url}'")
        end

        checkout_branch unless self.branch == "master"
      end

      def delete_files(files_to_delete: [], custom_message: nil)
        # No specific list given, e.g. this happens on `fastlane match nuke`
        # We just want to run `git add -A` to commit everything
        git_push(commands: ["git add -A"], commit_message: custom_message)
      end

      def upload_files(files_to_upload: [], custom_message: nil)
        commands = files_to_upload.map do |current_file|
          "git add #{current_file.shellescape}"
        end

        git_push(commands: commands, commit_message: custom_message)
      end

      # Generate the commit message based on the user's parameters
      def generate_commit_message
        [
          "[fastlane]",
          "Updated",
          self.type,
          "and platform",
          self.platform
        ].join(" ")
      end

      private

      # Create and checkout an specific branch in the git repo
      def checkout_branch
        return unless self.working_directory

        commands = []
        if branch_exists?(self.branch)
          # Checkout the branch if it already exists
          commands << "git checkout #{self.branch.shellescape}"
        else
          # If a new branch is being created, we create it as an 'orphan' to not inherit changes from the master branch.
          commands << "git checkout --orphan #{self.branch.shellescape}"
          # We also need to reset the working directory to not transfer any uncommitted changes to the new branch.
          commands << "git reset --hard"
        end

        UI.message("Checking out branch #{self.branch}...")

        Dir.chdir(self.working_directory) do
          commands.each do |command|
            FastlaneCore::CommandExecutor.execute(command: command,
                                                  print_all: FastlaneCore::Globals.verbose?,
                                                  print_command: FastlaneCore::Globals.verbose?)
          end
        end
      end

      # Checks if a specific branch exists in the git repo
      def branch_exists?(branch)
        return unless self.working_directory

        result = Dir.chdir(self.working_directory) do
          FastlaneCore::CommandExecutor.execute(command: "git --no-pager branch --list origin/#{branch.shellescape} --no-color -r",
                                                print_all: FastlaneCore::Globals.verbose?,
                                                print_command: FastlaneCore::Globals.verbose?)
        end
        return !result.empty?
      end

      def add_user_config(user_name, user_email)
        # Add git config if needed
        commands = []
        commands << "git config user.name \"#{user_name}\"" unless user_name.nil?
        commands << "git config user.email \"#{user_email}\"" unless user_email.nil?

        return if commands.empty?

        UI.message("Add git user config to local git repo...")
        Dir.chdir(self.working_directory) do
          commands.each do |command|
            FastlaneCore::CommandExecutor.execute(command: command,
                                                  print_all: FastlaneCore::Globals.verbose?,
                                                  print_command: FastlaneCore::Globals.verbose?)
          end
        end
      end

      def git_push(commands: [], commit_message: nil)
        commit_message ||= generate_commit_message
        commands << "git commit -m #{commit_message.shellescape}"
        commands << "GIT_TERMINAL_PROMPT=0 git push origin #{self.branch.shellescape}"

        UI.message("Pushing changes to remote git repo...")
        commands.each do |command|
          FastlaneCore::CommandExecutor.execute(command: command,
                                                print_all: FastlaneCore::Globals.verbose?,
                                                print_command: FastlaneCore::Globals.verbose?)
        end

        self.clear_changes
      rescue => ex
        UI.error("Couldn't commit or push changes back to git...")
        UI.error(ex)
      end
    end
  end
end
