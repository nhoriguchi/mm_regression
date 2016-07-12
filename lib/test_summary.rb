require 'pp'
require 'optparse'
require 'tmpdir'

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
    @return_code_seq = File.read(@tc_dir + "/_return_code_seq")
  end

  # If a testcase failed badly, some result data might not be stored,
  # so let's skip such cases.
  def data_check
    tmp = ["_testcount", "_success", "_failure", "_later"].any? do |f|
      ! File.exist?(@tc_dir + "/" + f)
    end

    if tmp == true
      # STDERR.puts "testcase <#{@testcaseid}> doesn't have valid testcount data. Skipped."
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
    tmp.uniq! # in retried case, same error can appear
    tmp.join("\n")
  end

  def testcase_result
    tmp = nil
    return "NONE" if ! File.exist? @tc_dir + "/result"
    File.read(@tc_dir + "/result").split("\n").each do |line|
      if line =~ /^TESTCASE_RESULT: (.+)?: (\w+)$/
        tmp = $2
        break
      end
    end
    return tmp.nil? ? "WARN" : tmp
  end

  def started?
    @return_code_seq =~ /\bSTART\b/
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
  attr_accessor :dir, :tc_summary, :testcases, :testcount, :success, :failure, :later, :tc_hash, :recipelist

  def initialize test_summary, dir
    @test_summary = test_summary
    @recipelist = File.read("#{dir}/full_recipe_list").chomp.split("\n")
    @dir = dir
    @testcases = Dir.glob("#{dir}/**/*").select do |g|
      File.directory? g # and File.exist? "#{g}/result"
    end.map do |tc|
      "#{tc.gsub(dir + '/', '')}"
    end.sort

    @tc_summary = []
    @tc_hash = {}
    @testcases.each do |tc|
      begin
        tcs = TestCaseSummary.new(dir, tc)
        @tc_summary << tcs
        @tc_hash[tc] = tcs
      rescue
        # STDERR.puts "sorry no real rescue yet."
      end
    end
    calc_scores
    calc_result_group
  end

  def sum_str
    tmp = []
    tmp << "PASS #{@testcase_pass.count}, FAIL #{@testcase_fail.count}, NONE #{@testcase_none.count}, SKIP #{@testcase_skip.count}, WARN #{@testcase_warn.count}"
    tmp << "checkcount #{@testcount}, checkpass #{@success}, checkfail #{@failure}, checklater #{@later}"
    if @test_summary.options[:verbose]
      tmp << non_passed_summary
    end
    tmp.join("\n")
  end

  def non_passed_summary
    tmp = []
    @testcase_fail.each do |tc|
      tmp << tc.failure_str
    end
    @testcase_none.each do |tc|
      tmp << "#{tc.testcaseid}: NONE"
    end
    @testcase_warn.each do |tc|
      tmp << "#{tc.testcaseid}: WARN"
      tmp << tc.failure_str
    end
    tmp.join("\n")
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

  def check_finished recipeset
    run = []
    skipped = []
    notrun = []

    recipeset.each do |r|
      if @tc_hash[r]
        if @tc_hash[r].started?
          run << r
        else
          skipped << r
        end
      else
        notrun << r
      end
    end
    puts "#{@dir}: #{run.size} run, #{skipped.size} skipped, #{notrun.size} notrun"
    if skipped.size > 0
      puts "Testcases skipped:"
      puts skipped.map {|r| "- " + r}
    end
    if notrun.size > 0
      puts "Testcases not run:"
      puts notrun.map {|r| "- " + r}
      # If there's "notrun" testcase, the current testrun is not finished yet.
      return nil
    else
      return true
    end
  end
end

