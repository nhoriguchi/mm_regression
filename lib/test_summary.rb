require 'pp'
require 'optparse'
require 'tmpdir'

class TestCaseSummary
  attr_accessor :testcaseid, :testcount, :success, :failure, :later, :date, :priority

  def initialize run_dir, tc_dir
    @runname = run_dir
    @tc_dir = run_dir + '/' + tc_dir
    @testcaseid = "#{tc_dir.gsub(run_dir + '/', '')}"
    @priority = 10 # default
    @run_status = "NONE"
    @testcount = 0
    @success = 0
    @failure = 0
    @later = 0
    File.read('cases/' + tc_dir).split("\n").select do |line|
      @priority = $1.to_i if line =~ /TEST_PRIORITY=(\d+)/
    end
    return if ! Dir.exist?(@tc_dir)
    @date = File.mtime(@tc_dir)
    if File.exist?(@tc_dir + "/run_status")
      @run_status = File.read(@tc_dir + "/run_status").strip
    end
    if data_check != true
      @testcount = @success = @failure = @later = 0
      @return_code_seq = ""
      return
    end
    @testcount = File.read(@tc_dir + "/_testcount").to_i
    @success = File.read(@tc_dir + "/_success").to_i
    @failure = File.read(@tc_dir + "/_failure").to_i
    @later = File.read(@tc_dir + "/_later").to_i
    @return_code_seq = File.read(@tc_dir + "/_return_code_seq")
  end

  # If a testcase failed badly, some result data might not be stored,
  # so let's skip such cases.
  def data_check
    tmp = ["_testcount", "_success", "_failure", "_later"].all? do |f|
      File.exist?(@tc_dir + "/" + f)
    end
    if tmp != true
      # STDERR.puts "testcase <#{@testcaseid}> doesn't have valid testcount data. Skipped."
    end
    return tmp
  end

  def testcase_result
    tmp = nil
    return "NONE" if @run_status == "NONE"
    return "SKIP" if @run_status == "SKIPPED"

    if File.exist?(@tc_dir + "/result")
      File.read(@tc_dir + "/result", :encoding => 'UTF-8').split("\n").each do |line|
        if line =~ /^TESTCASE_RESULT: (.+)?: (\w+)$/
          tmp = $2
          break
        end
      end
    end
    return tmp.nil? ? "WARN" : tmp
  end

  def started?
    @run_status == "FINISHED" || @run_status == "RUNNING"
  end

  def start_time
    return nil if ! File.exist? @tc_dir + "/start_time"
    return File.read(@tc_dir + "/start_time").to_i
  end

  def end_time
    return nil if ! File.exist? @tc_dir + "/end_time"
    return File.read(@tc_dir + "/end_time").to_i
  end
end

