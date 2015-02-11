#!/usr/bin/env ruby

# Check the Nagios JSON interface provided by nagios-api (TODO: Add link and doc)
# This is pattern for querying the Nagios server

require 'chef/search/query'
require 'date'
require 'json'
require 'logger'
require 'mixlib/cli'
require 'net/https'

# == CLI - Set up an options parser
class ChronosCheckCli
  include Mixlib::CLI

  # Help text
  help_text = <<-EOF
Show this help message

    chronos_check - a Nagios check for AirBnB Chronos.

    Syntax Detail:
    A valid Chef Environment and a verb are required at minimum.

    chronos_check -e <chev_environment>  /-t|-p|-w/ [long_options]

    Searches Chef for nodes running the Chronos recipe in their run_lists
    Writes Nagios configuration files from a query of Chronos tasks.
    Produces a Nagios/NRPE check result for a named task.
    Posts to Zorkian's Nagios API (https://github.com/zorkian/nagios-api).

    Proprietary License - Do Not Distribute
  EOF

  description_env = <<-EOF
Chef Environment - chronos_check searches
                                     the specified Chef Environment to find
                                     nodes with the Chronos recipe in their run
                                     lists.  Defaults to _default

  EOF

  description_config = <<-EOF
Path to Chef configuration file(s)
                                     chronos_check attempts to load configuration
                                     file(s) in order until one of them loads
                                     successfully. chronos_check is preconfigured
                                     to search Chef configuration files in the
                                     following order:
                                     ${HOME}/.chef/knife.rb
                                     ${HOME}/.chef/client.rb
                                     /etc/chef/knife.rb
                                     /etc/chef/client.rb

  EOF

  description_nagios_check = <<-EOF
Nagios Check - Return a Nagios check
                                     result from named Chronos Task <task>.
                                     chronos_check will output standard Nagios
                                     check messages exit codes.

  EOF

  description_nagios_api = <<-EOF
