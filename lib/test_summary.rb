require 'pp'
require 'optparse'

class TestCaseSummary
  attr_accessor :testcaseid, :testcount, :success, :failure, :later

  def initialize run_dir, tc_dir
    @runname = run_dir
    @tc_dir = run_dir + '/' + tc_dir
    @testcaseid = "#{tc_dir.gsub(run_dir + '/', '')}"
    data_check
    @testcount = File.read(@tc_dir + "/_testcount").to_i
    @success = File.read(@tc_dir + "/_success").to_i
    @failure = File.read(@tc_dir + "/_failure").to_i
    @later = File.read(@tc_dir + "/_later").to_i
  end

  # If a testcase failed badly, some result data might not be stored,
  # so let's skip such cases.
  def data_check
    tmp =["_testcount", "_success", "_failure", "_later"].any? do |f|
      ! File.exist?(@tc_dir + "/" + f)
    end

    if tmp == true
      puts "testcase #{@testcaseid} doesn't have valid testcount data. Skipped."
      raise
    end
  end

  def sum_str
    "#{@testcount}/#{@success}/#{@failure}/#{@later} #{@testcaseid}"
  end

  def failure_str
    tmp = File.read(@tc_dir + "/result").split("\n").select do |line|
      line =~ /FAIL:/
    end
    tmp.map! do |line|
      "#{@testcaseid}: #{line}"
    end
    tmp.join("\n")
  end

  def status
    return "NONE" if @testcount == 0
    return "PASS" if @testcount == @success + @later
    return "FAIL"
  end
end

class RunSummary
  attr_accessor :dir, :tc_summary, :testcases, :testcount, :success, :failure, :later

  def initialize test_summary, dir
    @test_summary = test_summary
    @dir = dir
    @testcases = Dir.glob("#{dir}/**/*").select do |g|
      File.directory? g and File.exist? "#{g}/result"
    end.map do |tc|
      "#{tc.gsub(dir + '/', '')}"
    end.sort
    @tc_summary = []
    @testcases.each do |tc|
      begin
        @tc_summary << TestCaseSummary.new(dir, tc)
      rescue
        puts "sorry no real rescue yet."
      end
    end
    calc_scores
  end

  def sum_str
    tmp = []
    if @test_summary.options[:totalonly].nil?
      @tc_summary.each do |tc|
        tmp << "  " + tc.sum_str
      end
    end
    tmp << "#{@testcount}/#{@success}/#{@failure}/#{@later} #{@dir}"
    if @test_summary.options[:verbose]
      tmp << failure_str
    end
    tmp.join("\n")
  end

  def failure_str
    tmp = []
    @tc_summary.each do |tc|
      if tc.failure > 0 or tc.later > 0
        tmp << tc.failure_str
      end
    end
    tmp.join("\n")
  end

  def calc_scores
    @testcount = @tc_summary.inject(0) {|sum, t| sum + t.testcount}
    @success = @tc_summary.inject(0) {|sum, t| sum + t.success}
    @failure = @tc_summary.inject(0) {|sum, t| sum + t.failure}
    @later = @tc_summary.inject(0) {|sum, t| sum + t.later}
  end
end

class TestSummary
  attr_accessor :options

  def initialize args
    parse_args args
    get_targets
    get_full_recipes
    @run_summary = @targets.map {|t| RunSummary.new self, t}
    if @options[:coverage]
      show_coverage
    else
      puts sum_str
    end
  end

  def show_coverage
    @run_summary.each do |run|
      covered = 0
      uncovered = 0
      @full_recipe_list.each do |recipe|
        a = run.tc_summary.find {|tc| tc.testcaseid == recipe}
        if a.nil?
          puts "---- #{recipe}"
          uncovered += 1
        else
          puts "#{a.status} #{recipe}"
          covered += 1
        end
      end
      puts "Coverage: #{covered} / #{covered + uncovered} (#{100*covered/(covered+uncovered)}%)"
    end
  end

  def get_full_recipes
    @full_recipe_list = Dir.glob("#{@options[:recipedir]}/**/*").select do |g|
      File.file? g and g !~ /\.set$/
    end.map do |f|
      f.gsub(/^#{@options[:recipedir]}\//, '')
    end.sort
  end

  def sum_str
    tmp = []
    @run_summary.each do |run|
      tmp << run.dir
      tmp << run.sum_str
    end
    tmp.join("\n")
  end

  def get_targets
    @targets = []
    if @options[:latest]
      tmp = Dir.glob("#{@options[:workdir]}/*").select do |g|
        File.directory? g
      end
      tmp.sort_by! {|f| File.mtime(f)}
      0.upto(@options[:latest] - 1) do |i|
        puts "latest result dir is #{tmp[-1-i]}"
        @targets << tmp[-1-i]
      end
    else
      @targets << "#{@options[:workdir]}/#{@runname}"
    end
  end

  def parse_args args
    @options = {
      # :workdir => File.expand_path(File.dirname(__FILE__) + "/../../work"),
      # :recipedir => File.expand_path(File.dirname(__FILE__) + "/../../cases"),
      :workdir => "#{Dir::pwd}/work",
      :recipedir => "#{Dir::pwd}/cases",
    }
    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [-options] seriesfile"
      opts.on("-o dir", "--outdir") do |d|
        @options[:outdir] = d
      end
      opts.on("-w workdir", "--workdir") do |d|
        @options[:workdir] = d
      end
      opts.on("-l [n]", "--latest") do |n|
        @options[:latest] = n.to_i
        @options[:latest] = 1 if @options[:latest] == 0
      end
      opts.on("-f filter", "--filter") do |f|
        @options[:filter] = f
      end
      opts.on("-v", "--verbose") do
        @options[:verbose] = true
      end
      opts.on("--only-total") do
        @options[:totalonly] = true
      end
      opts.on("-c", "--coverage") do
        @options[:coverage] = true
      end
    end.parse! args

    @runname = args[0]
    if @runname and File.directory? @runname  # work/<runname> form
      @runname = File.basename @runname
    else # just <runname> given, do nothing
    end

    check_args
  end

  def check_args
    if @options[:latest] and @runname
      puts "both of runname and -l option are given (not intended)"
      exit
    end
  end

  def self.usage
  end
end

if $0 == __FILE__
  if ARGV.empty?
    TestSummary.usage
  else
    TestSummary.new ARGV
  end
  # Dir.glob("#{Dir::pwd}/cases/**/*.set") do |f|
end
