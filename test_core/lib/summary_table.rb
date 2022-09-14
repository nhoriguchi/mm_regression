# input: the list of test result table like below:
#
# SKIP 20220914/174739 [10] (devel) mm/acpi_hotplug/base/type-acpi.auto3
# SKIP 20220914/174740 [10] (devel) mm/acpi_hotplug/base/type-acpi_hugetlb-free.auto3
# SKIP 20220914/174742 [10] (devel) mm/acpi_hotplug/base/type-acpi_hugetlb-hwpoisoned.auto3
# SKIP 20220914/174743 [10] (devel) mm/acpi_hotplug/base/type-acpi_in-use-1.auto3
# PASS 20220914/174803 [10] (devel) mm/acpi_hotplug/base/type-sysfs_hugetlb-hwpoisoned.auto3
# PASS 20220914/174749 [10] (devel) mm/acpi_hotplug/base/type-sysfs.auto3
# PASS 20220914/174755 [10] (devel) mm/acpi_hotplug/base/type-sysfs_hugetlb-free.auto3
# PASS 20220914/174808 [10] (devel) mm/acpi_hotplug/base/type-sysfs_in-use-2.auto3
#
# This should be the output from './run.sh proj sum -P <RUNNAME>' command.
#
# Usage:
#   ruby summary_table.rb <file>

dat = File.read(ARGV[0]).split("\n")

tmp_result_hash = {}
tmp_testtype_hash = {}
tmp_hash = {}
tmp_hash2 = {}
dat.each do |line|
  if line =~ /(\w*) \S+ \S+ \((\w+)\) (\S+)/
    tmp_result_hash[$1] = true
    tmp_testtype_hash[$2] = true
    tmp_hash[$3] = [$1, $2]
    if tmp_hash2[[$1, $2]]
      tmp_hash2[[$1, $2]] += 1
    else
      tmp_hash2[[$1, $2]] = 1
    end
  end
end


out = []
longest = tmp_testtype_hash.keys.map {|tt| tt.size}.max
label = ([" " * longest] + tmp_result_hash.keys).join(" ")
out << label
tmp_testtype_hash.keys.each do |tt|
  line = ["%#{longest}s" % tt]
  tmp_result_hash.keys.each do |res|
    if tmp_hash2[[res, tt]]
      line << "%4d" % tmp_hash2[[res, tt]]
    else
      line << "%4d" % 0
    end
  end
  out << line.join(' ')
end
puts out.join("\n")