Post to Nagios API - Post all checks to
                                     Nagios API. (You must have Zorkian's
                                     Nagios API installed and running. See
                                     https://github.com/zorkian/nagios-api

  EOF

  description_write_config = <<-EOF
Write to Nagios config files - Process
                                     Chronos task names into individual Nagios
                                     checks. chronos_check is hard-coded to
                                     write to /etc/nagios/commands/chronos_check.cfg
                                     and /etc/nagios/objects/servers/<chronos_host>.cfg

  EOF

  # === Required Arguments
  # A Chef environment and configuration are required; however these defaults
  # should allow this command to run even if no arguments are given.

  option :env,
         :boolean => false,
         :default => '_default',
         :description => description_env,
         :long  => '--env <chef_environment>',
         :required => false,
         :short => '-e ENVIRONMENT'

  option :chef_config,
         :boolean => false,
         :default => %w(~/.chef/knife.rb ~/.chef/client.rb /etc/chef/knife.rb /etc/chef/client.rb),
         :description => description_config,
         :long  => '--config <path>',
         :required => false,
         :short => '-c PATH'

  # === Verbs - Short Options Only

  option :nagios_check,
         :boolean => false,
         :description => description_nagios_check,
         :required => false,
         :short => '-t <chronos_task_name>'

  option :post_api,
         :boolean => true,
         :default => false,
         :description => description_nagios_api,
         :required => false,
         :short => '-p'

  option :write_config,
         :boolean => true,
         :default => false,
         :description => description_write_config,
         :required => false,
         :short => '-w'

  # === Configuration - Long Options Only

  option :proto,
         :boolean => true,
         :default => false,
         :description => 'Specify HTTPS to contact the Chronos server (defaults to HTTP)',
         :long  => '--https',
         :required => false

  option :state_file,
         :boolean => false,
         :default => '/tmp/chronos-state.json',
         :description => 'Path to the state file',
         :long  => '--state-file <path>',
         :required => false

  option :state_file_age,
         :boolean => false,
         :default => 3,
         :description => 'Amount of time to allow before timing out and refreshing the state file',
         :long  => '--state-timeout <minutes>',
         :required => false

  option :verbose,
         :boolean => true,
         :default => false,
         :description => 'Turn on verbose logging',
         :long  => '--verbose',
         :required => true,
         :short => '-v'

  option :help,
         :boolean => true,
         :default => false,
         :description => help_text,
         :exit => 0,
         :long => '--help',
         :on => :tail,
         :short => '-h',
         :show_options => true
end

# == ChronosCheck - a class to find a Chronos node and query it for task status.
class ChronosCheck

	# === Initialize Class
	# For now feed in the port and protocol.
	def initialize(*args)	# ChronosCheck.new(chef_environment, chef_config, chronos_protocol, state_file, state_file_age)
    @chef_environment = "#{args[0]}"||'_default'

    args[1] = args[1].split(/, /) if args[1].class == 'String'
    @chef_configs = args[1]||%w(~/.chef/knife.rb ~/.chef/client.rb /etc/chef/knife.rb /etc/chef/client.rb)

    @chronos_proto = args[2]||'http'
		@state_file = File.expand_path(args[3])||'/tmp/chronos-state.json'
		@state_file_age = args[4]||3
    @logger = Logger.new(STDOUT)
	end

  # === Configure Chronos Server using Chef
  def get_chef_node
    # Set up logging

    # If our target environment doesn't exist, fail gracefully.
    available_environments = Chef::Environment.list.keys
    raise @logger.fatal("Environment does not exist on Chef server! #{@chef_environment}") unless
        available_environments.include?(@chef_environment)

    # Configure Chef for this instance of the class.
    @chef_configs.each do |config|
      if ( ! File.exist?(config) ) && ( config == @chef_configs.last )
        raise @logger.fatal("Could not load Chef configuration from: #{@chef_configs.join(', ')}")
      elsif ! File.exist?(config)
        next
      elsif ! Chef::Config.from_file(File.expand_path(config))
        next
      else
        raise @logger.fatal("Could not load Chef configuration from: #{config}")
      end
    end

    # Search Chef for nodes that are running the Chronos recipe in the selected
    # @chef_environment.  Pick a server at random from the list.
    chef_query = Chef::Search::Query.new
    raise @logger.fatal("Could not find a Cronos node in #{@chef_environment}") unless
        ( chronos_node_name =
            chef_query.search('node', "recipes:*chronos* AND chef_environment:#{@chef_environment}")[0]
                .sample.name )

    # Load the Chronos server's Chef node data
    # noinspection RubyResolve
    raise @logger.fatal("Could not load node data for #{chronos_node_name}") unless
        ( chronos_node = Chef::Node.load(chronos_node_name.to_s) )

    # Set the Chronos server's base URL.
    @chronos_base_url = "#{@chronos_proto}://#{chronos_node['fqdn']}:#{chronos_node['chronos']['http_port']}"

    # Return the Node object as the output of the method.
    chronos_node
  end

  # === Get State from the Chronos Server
  def refresh_state
    self.get_chef_node
    begin
      chronos_url = URI.parse("#{@chronos_base_url}/scheduler/jobs")

      # Get task data from the Chronos API
      chronos_response = JSON.parse(Net::HTTP.get(chronos_url)).sort_by { |task| task['name'] }
      state_data = {
          :chronos_url => chronos_url,
          :query_time => DateTime.now,
          :tasks => chronos_response
      }
      @state_data = state_data

      # Write to the State file
      File.open(@state_file, 'w') do |file|
        file.write(JSON.pretty_generate(@state_data))
      end
    rescue
      raise @logger.fatal("Could not generate state data in file #{@state_file} from #{chronos_url}")
    end
  end

  # === Check for state freshness and update if necessary
  def state_timer
    # Set the time the state file expires, based on @state_file_age
    state_file_expires_on = DateTime.now - Rational(@state_file_age.to_i, 1440)

    # If the state file doesn't exist, refresh state data and write state file
    if ! File.exist?(@state_file)
      self.refresh_state

    # Else if the state file exists, test its validity
    elsif File.exist?(@state_file)
      # Get the state file's timestamp.
      state_file_timestamp = DateTime.parse(JSON.parse(File.read(@state_file))['query_time'])

      # TODO: If the file timestamp and doesn't match the modify time, assume tampering and refresh state data.

      # Refresh state unless the state file's timestamp shows that it hasn't yet expired.
      self.refresh_state unless state_file_timestamp < state_file_expires_on
    else
      false
    end
  end

  # === Parse tasks from the state file.
  def parse_tasks
    # Refresh state if needed, set up variables.
    self.state_timer
		chronos_tasks = JSON.parse(File.read(@state_file))
    chronos_domain = URI.parse(chronos_tasks['chronos_url']).host.split('.').drop(1).join('.')

		# Prepare state information for Nagios checks
    task_data = []
    chronos_tasks['tasks'].each do |task|


      # Parse the success and error times if any have been recorded.
      (task['lastError'] == '') ?
          last_error = nil :
          last_error = DateTime.parse(task['lastError'])

      (task['lastSuccess'] == '') ?
          last_success = nil :
          last_success = DateTime.parse(task['lastSuccess'])

      # Output a Nagios WARNING if the task is disabled.
      if task['disabled']
        status = 1
        output = "#{task['name']} WARNING: Task disabled!"

			# Output a Nagios CRITICAL for enabled tasks with no successes or failure
			elsif ! last_error && ! last_success
				status = 2
				output = "#{task['name']} CRITICAL: Task cannot run! No successful or failed runs."

      # Output a Nagios CRITICAL for tasks that are failing with no successes
      elsif last_error && ! last_success
        status = 2
        output = "#{task['name']} CRITICAL: Task cannot run! No successes, recorded last failure at #{last_error}"

      # Output a Nagios OK for tasks that have succeeded with no failures. TODO: Make sure this is within epsilon
      elsif last_success && ! last_error
        status = 0
        output = "#{task['name']} OK: Task reports success at #{last_success}"

      # Output a Nagios OK for tasks with current success status
      elsif last_success > last_error
        status = 0
        output = "#{task['name']} OK: Task reports recovery at #{last_success} from error at #{last_error}"

      # Output a Nagios CRITICAL for tasks with a current failing status. TODO: Make sure this is within epsilon
      elsif last_error > last_success
        status = 2
        output = "#{task['name']} CRITICAL: Task failed! Error recorded at #{last_success}"

      # TODO: Output a Nagios CRITICAL for tasks that fail to meet their schedule.  Here is the formula:
        # Parse the schedule
      #elsif epsilon > ( last_success + epsilon )
      #  status = 2
      #  output = "#{task['name']} CRITICAL: Task did not run within its epsilon! Last run at #{last_success}"

			# If none of these tests match, then we are in an unknown state
			else
				status = 3
				output = "#{task['name']} UNKNOWN: No conditions match known task state!"

      end

			# Return a hash in preparation for sending a REST call to Nagios
			task_data << {
				:host => "chronos.#{chronos_domain}",
				:service => task['name'],
				:status => status,
				:output => output#,
			}
    end
    task_data
  end

  # === TODO: Write out the Nagios commands definition and chronos host.
  def write_nagios_config
    task_list  = self.parse_tasks
    task_list.each do |task|
      puts JSON.pretty_generate(task)
    end
  end

  # === TODO: Post Chronos task data to Nagios via nagios-api
  def post_nagios
    JSON.pretty_generate(self.parse_tasks)
  end

  # === Submit a check for an individual Chronos task.
  def post_nrpe(task_name)
    nrpe_task = self.parse_tasks.select { |task| task[:service] == task_name }.first
    puts nrpe_task[:output]
    exit(status=nrpe_task[:status].to_i)
  end
end

# == Do some work now!
# Use the classes defined above to perform the checks.

# === Parse the CLI
cli_data = ChronosCheckCli.new
cli_data.parse_options

cli_state_file = File.expand_path(cli_data.config[:state_file])
cli_state_file_age = cli_data.config[:state_file_age].to_i
if cli_data.config[:proto]
  cli_proto = 'https'
else
  cli_proto = 'http'
end

# === Display help if no options are given
if ARGV.empty?
  raise cli_data.config[:help]
end

# === Execute the checks requested by the user.
exec_check = ChronosCheck.new(cli_data.config[:env], cli_data.config[:config], cli_proto, cli_state_file, cli_state_file_age)

if cli_data.config[:post_api]
  puts exec_check.post_nagios
end

if cli_data.config[:write_config]
  puts 'TODO: Write config'
end

if cli_data.config[:nagios_check]
  exec_check.post_nrpe(cli_data.config[:nagios_check])
end
