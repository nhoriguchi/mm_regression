#
# Generate small recipeset from recipeset file "<recipe>.set"
#
require 'pp'
require 'fileutils'

class SplitRecipe
  def initialize f
    @text = File.read(f)
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
          @rule_mark << "__MARK_#{key}_#{r}"
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
    Tempfile.create("split_recipe") do |tmpf|
      File.write(tmpf.path, tmp)
      rules.each do |rule|
        id = rule.values.join("_")
        outfile = f.gsub(".set", "_#{id}.auto")
        cmd = "cpp -E"
        rule.each do |k, v|
          cmd += " -D__STR_#{k}=#{v} -D__MARK_#{k}=__MARK_#{k}_#{v}"
        end
        cmd += " #{tmpf.path} > #{outfile} 2> /dev/null"
        system cmd
      end
    end
  end
end

if $0 == __FILE__
  Dir.glob("#{Dir::pwd}/cases/**/*.set") do |f|
    SplitRecipe.new f
  end

  Dir.glob("#{Dir::pwd}/cases/**/*.set2") do |f|
    SplitRecipe.new f
  end
end
