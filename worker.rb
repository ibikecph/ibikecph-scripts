# runs on the worker and handles actual processing og osrm data and tiles

require File.expand_path( File.join( File.dirname(__FILE__), 'server' ) )
require 'fileutils'

class Worker  
  def initialize
    @api_config = Configuration.new 'servers.yml'   # relative to working dir
    @config = Configuration.new File.join( File.dirname(__FILE__), 'worker.yml' ) # in repo folder
  end

  def time str, divider=:short, &block
    str += ': ' if str
    start = Time.now
    if divider==:long
      puts '-'*50
    else
      puts '---------'
    end
    puts "#{str}Starting at #{start}"
    yield block
    finish = Time.now
    seconds = (Time.now - start).to_i
    formatted = format_time seconds
    puts "#{str}Completed in #{seconds}s / #{formatted}, at #{finish}."
  end

  def run_cmd cmd
    puts cmd
    raise "Failed to run command: #{cmd}" unless system cmd
  end

  def update_osm_data
    run_cmd "osmupdate #{@config['osm_file']} #{@config['new_osm_file']} -B=#{@config['polygon_file']}"
    FileUtils.mv @config['new_osm_file'], @config['osm_file']
  end

  def process
    run_cmd "rm -rf #{@config['data_folder']}/#{@config['package_name']}"
    run_cmd "mkdir -p #{@config['data_folder']}/#{@config['package_name']}"
    timestamp = Time.now
    Dir.chdir "#{@config['data_folder']}" do
      @config['profiles'].each_pair do |k,v|
        puts '----'
        time("Processing profile: #{k}") do      
          run_cmd "rm -rf #{@config['map_name']}.osrm*"
          puts
          run_cmd "#{@config['bin_folder']}/osrm-extract #{@config['osm_file']} #{v['osrm_profile']}"
          puts
          run_cmd "#{@config['bin_folder']}/osrm-prepare #{@config['map_name']}.osrm #{@config['map_name']}.osrm.restrictions #{v['osrm_profile']}"
          puts
          run_cmd "mkdir -p #{@config['package_name']}/#{profile}; mv #{@config['map_name']}.osrm* #{@config['package_name']}/#{k}/"
          run_cmd "echo '#{timestamp}' >> #{@config['data_folder']}/#{@config['package_name']}/#{profile}/#{@config['map_name']}.osrm.timestamp"
        end
      end
    end
  end

  def write_config
    @config['profiles'].each_pair do |t|
      write_ini t[0], t[1]
    end
  end

  def write_ini profile, port
    s = <<-EOF
      Threads = #{@config['osrm_threads']}
      IP = #{@config['osrm_ip']}
      Port = #{port}

      hsgrData=#{@config['map_name']}.osrm.hsgr
      nodesData=#{@config['map_name']}.osrm.nodes
      edgesData=#{@config['map_name']}.osrm.edges
      ramIndex=#{@config['map_name']}.osrm.ramIndex
      fileIndex=#{@config['map_name']}.osrm.fileIndex
      namesData=#{@config['map_name']}.osrm.names
      timestamp=#{@config['map_name']}.osrm.timestamp
    EOF
    File.open( "#{@config['data_folder']}/#{@config['package_name']}/#{profile}/server.ini", 'w') {|f| f.write( s ) }
  end


  def copy_binaries
    run_cmd "cp #{@config['bin_folder']}/osrm-* #{@config['data_folder']}/#{@config['package_name']}/"
  end

  def rsync_osrm_data
    run_cmd "rm -rf #{@config['user']}@#{@config['server']}:/tmp/data"    # remove left-overs if any
    run_cmd "rsync -r --delete --force #{@config['data_folder']}/#{@config['package_name']} #{@config['user']}@#{@config['server']}:/tmp/"
  end

  def postgres
    run_cmd "osm2pgsql -d osm -U osm -c -C8000 --number-processes=5 --style #{@config['import_style_file']}  --tag-transform-script #{@config['import_lua_file']} #{@config['data_folder']}/#{@config['osm_file']}"
  end

  def remove_metatiles
  #  run_cmd "rm -rf /tiles/meta/web/*"
  #  run_cmd "rm -rf /tiles/meta/retina/*"
  end

  def remove_tiles
    run_cmd "rm -rf /tiles/plain/web/*"
    run_cmd "rm -rf /tiles/plain/retina/*"
  #  run_cmd "rm -rf /tiles/plain/background/*"
  end

  def render_tiles
    @config['render_tasks'].each do |options|
      run_cmd "tirex-batch #{options}"
    end

    raw = ''
    (20*60).times do |i|
      sleep 60
      raw = `tirex-status --raw`
      size = /"size" : (\d+)/.match(raw)[1].to_i
      if i%60 == 0
        puts "#{size} tiles left to render, at #{Time.now}"
      end
      return if size==0
    end
    raise "Rendering timed out! Last tirex-status raw: #{raw}"
  end

  def convert_tiles
    run_cmd "#{@config['root']}/meta2tile /tiles/meta/web /tiles/plain/web"
    run_cmd "#{@config['root']}/meta2tile /tiles/meta/retina /tiles/plain/retina"
  #  run_cmd "#{@config['root']}/meta2tile /tiles/meta/background /tiles/plain/background"
  end

  def sync_tiles
    run_cmd "rsync -r --ignore-times /tiles/plain/ root@tiles.ibikecph.dk:/tiles/new/"
    run_cmd %{ssh root@tiles.ibikecph.dk "mv /tiles/current /tiles/old; mv /tiles/new /tiles/current"}
  #  run_cmd %{ssh root@tiles.ibikecph.dk "nohup rm -r /tiles/old >> /dev/null 2>&1 < /dev/null &"}
  end

  def deploy_osrm
    log_msg = "OSRM update deployed at #{Time.now}"
    cmd = <<-EOF
      rm -rf #{@config['server_root']}/#{@config['package_name']}_old;
      stop osrm;
      mv #{@config['server_root']}/#{@config['package_name']} #{@config['server_root']}/#{@config['package_name']}_old;
      mv /tmp/#{@config['package_name']} #{@config['server_root']}/#{@config['package_name']};
      start osrm;
      echo '#{log_msg}' >> #{@config['server_root']}/log/deploy.log;
    EOF
    run_cmd %{ssh #{@config['user']}@#{@config['server']} "#{cmd}" }
  end

  def format_time total_seconds
    seconds = total_seconds % 60
    minutes = (total_seconds / 60) % 60
    hours = total_seconds / (60 * 60)
    format("%02d:%02d:%02d", hours, minutes, seconds)
  end

  def shutdown
    me = Server.new @api_config, :worker_v1
    me.shutdown
  end

  def run argv
    time(nil, :long) do
      begin
        all = argv.include?('all')

        run_cmd "df -h"
        run_cmd "df -i"
        #run_cmd "free -m"

        if all || argv.include?('osm')
          time("Updating OSM data") { update_osm_data }
        end
        if all || argv.include?('osrm')
          time("Preprocess OSRM data") { process }
          time("Writing OSRM configuration") { write_config }
          time("Copy binaries") { copy_binaries }
        end
        if all || argv.include?('sync-osrm')
          time("Sync data to route server") { rsync_osrm_data }
        end
        if all || argv.include?('deploy-osrm')
          time("Swap folders and restart OSRM") { deploy_osrm }
        end
        if all || argv.include?('db')
          time("Import to Postgres") { postgres }
        end
        if argv.include?('clean-tiles')
          time("Remove old meta-tiles") { remove_metatiles }
          time("Remove old tiles") { remove_tiles }
        end
        if all || argv.include?('tiles')
          time("Remove old meta-tiles") { remove_metatiles }
          time("Remove old tiles") { remove_tiles }
          time("Render meta-tiles") { render_tiles }
          time("Convert meta-tiles") { convert_tiles }
        end
        if all || argv.include?('sync-tiles')
          time("Sync tiles to tiles server") { sync_tiles }
        end
        if all || argv.include?('test')
          time("Test") {}
        end
        
      rescue Exception => e
        puts "*** An error occurred:"
        puts e
        puts e.backtrace
      ensure
        if all || argv.include?('shutdown')
          time("Shutdown") { shutdown }
        end
      end
    end
  end
end
