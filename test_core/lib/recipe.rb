require 'pp'
require 'erb'
require 'optparse'
require 'fileutils'

class RecipeTemplate
  def initialize f
    dirname = File.dirname(f)
    basename = File.basename(f, ".set3")
    text = File.read(f, :encoding => 'UTF-8')

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

    if params.empty?
      params << {}
    end

    backward_keyword = []
    backward_keyword = ENV['BACKWARD_KEYWORD'].split(',') if ENV['BACKWARD_KEYWORD']
    forward_keyword = []
    forward_keyword = ENV['FORWARD_KEYWORD'].split(',') if ENV['FORWARD_KEYWORD']

    params.each do |param|
      if param.empty?
        outbase = basename + '.auto3'
      else
        outbase = basename + '/' + get_id(param) + '.auto3'
        FileUtils.mkdir_p(dirname + "/" + basename)
      end
      File.write(dirname + "/" + outbase, template.result(binding))
    end
  end

  def get_id values
    values.each.map do |k, v|
      "#{k}-#{v}"
    end.join('_')
  end
end

class SplitRecipe
  def initialize f
    @text = File.read(f, :encoding => 'UTF-8')
    parse_rule_sets f
    remove_rule_macro

    if @rule_sets.empty?
      outfile = f.gsub(".set", ".auto")
      FileUtils.cp f, outfile
    else
      @rule_sets.each do |key, rs|
        ary = rs.map {|k, v| [k].product v}
        rules = ary.shift.product(*ary).map {|a| Hash[a]}
        if f =~ /\.set2/ # version 2
          generate_auto_recipes2 f, rules
        else
          generate_auto_recipes f, rules
        end
      end
    end
  end

  def parse_rule_sets f
    tmp = @text.split("\n")

    rule_sets = {}
    rules = tmp.select {|line| line =~ /^#!/}
    rules.each do |r|
      if r =~ /^#!(\S*)\s+(\S+):\s*(.*)\s*$/
        key = $1 == "" ? "default" : $1
        rule_sets[key] = {} if rule_sets[key].nil?
        rule_sets[key][$2] = $3.split(/\s+/)
      end
    end
    @rule_sets = rule_sets

    @rule_mark = []
    rule_sets.values.each do |rule_set|
      rule_set.each do |key, rule|
        rule.each do |r|
          @rule_mark << "__MARK_#{key}_#{r.gsub('-', '_')}"
        end
      end
    end
  end

  def remove_rule_macro
    @text = @text.split("\n").delete_if {|line| line =~ /^#!/}.join("\n")
  end

  def generate_auto_recipes f, rules
    rules.each do |rule|
      id = rule.values.join("_")
      outfile = f.gsub(".set", "_#{id}.auto")
      tmp = @text.dup
      rule.each do |k, v|
        tmp.gsub!("__MARK_#{k}", v)
      end
      File.write outfile, tmp
    end
  end

  def generate_auto_recipes2 f, rules
    marks = @rule_mark.map.with_index {|m, i| "#define #{m} #{i}"}.join("\n")
    tmp = marks + @text.dup

    require "tempfile"
    # Can't use Tempfile due to incompatiblility b/w 2.0 and 2.1>
    tmpfpath = "/tmp/.split_recipe.rb"
    # Tempfile.create("split_recipe") do |tmpfpath|
      File.write(tmpfpath, tmp)
      rules.each do |rule|
        id = rule.values.join("_")
        outfile = f.gsub(".set", "_#{id}.auto")
        cmd = "cpp -E"
        rule.each do |k, v|
          cmd += " -D__STR_#{k}=#{v} -D__MARK_#{k}=__MARK_#{k}_#{v.gsub('-', '_')}"
        end
        cmd += " #{tmpfpath} > #{outfile} 2> /dev/null"
        system cmd
      end
    # end
  end
end

class RecipeSet
  def initialize args
    @options = {
      :action => :split,
      :all => false,        # show ".tmp"
      :recipelist => nil,
      :type => nil,
      :priority => nil,
    }

    if args[0] == "list"
      @options[:action] = :list
      args.shift
      OptionParser.new do |opts|
        opts.banner = "Usage: recipe.rb list [--all]"
        opts.on("-a", "--all") do
          @options[:all] = true
        end
        opts.on("-r recipelist", "--recipelist") do |f|
          @options[:recipelist] = File.read(f).split("\n")
        end
        opts.on("-t types", "--type") do |types|
          @options[:type] = types.split(",")
        end
        opts.on("-p priority", "--priority") do |priority|
          @options[:priority] = priority.split(",").map do |pr|
            if pr =~ /(\d+)-(\d+)/
              ($1.to_i..$2.to_i).to_a
            else
              pr.to_i
            end
          end.flatten
        end
      end.parse! args
    end
  end

  def split
    Dir.glob("#{Dir::pwd}/cases/**/*.set2") do |f|
      SplitRecipe.new f
    end

    Dir.glob("#{Dir::pwd}/cases/**/*.set3") do |f|
      RecipeTemplate.new f
    end
  end

  def generate_list
    @list = []
    Dir.glob("#{Dir::pwd}/cases/**/*").select do |f|
      File.file?(f)
    end.each do |f|
      next if f =~ /(set2|set3)$/
      f.gsub!("#{Dir::pwd}/", '')
      id = f.gsub("cases/", '')
      priority = 10
      type = ["normal"]
      text = File.read(f, :encoding => 'UTF-8').split("\n")
      text.each do |line|
        if line =~ /TEST_PRIORITY=(\d+)/
          priority = $1.to_i
        end
        if line =~ /TEST_TYPE=([\w,]+)/
          type = $1.split(",")
        end
      end
      next if @options[:type] and not (type - @options[:type]).empty?
      next if @options[:priority] and not @options[:priority].include?(priority)
      next if @options[:recipelist] and not @options[:recipelist].include?(id)
      @list << {:id => id, :priority => priority, :type => type}
    end
    @list.sort! {|a, b| [a[:priority], a[:id]] <=> [b[:priority], b[:id]]}
    return @list
  end

  def show_list
    return if @options[:action] != :list
    # pp @options
    generate_list
    return if @list.empty?
    type_width = @list.map {|a| a[:type].size}.max + 1
    @list.each do |a|
      next if a[:id] =~ /\/config$/
      if ARGV[1] == "all"
      else
        next if a[:id] =~ /\/.*\.tmp$/
      end
      printf("%-#{type_width}s\t%d\t%s\n", a[:type].join(","), a[:priority], a[:id])
    end
  end
end

if $0 == __FILE__
  rs = RecipeSet.new ARGV
  rs.split
  rs.show_list
end
