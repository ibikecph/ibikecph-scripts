# runs on the worker and handles actual processing og osrm data and tiles

require File.expand_path( File.join( File.dirname(__FILE__), 'server' ) )
require 'fileutils'

class Worker  
  def initialize
    @api_config = Configuration.new 'servers.yml'   # relative to working dir
    @config = Configuration.new File.join( File.dirname(__FILE__), 'worker.yml' ) # in repo folder
  end
  
  def path key
    path_from_string @config[key]
  end

  def path_from_string path
    File.expand_path( File.join( @config['base_dir'], path ) )
  end  
  
  def time str, &block
    start = Time.now
    puts "#{str}: Starting at #{start}"
    yield block
    finish = Time.now
    seconds = (Time.now - start).to_i
    formatted = format_time seconds
    puts "#{str}: Completed in #{seconds}s / #{formatted}, at #{finish}."
  end

  def run_cmd cmd
    puts "--> #{cmd}"
    raise "Failed to run command: #{cmd}" unless system cmd
  end

  def update_osm_data
    puts "Existing map file #{path 'osm_file'} was last updated #{File.mtime(path 'osm_file')}"
    run_cmd "osmupdate #{path 'osm_file'} #{path 'new_osm_file'} -B=#{path 'polygon_file'}"
    FileUtils.mv path('new_osm_file'), path('osm_file')
  end
  
  def basename_with_path path
    dir = File.dirname path
    # File.basename with '.*' argument only removes one extension, so 'fun.a.b' would result in 'fun.a'
    # we want just 'fun', so use a regex to strip all extensions
    base = File.basename(path).match(/[^\.]*/).to_s
    File.join( dir, base )
  end

  def basename_without_path path
    # File.basename with '.*' argument only removes one extension, so 'fun.a.b' would result in 'fun.a'
    # we want just 'fun', so use a regex to strip all extensions
    File.basename(path).match(/[^\.]*/).to_s
  end

  def process_osrm
    run_cmd "rm -rf #{path 'data_folder'}/#{@config['package_name']}"
    run_cmd "mkdir -p #{path 'data_folder'}/#{@config['package_name']}"
    timestamp = Time.now
    # osrm writes output to current folder, so must set it to where we want them before processing
    Dir.chdir "#{path 'data_folder'}" do
      @config['profiles'].each_pair do |profile_name,profile|
        time("Processing profile: #{profile_name}") do
          
          # using rm with -r and * can be dangerous
          # we must be careful not to wipe the disk with something like "rm -r *"
          # appending .osrm gives some safety against this
          map_base = basename_with_path path('osm_file')
          run_cmd "rm -rf #{map_base}.osrm*"      # carefull with using *
          
          map_name = basename_without_path path('osm_file')
          run_cmd "#{path 'bin_folder'}/osrm-extract #{path 'osm_file'} --profile #{path_from_string profile['lua_file']}"
          run_cmd "#{path 'bin_folder'}/osrm-prepare #{map_base}.osrm --profile #{path_from_string profile['lua_file']}"
          run_cmd "mkdir -p #{@config['package_name']}/#{profile_name}; mv #{map_base}.osrm* #{@config['package_name']}/#{profile_name}/"
          run_cmd "echo '#{timestamp}' >> #{path 'data_folder'}/#{@config['package_name']}/#{profile_name}/#{map_name}.osrm.timestamp"
        end
      end
    end
  end

  def write_config
    @config['profiles'].each_pair do |profile_name,profile|
      write_ini profile_name, profile['port']
    end
  end

  def write_ini profile, port
    map_name = basename_without_path path('osm_file')
    
    s = <<-EOF
      Threads = #{@config['osrm_threads']}
      IP = #{@config['osrm_ip']}
      Port = #{port}

      hsgrData=#{map_name}.osrm.hsgr
      nodesData=#{map_name}.osrm.nodes
      edgesData=#{map_name}.osrm.edges
      ramIndex=#{map_name}.osrm.ramIndex
      fileIndex=#{map_name}.osrm.fileIndex
      namesData=#{map_name}.osrm.names
      timestamp=#{map_name}.osrm.timestamp
    EOF
    File.open( "#{path 'data_folder'}/#{@config['package_name']}/#{profile}/server.ini", 'w') {|f| f.write( s ) }
  end


  def copy_binaries
    run_cmd "cp #{path 'bin_folder'}/osrm-* #{path 'data_folder'}/#{@config['package_name']}/"
  end

  def sync_osrm
    run_cmd "rm -rf #{@config['user']}@#{@config['server']}:/tmp/data"    # remove left-overs if any
    run_cmd "rsync -r --delete --force #{path 'data_folder'}/#{@config['package_name']} #{@config['user']}@#{@config['server']}:/tmp/"
  end

  def postgres
    run_cmd "osm2pgsql -d osm -U osm -c -C8000 --number-processes=5 --style #{path 'import_style_file'}  --tag-transform-script #{path 'import_lua_file'} #{path 'osm_file'}"
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
    run_cmd "#{path 'meta2tile_bin'} /tiles/meta/web /tiles/plain/web"
    run_cmd "#{path 'meta2tile_bin'} /tiles/meta/retina /tiles/plain/retina"
  #  run_cmd "#{path 'root'}/meta2tile /tiles/meta/background /tiles/plain/background"
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
    me = Server.new @api_config, :worker
    me.shutdown
  end
  
  def divider len=nil
    case len
    when :long
      puts '-'*60
    when :short
      puts '-'*30
    else
      puts '-'*15
    end
  end
  
  def run argv
    divider :long
    time 'Worker' do
      puts "Options: #{argv.join(' ')}"
      begin
        all = 'all'
        osrm = 'osrm'
        tiles = 'tiles'

        run_cmd 'df -h'
        run_cmd 'df -i'
        #run_cmd 'free -m'

        if (argv & [all,osrm,'update-osrm']).any?
          divider
          time("Updating OSM data") { update_osm_data }
        end

        if (argv & [all,osrm,'process-osrm']).any?
          divider
          time("Preprocess OSRM data") { process_osrm }
          divider
          time("Writing OSRM configuration") { write_config }
          divider
          time("Copy binaries") { copy_binaries }
        end

        if (argv & [all,osrm,'sync-osrm']).any?
          divider
          time("Sync data to route server") { sync_osrm }
        end

        if (argv & [all,osrm,'deploy-osrm']).any?
          divider
          time("Swap folders and restart OSRM") { deploy_osrm }
        end

        if (argv & [all,tiles,'update-db']).any?
          divider
          time("Import to Postgres") { postgres }
        end

        if (argv & [all,tiles,'clean-tiles']).any?
          divider
          time("Remove old meta-tiles") { remove_metatiles }
          divider
          time("Remove old tiles") { remove_tiles }
        end

        if (argv & [all,tiles,'render-tiles']).any?
          divider
          time("Render meta-tiles") { render_tiles }
        end

        if (argv & [all,tiles,'convert-tiles']).any?
          divider
          time("Convert meta-tiles") { convert_tiles }
        end

        if (argv & [all,tiles,'sync-tiles']).any?
          divider
          time("Sync tiles to tiles server") { sync_tiles }
        end

        if (argv & [all,'test']).any?
          divider
          time("Test") {}
        end
        
      rescue Exception => e
        puts "*** An error occurred:"
        puts e
        puts e.backtrace
      ensure
        if all || argv.include?('shutdown')
          divider
          time("Shutdown") { shutdown }
        end
      end
    end
  end
end
