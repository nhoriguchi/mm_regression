#!/usr/bin/ruby

# Should be run by root

abort "Usage: #{$0} <pfn>" if ARGV.size != 1
pfn = ARGV[0].hex # assuming gpa is given in hex number

io = open "/proc/kpagecount"
io.seek(pfn * 8, IO::SEEK_SET)
a = io.read 8
begin
  b = a.unpack("Q")[0] & 0xfffffffffff
  puts "%d" % b
rescue
  puts "-1"
end
