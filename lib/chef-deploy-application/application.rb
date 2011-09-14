
require 'chef'
require 'chef/application'
require 'chef/client'
require 'chef/config'
require 'chef/daemon'
require 'chef/log'
require 'chef/rest'
require 'chef/handler/error_report'

require "chef-deploy-application/version"

class Chef::Application::DeployApplication < Chef::Application

  # Mimic self_pipe sleep from Unicorn to capture signals safely
  SELF_PIPE = []

  option :config_file,
    :short => "-c CONFIG",
    :long  => "--config CONFIG",
    :default => "/etc/chef/client.rb",
    :description => "The configuration file to use"

  option :log_level,
    :short        => "-l LEVEL",
    :long         => "--log_level LEVEL",
    :description  => "Set the log level (debug, info, warn, error, fatal)",
    :proc         => lambda { |l| l.to_sym }

  option :log_location,
    :short        => "-L LOGLOCATION",
    :long         => "--logfile LOGLOCATION",
    :description  => "Set the log file location, defaults to STDOUT - recommended for daemonizing",
    :proc         => nil

  option :help,
    :short        => "-h",
    :long         => "--help",
    :description  => "Show this message",
    :on           => :tail,
    :boolean      => true,
    :show_options => true,
    :exit         => 0

  option :user,
    :short => "-u USER",
    :long => "--user USER",
    :description => "User to set privilege to",
    :proc => nil

  option :group,
    :short => "-g GROUP",
    :long => "--group GROUP",
    :description => "Group to set privilege to",
    :proc => nil

  option :json_attribs,
    :short => "-j JSON_ATTRIBS",
    :long => "--json-attributes JSON_ATTRIBS",
    :description => "Load attributes from a JSON file or URL",
    :proc => nil

  option :node_name,
    :short => "-N NODE_NAME",
    :long => "--node-name NODE_NAME",
    :description => "The node name for this client",
    :proc => nil

  option :chef_server_url,
    :short => "-S CHEFSERVERURL",
    :long => "--server CHEFSERVERURL",
    :description => "The chef server URL",
    :proc => nil

  option :validation_key,
    :short        => "-K KEY_FILE",
    :long         => "--validation_key KEY_FILE",
    :description  => "Set the validation key file location, used for registering new clients",
    :proc         => nil

  option :client_key,
    :short        => "-k KEY_FILE",
    :long         => "--client_key KEY_FILE",
    :description  => "Set the client key file location",
    :proc         => nil

  option :environment,
    :short        => '-E ENVIRONMENT',
    :long         => '--environment ENVIRONMENT',
    :description  => 'Set the Chef Environment on the node'

  option :version,
    :short        => "-v",
    :long         => "--version",
    :description  => "Show chef version",
    :boolean      => true,
    :proc         => lambda {|v| puts "Chef Deploy Application: #{::ChefDeployApplicationGem::VERSION}"},
    :exit         => 0

  attr_reader :chef_client_json

  def initialize
    super

    @chef_client = nil
    @chef_client_json = nil
  end

  # Reconfigure the chef client
  # Re-open the JSON attributes and load them into the node
  def reconfigure
    super

    Chef::Config[:chef_server_url] = config[:chef_server_url] if config.has_key? :chef_server_url
    unless Chef::Config[:exception_handlers].any? {|h| Chef::Handler::ErrorReport === h}
      Chef::Config[:exception_handlers] << Chef::Handler::ErrorReport.new
    end

    # Run chef once and exit
    Chef::Config[:interval] = nil
    Chef::Config[:splay] = nil

    if Chef::Config[:json_attribs]
      begin
        json_io = case Chef::Config[:json_attribs]
                  when /^(http|https):\/\//
                    @rest = Chef::REST.new(Chef::Config[:json_attribs], nil, nil)
                    @rest.get_rest(Chef::Config[:json_attribs], true).open
                  else
                    open(Chef::Config[:json_attribs])
                  end
      rescue SocketError => error
        Chef::Application.fatal!("I cannot connect to #{Chef::Config[:json_attribs]}", 2)
      rescue Errno::ENOENT => error
        Chef::Application.fatal!("I cannot find #{Chef::Config[:json_attribs]}", 2)
      rescue Errno::EACCES => error
        Chef::Application.fatal!("Permissions are incorrect on #{Chef::Config[:json_attribs]}. Please chmod a+r #{Chef::Config[:json_attribs]}", 2)
      rescue Exception => error
        Chef::Application.fatal!("Got an unexpected error reading #{Chef::Config[:json_attribs]}: #{error.message}", 2)
      end

      begin
        @chef_client_json = Chef::JSONCompat.from_json(json_io.read)
        json_io.close unless json_io.closed?
      rescue JSON::ParserError => error
        Chef::Application.fatal!("Could not parse the provided JSON file (#{Chef::Config[:json_attribs]})!: " + error.message, 2)
      end
    end
  end

  def configure_logging
    super
    Mixlib::Authentication::Log.use_log_devices( Chef::Log )
    Ohai::Log.use_log_devices( Chef::Log )
  end

  def setup_application
    Chef::Daemon.change_privilege
  end

  # Run the chef client, optionally daemonizing or looping at intervals.
  def run_application
    if no_app_name_given?
      puts "You must provide the name of an application to deploy."
      exit 1
    end

    begin
      Chef::Log.info("*** Chef #{Chef::VERSION} ***")

      # Make sure the client knows this is not chef solo
      Chef::Config[:solo] = false

      # Rebuild node
      client = Chef::Client.new
      client.run_ohai
      client.register
      client.build_node


      # Shorten node inspection
      node = client.node
      def node.inspect
        "<Chef::Node:0x#{self.object_id.to_s(16)} @name=\"#{self.name}\">"
      end

      # Rebuild context
      run_status = Chef::RunStatus.new(node)
      Chef::Cookbook::FileVendor.on_create { |manifest| Chef::Cookbook::RemoteFileVendor.new(manifest, Chef::REST.new(Chef::Config[:server_url])) }
      cookbook_hash = client.sync_cookbooks
      cookbooks = Chef::CookbookCollection.new(cookbook_hash)

      run_context = Chef::RunContext.new(node, cookbooks)
      run_context.load(Chef::RunList::RunListExpansionFromAPI.new(node.chef_environment, []))
      run_status.run_context = run_context

      # Merge json
      node.consume_attributes(@chef_client_json) if @chef_client_json

      # Setup the recipe
      app_name = application_name
      recipe = Chef::Recipe.new(nil, nil, run_context)
      recipe.instance_eval do
        app = search(:apps, "id:#{app_name}").first
        raise "Cannot find an application named #{app_name}" unless app

        server_roles = (app["server_roles"] & node.run_list.roles)
        if server_roles.empty?
          Chef::Log.info("None of this server's roles match the app's server_roles.")
        else
          server_roles.each do |app_role|
            app["type"][app_role].each do |thing|
              recipe_name = "application::#{thing}"
              node.run_state[:current_app] = app
              node.run_state[:seen_recipes].delete(recipe_name)
              include_recipe recipe_name
            end
          end
        end

        node.run_state.delete(:current_app)
      end

      # Run the recipe
      Chef::Runner.new(run_context).converge

      Chef::Application.exit! "Exiting", 0
    rescue SystemExit => e
      raise
    rescue Exception => e
      Chef::Application.debug_stacktrace(e)
      Chef::Application.fatal!("#{e.class}: #{e.message}", 1)
    end
  end

  private

  def application_name
    return nil if no_app_name_given?
    ARGV[0]
  end

  def no_app_name_given?
    ARGV.empty?
  end

end
