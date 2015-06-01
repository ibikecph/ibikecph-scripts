# Read configs from an yaml file, including API settings and list of servers

require 'yaml'

class Configuration 
  def initialize path
    raise "Config file '#{path} not found." unless File.exists? path
    @config = YAML.load_file(path)
  end 
  
  def [] key
    @config[key]
  end
end