class TestSummary
  attr_accessor :options

  def initialize args
    parse_args args
    get_targets
    @run_summary = @targets.map {|t| RunSummary.new self, t}

    if @options[:finishcheck]
      do_finishcheck
    elsif @options[:coverage]
      show_coverage
    elsif @options[:timesummary]
      show_timesummary
    elsif @options[:recipes]
      show_recipe_status
    else
      puts sum_str
    end
  end

  # TODO: user can limit the set of recipes to be searched
  def do_finishcheck
    if ENV['RECIPEFILES'].nil?
      @run_summary.each do |run|
        given_recipes = run.recipelist.map do |c|
          c.gsub(/^cases\//, '')
        end
        if ! run.check_finished given_recipes
          puts "There's some \"not run\" testcases. So try to run test again with the same setting."
          exit 1
        end
      end
      puts "All of given recipes are finished."
      exit 0
    else
      given_recipes = `echo $RECIPEFILES | bash test_core/lib/filter_recipe.sh | cut -f1`.chomp.split("\n").map {|r| r.gsub(/.*cases\//, '')}
      if @run_summary.all? {|rs| rs.check_finished given_recipes}
        puts "All of given recipes are finished."
        exit 0
      else
        puts "There's some \"not run\" testcases. So try to run test again with the same setting."
        exit 1
      end
    end
  end

  def show_coverage
    @run_summary.each do |run|
      covered = 0
      uncovered = 0
      full_recipe_list = run.recipelist.map do |c|
        c.gsub(/^cases\//, '')
      end

      full_recipe_list.each do |recipe|
        a = run.tc_summary.find {|tc| tc.testcaseid == recipe}
        if a.nil?
          puts "---- #{recipe}"
          uncovered += 1
        else
          puts "#{a.testcase_result} #{recipe}"
          covered += 1
        end
      end

      if covered + uncovered == 0
        coverage = 0
      else
        coverage = 100*covered/(covered+uncovered)
      end

      puts "Coverage: #{covered} / #{covered + uncovered} (#{coverage}%)"
    end
  end

  def show_timesummary
    @run_summary.each do |run|
      covered = 0
      uncovered = 0
      full_recipe_list = run.recipelist.map do |c|
        c.gsub(/^cases\//, '')
      end

      tmp_duration = []
      tmp_accumulative_duration = []
      tmp_rname = []

      tstart = 0
      tmp = 0
      remember_endtime = 0
      full_recipe_list.each do |recipe|
        a = run.tc_summary.find {|tc| tc.testcaseid == recipe}
        if a.nil?
          if remember_endtime > 0
            tmp_duration << remember_endtime - tmp
          else
            tmp_duration << 0
          end
          tmp_accumulative_duration << 0
          tmp_rname << recipe
          remember_endtime = 0
        else
          tstart = tmp = a.start_time if tmp == 0
          # puts sprintf "%6d / %6d %s\n", a.start_time - tmp, a.start_time - tstart, recipe
          tmp_duration << a.start_time - tmp
          tmp_accumulative_duration << a.start_time - tstart
          tmp_rname << recipe
          tmp = a.start_time
          remember_endtime = a.end_time
        end
      end
      tmp_duration.shift
      if remember_endtime > 0
        tmp_duration << remember_endtime - tmp
      else
        tmp_duration << 0
      end

      tmp_rname.each_with_index do |r, i|
        printf "%6d / %6d %s\n", tmp_duration[i], tmp_accumulative_duration[i], r
      end
    end
  end

  def show_recipe_status
    @run_summary.each do |run|
      @options[:recipes].each do |recipe|
        a = run.tc_summary.find {|tc| tc.testcaseid == recipe.gsub(/^cases\//, '')}
        if a.nil?
          puts "---- #{recipe}"
        else
          puts "#{a.testcase_result} #{recipe}"
        end
      end
    end
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
    if @options[:latest]
      tmp = Dir.glob("#{@options[:workdir]}/*").select do |g|
        File.directory? g
      end
      tmp.delete_if {|d| d =~ /\/hugetlbfs/}
      raise "not target directory found" if tmp.empty?
      tmp.sort_by! {|f| File.mtime(f)}
      0.upto(@options[:latest] - 1) do |i|
        puts "latest result dir is #{tmp[-1-i]}"
        @targets << tmp[-1-i]
      end
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
      opts.on("-c", "--coverage") do
        @options[:coverage] = true
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
        dat = File.expand_path dat
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
