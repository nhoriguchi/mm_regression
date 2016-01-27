#
# Generate small recipeset from recipeset file "<recipe>.set"
#
require 'pp'
require 'fileutils'

class SplitRecipe
  def initialize f
    @text = File.read(f)
    parse_rule_sets f

    if @rule_sets.empty?
      outfile = f.gsub(".set", ".auto")
      FileUtils.cp f, outfile
    else
      @rule_sets.each do |key, rs|
        ary = rs.map {|k, v| [k].product v}
        rules = ary.shift.product(*ary).map {|a| Hash[a]}
        generate_auto_recipes f, rules
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
end

if $0 == __FILE__
  Dir.glob("#{Dir::pwd}/cases/**/*.set") do |f|
    SplitRecipe.new f
  end
end