class RunSummary
  attr_accessor :dir, :tc_summary, :testcount, :success, :failure, :later, :tc_hash, :recipelist

  def initialize test_summary, dir
    @test_summary = test_summary
    # Items in this list has 'cases/' prefix
    @recipelist = File.readlines("#{dir}/recipelist").map do |r|
      r.chomp.gsub(/^cases\//, '')
    end
    @recipelist.delete_if {|rc| File.basename(rc) == "config"}

    @dir = dir

    @tc_summary = []
    @tc_hash = {}
    @recipelist.each do |tc|
      tcs = TestCaseSummary.new(dir, tc)
      @tc_summary << tcs
      @tc_hash[tc] = tcs
    end
  end

  def do_calc
    calc_scores
    calc_result_group
  end

  def calc_scores
    @testcount = @tc_summary.inject(0) {|sum, t| sum + t.testcount}
    @success = @tc_summary.inject(0) {|sum, t| sum + t.success}
    @failure = @tc_summary.inject(0) {|sum, t| sum + t.failure}
    @later = @tc_summary.inject(0) {|sum, t| sum + t.later}
  end

  def calc_result_group
    @testcase_pass = @tc_summary.select {|t| t.testcase_result == "PASS"}
    @testcase_fail = @tc_summary.select {|t| t.testcase_result == "FAIL"}
    @testcase_none = @tc_summary.select {|t| t.testcase_result == "NONE"}
    @testcase_skip = @tc_summary.select {|t| t.testcase_result == "SKIP"}
    @testcase_warn = @tc_summary.select {|t| t.testcase_result == "WARN"}
  end
end

class TestSummary
  attr_accessor :options

  def initialize args
    parse_args args
  end

  def parse_targets
    @full_recipe_list = []
    @test_summary_hash = {}
    @targets.each do |t|
      rs = RunSummary.new self, t
      rs.do_calc
      @full_recipe_list += rs.recipelist
      @test_summary_hash.merge! rs.tc_hash
    end
    @full_recipe_list.uniq!
  end

  def do_work
    if @options[:finishcheck]
      do_finishcheck
    elsif @options[:progress]
      show_progress
    elsif @options[:progressverbose]
      show_progress_verbose
    elsif @options[:timesummary]
      show_timesummary
    elsif @options[:recipes]
      show_recipe_status
    else
      show_default_sum
    end
  end

  def check_finished recipe_list=@full_recipe_list
    run = 0
    skipped = 0
    notrun = 0
    recipe_list.each do |recipe|
      if ! @test_summary_hash.key? recipe
        notrun += 1
      elsif @test_summary_hash[recipe].testcase_result == "NONE"
        notrun += 1
      elsif @test_summary_hash[recipe].testcase_result == "SKIP"
        skipped += 1
      else
        run += 1
      end
    end

    puts "#{run} run, #{skipped} skipped, #{notrun} notrun"
    return notrun > 0 ? nil : true
  end

  # TODO: user can limit the set of recipes to be searched
  def do_finishcheck
    if ENV['RECIPEFILES'].nil?
      recipe_list = @full_recipe_list
    else
      recipe_list = `echo $RECIPEFILES | bash test_core/lib/filter_recipe.sh | cut -f1`.chomp.split("\n").map {|r| r.gsub(/.*cases\//, '')}
    end
    if check_finished recipe_list
      puts "All of given recipes are finished."
      exit 0
    else
      puts "There're some \"not run\" testcases."
      exit 1
    end
  end

  def calc_progress_percentile
    done = 0
    undone = 0
    @full_recipe_list.select do |recipe|
      case @test_summary_hash[recipe].testcase_result
      when "PASS", "FAIL", "SKIP", "WARN"
        done += 1
      when "RUNN", "NONE"
        undone += 1
      end
    end
    if done + undone == 0
      progress = 0
    else
      progress = 100*done/(done+undone)
    end
    puts "Progress: #{done} / #{done + undone} (#{progress}%)"
  end

  def show_progress
    @full_recipe_list.each do |recipe|
      puts "#{@test_summary_hash[recipe].testcase_result} #{recipe}"
    end
    calc_progress_percentile
  end

  def show_progress_verbose
    @full_recipe_list.each do |recipe|
      if @test_summary_hash[recipe].started?
        puts "#{@test_summary_hash[recipe].testcase_result} #{@test_summary_hash[recipe].date.strftime("%Y%m%d/%H%M%S")} [%02d] cases/#{recipe}" % [@test_summary_hash[recipe].priority]
      else
        puts "#{@test_summary_hash[recipe].testcase_result} --------/------ [%02d] cases/#{recipe}" % [@test_summary_hash[recipe].priority]
      end
    end
    calc_progress_percentile
    puts "Target: #{@targets.join(", ")}"
  end

  def show_timesummary
    @full_recipe_list.each do |recipe|
      if r = @test_summary_hash[recipe]
        if r.start_time and r.end_time
          printf "%6d %s\n", r.end_time - r.start_time, recipe
        else
          printf "%6d %s\n", 99999, recipe
        end
      end
    end
  end

  def show_recipe_status
    @options[:recipes].each do |recipe|
      recipe.gsub!(/^cases\//, '')
      puts "#{@test_summary_hash[recipe].testcase_result} #{recipe}"
    end
  end

  def show_default_sum
    sum = {
      "PASS" => 0,
      "FAIL" => 0,
      "NONE" => 0,
      "SKIP" => 0,
      "WARN" => 0,
    }
    @test_summary_hash.each do |id, tc|
      sum[tc.testcase_result] += 1
    end
    calc_progress_percentile
    puts "PASS #{sum["PASS"]}, FAIL #{sum["FAIL"]}, WARN #{sum["WARN"]}, SKIP #{sum["SKIP"]}, NONE #{sum["NONE"]}"
  end

  def parse_args args
    @options = {
      # :workdir => File.expand_path(File.dirname(__FILE__) + "/../../work"),
      # :recipedir => File.expand_path(File.dirname(__FILE__) + "/../../cases"),
      # :workdir => "#{Dir::pwd}/work",
      :latest => nil,
      :workdir => "work",
      :recipedir => "#{Dir::pwd}/cases",
    }
    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [-options] work/<runname>"
      opts.on("-o dir", "--outdir") do |d|
        @options[:outdir] = d
      end
      opts.on("-w workdir", "--workdir") do |d|
        @options[:workdir] = d
      end
      opts.on("-l", "--latest") do
        @options[:latest] = true
      end
      opts.on("-f filter", "--filter") do |f|
        @options[:filter] = f
      end
      opts.on("-v", "--verbose") do
        @options[:verbose] = true
      end
      opts.on("-p", "--progress") do
        @options[:progress] = true
      end
      opts.on("-P", "--progress-verbose") do
        @options[:progressverbose] = true
      end
      opts.on("-C", "--progress-verbose") do # left for compatibility
        @options[:progressverbose] = true
      end
      opts.on("-F", "--finishcheck") do
        @options[:finishcheck] = true
      end
      opts.on("-t", "--time-summary") do
        @options[:timesummary] = true
      end
      opts.on("-r recipe", "--recipe-status") do |r|
        @options[:recipes] = [] if @options[:recipes].nil?
        @options[:recipes] += r.split(",")
      end
    end.parse! args

    @targets = args.map do |dat|
      if File.directory? dat # maybe work/<runname> form
        dat = "work/" + dat.split("/")[-1]
      elsif File.exist? dat # maybe tar file
        tmpdir = Dir.mktmpdir
        system "tar -x --force-local -zf #{dat} -C #{tmpdir}"
        dat = tmpdir + "/work_log_testrun" # TODO: better getter?
      end
      dat
    end
    check_args
  end

  def check_args
    if @options[:latest].nil? and @targets.empty?
      puts "both of runname and -l option are given (not intended)"
      exit
    end

    if @options[:latest]
      tmp = Dir.glob(@options[:workdir] + "/*/full_recipe_list").sort do |a, b|
        File.mtime(a) <=> File.mtime(b)
      end
      # TODO: assuming @options[:workdir] is 'work'
      @targets = [tmp[-1].split('/')[-3..-2].join('/')]
    end
  end

  def self.usage
  end
end

if $0 == __FILE__
  if ARGV.empty?
    TestSummary.usage
  else
    ts = TestSummary.new ARGV
    ts.parse_targets
    ts.do_work
  end
end
