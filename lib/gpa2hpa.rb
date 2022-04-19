#!/usr/bin/ruby

# Should be run by root

if ARGV.size == 0
  puts "Usage: #{$0} <vmname> <gpa> [-d]"
  puts "Usage: #{$0} <PID> <vfn> [-d]"
  puts ""
  puts "  gpa and vfn should be given as hex number."
  exit
end

vmname = ARGV[0]
if ARGV[0].to_i == 0 # for VM
  # assuming gpa is given in hex number
  gpa = ARGV[1].nil? ? nil : ARGV[1].hex
  debug = ARGV[2] == "-d"

  pidfile = "/var/run/libvirt/qemu/#{vmname}.pid"
  raise "VM #{vmname} not running" unless File.exist? pidfile
  pid = File::open(pidfile) {|f| f.gets}
  max = 0
  vaddr = 0
  File::open("/proc/#{pid}/maps").each do |line|
    if line =~ /(\w*)-(\w*) /
      size = ($2.hex - $1.hex)
      if size > max
        max = size
        vaddr = $1.hex
      end
    end
  end

  tmp = `virsh dommemstat #{vmname} | grep actual | awk '{print $2}'`.to_i
  STDERR.puts "size is 0x#{max} (dommem 0x#{tmp*1024})\n" if debug == true
  raise "Guest RAM is separated in Virtual space of qemu process" if max < tmp * 1024

  if gpa.nil?
    tmp = `virsh dommemstat #{vmname} | grep actual | awk '{print $2}'`.to_i
    printf "size is 0x%x (dommem 0x%x)\n", max, tmp * 1024
    raise "Guest RAM is separated in Virtual space of qemu process" if max < tmp * 1024
    printf "vaddr of guest memory is [0x%x-0x%x] ([0x%x+0x%x] in pfn) \n" % [vaddr, vaddr+max, vaddr >> 12, max >> 12]
    exit
  end

  # at least for x86_64, physical address range [0xc0000000, 0x100000000] is not allocated and
  # QEMU process does not allocate virtual address for that range, so when translating
  # GPA to HVA, we need subtract the offset (1GB) from GPA when GPA is larger than 4GB.
  if gpa > 0x100000
    target = vaddr + (gpa << 12) - 0x40000000
  else
    target = vaddr + (gpa << 12)
  end

  if debug == true
    STDERR.puts "vaddr of guest memory is [0x#{vaddr}-0x#{vaddr+max}] ([0x#{vaddr>>12}+0x#{max>>12}] in pfn) \n"
    STDERR.puts "HVASTART:#{vaddr>>12}\n"
    STDERR.puts "HVASIZE:#{max>>12}\n"
    hextarget = "0x%x" % [target]
  end
else
  pid = ARGV[0].to_i
  target = ARGV[1].hex << 12
  hextarget = "0x%x" % [target]
  # puts "PID mode #{pid} #{target}"
end

pagemapfile = "/proc/#{pid}/pagemap"
io = open pagemapfile
io.seek((target >> 12) * 8, IO::SEEK_SET)
a = io.read 8
b = a.unpack("Q")[0] & 0xfffffffffff
corruptstr = "0x%x" % b
if debug == true
  STDERR.puts "target virtual address is #{hextarget}\n"
  STDERR.puts "target physical address is #{corruptstr}\n"
end
puts corruptstr
