# Launches the worker and initiates updates

require File.expand_path( File.join( File.dirname(__FILE__), 'server' ) )

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
  def initiate_update options
    puts '-'*60
    puts "Starting update at #{Time.now}"
    @worker.up
    puts "Initiating worker at #{Time.now}."
    if @worker.initiate "#{@worker_bin} #{options.join(' ')} >> #{@log_path}"
      puts 'View log file on worker to check progress'
      #we're done, worker will shut itself down after it finishes
    else
      raise 'Failed to initiate worker!'
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
    if argv[0]=='run'
      argv.shift
      initiate_update argv
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
