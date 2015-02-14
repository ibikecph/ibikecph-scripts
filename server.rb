# Handles cloud.dk server automation API
# https://docs.onapp.com/display/33API/OnApp+3.3+API+Guide
#
# ssh keys must be setup beforehand so password is not needed

require 'net/http'
require 'json'
require File.join( File.dirname(__FILE__), 'configuration' )

# Manages a single virtual server
class Server
  def initialize config, key
    @config = config
    raise "Config missing!" unless @config
    
    @settings = config['servers'][key.to_s]
    raise "Settings for server #{key} missing!" unless @settings

    @id = @settings['id']
    raise "Server id for server #{key} missing!" unless @id

    @hostname = @settings['hostname']
    raise "Hostname id for server #{key} missing!" unless @hostname
    
    @ssh_user = @settings['ssh_user']
    raise "SSH user for server #{key} missing!" unless @ssh_user    
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
      if system %{ssh -o PasswordAuthentication=no -q #{@ssh_user}@#{@hostname} "whoami" 2>&1 > /dev/null}
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
    system %{ssh #{@ssh_user}@#{@hostname} "nohup #{cmd} 2>&1 < /dev/null &"}
  end
    
  private
  
  def http_get call
    http_call call, :get
  end
  
  def http_post call
    http_call call, :post
  end

  def http_call call, method=:get
    uri = URI("#{@config['api_hostname']}/virtual_machines/#{@id}/#{call}.json")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    if method == :post
      request = Net::HTTP::Post.new(uri.path)
    else
      request = Net::HTTP::Get.new(uri.path)
    end
    request.basic_auth @config['api_username'], @config['api_password']
    response = http.start {|http| http.request(request) }
    check_response response
    response
  end
end
