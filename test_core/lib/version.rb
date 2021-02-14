require 'pp'

class VersionCheck
  def initialize argv

    @vers = argv.map do |v|
      v.split(/[\.-]/).map do |s|
        if s =~ /^\d+$/
          s.to_i
        else
          s
        end
      end
    end
  end

  def compare
    len0 = @vers[0].size
    len1 = @vers[1].size
    len = len1 > len0 ? len0 : len1
    len.times do |i|
      if @vers[0][i] != @vers[1][i]
        return @vers[0][i] > @vers[1][i] ? 0 : 2
      end
    end
    return 1 if len0 == len1
    return len0 > len1 ? 0 : 2
  end

  def self.usage
    puts "Usage: version.rb <version1> <version2>

  Compare two given versions and return:
  - 0 if version1 is newer,
  - 1 if two versions are identical, and
  - 2 if version2 is newer.
"
  end
end

if $0 == __FILE__
  if ARGV.empty?
    VersionCheck.usage
  else
    ts = VersionCheck.new ARGV
    puts ts.compare
  end
end
