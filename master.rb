# Launches the worker and initiates updates

require File.join( File.dirname(__FILE__), 'server' )

class Master
  def initialize
    # config files are loaded relative to working dir, not this file
    @api_config = Configuration.new 'servers.yml'   # relative to working dir
    @local_config = Configuration.new File.join( File.dirname(__FILE__), 'master.yml' ) # in repo folder
    
    @worker = Server.new @api_config, 'worker_v1'
    @update_cmd = @local_config['update_cmd']
    @log_path = @local_config['log_path']
  end
  
  # Initiate the update on the worker
  def initiate_update
    puts "--------"
    puts "Starting update at #{Time.now}"
    @worker.up
    puts "Initiating remote update at #{Time.now}."
    if @worker.initiate "#{@update_cmd} >> #{@log_path}"
      puts 'OK'
      #we're done, remote script will handle shutdown after it finishes
    else
      raise 'Failed to initiate remote update!'
    end
  rescue Exception => e
    puts e
    puts e.backtrace
    @worker.shutdown
  ensure
    puts "\n\n"
  end
  
  # Read command line options and take action
  def run argv
    if argv[0]=='update'
      initiate_update
    elsif argv[0]=='up'
      @worker.up
    elsif argv[0]=='down'
      @worker.down
    elsif argv[0]=='status'
      puts "Worker is #{@worker.status}"
    elsif argv[0]=='test'
      puts "Test at #{Time.now}."
    end
  end
end
