require 'pp'
require 'erb'
require 'optparse'

class RecipeTemplate
  def initialize f
    dirname = File.dirname(f)
    basename = File.basename(f, ".set3")
    text = File.read(f)
    
    params = []
    tmp = []
    text.split("\n").each do |line|
      if line =~ /^#! (.*)$/
        params << eval($1)
      else
        tmp << line
      end
    end

    template = ERB.new(tmp.join("\n"))
    
    params.each do |param|  
      outbase = basename + '_' + get_id(param) + '.auto3'
      File.write(dirname + "/" + outbase, template.result(binding))
    end
  end

  def get_id values
    values.each.map do |k, v|
      "#{k}-#{v}"
    end.join('_')
  end
end

class RecipeTemplateDir
  def initialize args
    @options = {}

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [-h|--help]"
    end.parse! args

    Dir.glob("#{Dir::pwd}/cases/**/*.set3") do |f|
      RecipeTemplate.new f
    end
  end
end

if $0 == __FILE__
  RecipeTemplateDir.new ARGV
end
