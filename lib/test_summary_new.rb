require 'pp'
require 'optparse'
require 'tmpdir'

class TestCaseSummary
  attr_accessor :testcaseid, :testcount, :success, :failure, :warning, :later

  def initialize run_dir, tc_dir
    @runname = run_dir
    @tc_dir = run_dir + '/' + tc_dir
    @testcaseid = "#{tc_dir.gsub(run_dir + '/', '')}"
    data_check
    @testcount = File.read(@tc_dir + "/_testcount").to_i
    @success = File.read(@tc_dir + "/_success").to_i
    @failure = File.read(@tc_dir + "/_failure").to_i
    @warning = File.read(@tc_dir + "/_warning").to_i
    @later = File.read(@tc_dir + "/_later").to_i
    @return_code_seq = File.read(@tc_dir + "/_return_code_seq")
  end

  # If a testcase failed badly, some result data might not be stored,
  # so let's skip such cases.
  def data_check
    tmp = ["_testcount", "_success", "_failure", "_warning", "_later"].any? do |f|
      ! File.exist?(@tc_dir + "/" + f)
    end

    if tmp == true
      puts "testcase #{@testcaseid} doesn't have valid testcount data. Skipped."
      raise
    end
  end

  def sum_str
    "#{@testcount}/#{@success}/#{@failure}/#{@warning}/#{@later} #{@testcaseid}"
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
end

class RunSummary
  attr_accessor :dir, :tc_summary, :testcases, :testcount, :success, :failure, :later, :tc_hash

  def initialize test_summary, dir
    @test_summary = test_summary
    @dir = dir
    @testcases = Dir.glob("#{dir}/**/*").select do |g|
      File.directory? g and File.exist? "#{g}/result"
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
        puts "sorry no real rescue yet."
      end
    end
    calc_scores
    calc_result_group
  end

  def sum_str
    tmp = []
    # if @test_summary.options[:verbose]
    #   @tc_summary.each do |tc|
    #     tmp << "  " + tc.sum_str
    #   end
    # end
    tmp << "PASS #{@testcase_pass.count}, FAIL #{@testcase_fail.count}, NONE #{@testcase_none.count}, SKIP #{@testcase_skip.count}, WARN #{@testcase_warn.count}"
    tmp << "checkcount #{@testcount}, checkpass #{@success}, checkfail #{@failure}, checkwarn #{@warning}, checklater #{@later}"
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
    @warning = @tc_summary.inject(0) {|sum, t| sum + t.warning}
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
    else
      puts sum_str
    end
  end

  def do_finishcheck
    if ENV['RECIPEFILES'].nil?
      puts "No environment variable RECIPEFILES set, so can't tell test ending."
      exit
    end

    given_recipes = `echo $RECIPEFILES | bash test_core/lib/filter_recipe.sh`.chomp.split("\n").map {|r| r.gsub(/.*cases\//, '')}

    if @run_summary.all? {|rs| rs.check_finished given_recipes}
      puts "All of given recipes are finished."
      exit 0
    else
      puts "There's some \"not run\" testcases. So try to run test again with the same setting."
      exit 1
    end
  end

  def show_coverage
    @run_summary.each do |run|
      covered = 0
      uncovered = 0
      full_recipe_list = File.read("#{run.dir}/full_recipe_list").split("\n").map do |c|
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
