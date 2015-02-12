# Handles cloud.dk server automation API
# https://docs.onapp.com/display/33API/OnApp+3.3+API+Guide

require 'net/http'
require 'yaml'
require 'json'

# Read configs from an yaml file, including API settings and list of servers
class ServerConfig
  attr_reader :hostname, :username, :password, :servers, :ssh_user
  
  def initialize path
    raise "Config file '#{path} not found." unless File.exists? path
    config = YAML.load_file(path)
    @hostname = config['api_hostname']
    @username = config['api_username']
    @password = config['api_password']
    @ssh_user = config['ssh_user']
    @servers = config['servers']
    raise "hostname missing from config!" unless @hostname
    raise "username missing from config!" unless @username
    raise "password missing from config!" unless @password
    raise "servers missing from config!" unless @servers
  end 
end

# Manages a single virtual server
class Server
  def initialize config, key
    @config = config
    raise "Config missing!" unless @config
    
    @settings = config.servers[key.to_s]
    raise "Settings for server #{key} missing!" unless @settings

    @id = @settings['id']
    raise "Server id for server #{key} missing!" unless @id

    @hostname = @settings['hostname']
    raise "Hostname id for server #{key} missing!" unless @hostname
  end
    
  def status
    response = http_get 'status'
    status = JSON.parse(response.body).first['virtual_machine']
    if status['locked'] == false
      if status['booted'] == true
        :up
      else
        :down
      end
    else
      :pending
    end
  end

  def up?
    status == :up
  end

  def check_response response
    raise "API error code #{response.code}" unless [200,201].include? response.code.to_i
  end

  def startup
    puts "Starting update server at #{Time.now}"
    response = http_post 'startup'
  end
  
  def shutdown
    puts "Shutting down update server at #{Time.now}"
    response = http_post 'shutdown'
  end

  def up
    unless up?
      startup
    else
      puts "Update server already up"
    end
    wait_for_ssh
  end

  def down
    if up?
      shutdown
    else
      puts "Update server already down"
    end
  end

  def wait_for_ssh
    puts 'Waiting for SSH...'
    600.times do
      if system %{ssh #{@config.ssh_user}@#{@hostname} "whoami" 2>&1 > /dev/null}
        puts 'SSH Ready'
        return
      end
      sleep 1
    end
    raise "Timeout while waiting for SSH"
  end
    
  def initiate cmd
    # use ssh to run command on remote server
    # run script in background using '&'
    # use nohup, so it's not terminated when we log out of ssh
    # to avoid ssh hanging, make sure to redirect all three stream: stdout, stderr, stdin
    system %{ssh #{@config.ssh_user}@#{@config.hostname} "nohup #{cmd} 2>&1 < /dev/null &"}
  end
    
  private
  
  def http_get call
    uri = URI("#{@config.hostname}/virtual_machines/#{@id}/#{call}.json")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.path)
    request.basic_auth @config.username, @config.password
    response = http.start {|http| http.request(request) }
    check_response response
    response
  end
  
  def http_post call
    uri = URI("#{@config.hostname}/virtual_machines/#{@id}/#{call}.json")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path)
    request.basic_auth @config.username, @config.password
    response = http.start {|http| http.request(request) }
    check_response response
    response
  end
end
