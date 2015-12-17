#
# Generate small recipeset from recipeset file "<recipe>.set"
#
require 'pp'

class SplitRecipe
  def initialize f
    @text = File.read(f)
    parse_rules f
    generate_auto_recipes f
  end

  def parse_rules f
    tmp = @text.split("\n")

    rules = tmp.select {|line| line =~ /^#!/}
    rules_hash = {}
    rules.each do |rule|
      rule =~ /^#!\s*(\S+):\s*(.*)\s*$/
      rules_hash[$1] = $2.split(/\s+/)
    end
    ary = rules_hash.map {|k,v| [k].product v}
    @rules = ary.shift.product(*ary).map {|a| Hash[a]}
  end

  def generate_auto_recipes f
    @rules.each do |rule|
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
