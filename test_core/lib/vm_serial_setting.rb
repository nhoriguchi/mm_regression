require 'nokogiri'

# usage:
#   set serial to pty-based or file-based:
#     ./vm_serial_setting.rb <vm> [pty|file] <source path>
#
#   show current serial mode:
#     ./vm_serial_setting.rb <vm>

tmp = `virsh dumpxml #{ARGV[0]}`
doc = Nokogiri::XML(tmp)

if ARGV[1] == "pty"
  elm = doc.xpath("//domain/devices/serial[@type='file']")
  exit 1 if elm.empty?
elsif ARGV[1] == "file"
  elm = doc.xpath("//domain/devices/serial[@type='pty']")
  exit 1 if elm.empty?
elsif ARGV[1].nil?
  elm = doc.xpath("//domain/devices/serial[@type='file']")
  if ! elm.empty?
    puts "found file-based serial setting"
    puts elm.xpath("source")[0]["path"]
    exit
  end
  elm = doc.xpath("//domain/devices/serial[@type='pty']")
  if ! elm.empty?
    puts "found pty-based serial setting"
    puts elm.xpath("source")[0]["path"]
    exit
  end
  exit
end

elm[0]['type'] = ARGV[1]
source = elm.xpath("source")[0]
source['path'] = ARGV[2]
# puts elm.to_xml
File.write("/tmp/newvirtxml.xml", doc.to_xml)
system "virsh define /tmp/newvirtxml.xml"
exit 0
