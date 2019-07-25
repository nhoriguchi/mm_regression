#!/usr/bin/ruby

require 'pp'
require 'optparse'
require 'time'
require 'xmlsimple'
require 'tmpdir'

class SetupVirtNet
  def initialize argv
    arg_check argv
    get_vm_list
    stop_virtnet if @options[:dryrun].nil?
    update_virtnet
    start_virtnet if @options[:dryrun].nil?
    restart_libvirtd
    restart_vms if @options[:reset_guests] == :reboot
  end

  def get_vm_list
    @vm_list = []
    @vm_running = []
    tmp = `LANG=C virsh list --all`.chomp.split("\n")[2..-1]
    tmp.each do |line|
      if line =~ /(\S+)\s+(\S+)\s+(.*)$/
        @vm_list << $2
        if $3 != "shut off" and @options[:reset_guests] and @options[:dryrun].nil?
          @vm_running << $2
          system "virsh destroy #{$2}"
        end
      end
    end
  end

  def start_virtnet
    system "virsh net-start #{@options[:network]}"
  end

  def stop_virtnet
    system "virsh net-destroy #{@options[:network]}"
  end

  def get_mac_from_vm vm, nw
    xml = XmlSimple.xml_in(`virsh dumpxml #{vm}`, 'AttrPrefix' => true)
    xml["devices"][0]["interface"].each do |iface|
      if iface["@type"] == "network" and iface["source"][0]["@network"] == nw
        return iface["mac"][0]["@address"]
        break
      end
    end
    nil
  end

  def get_ip i
    tmp = @options[:baseaddr].split(".").map {|i| i.to_i}
    tmp[3] = i
    tmp.join(".")
  end

  def update_virtnet
    Dir.mktmpdir do |tmpd|
      @vm_mac = {}
      @vm_list.each do |vm|
        if mac = get_mac_from_vm(vm, @options[:network])
          @vm_mac[vm] = mac
        end
      end

      nwxml = XmlSimple.xml_in(`virsh net-dumpxml #{@options[:network]}`, 'AttrPrefix' => true)
      @virbr = nwxml["bridge"][0]["@name"]
      nwxml["ip"][0]["@address"] = @options[:baseaddr]
      nwxml["ip"][0]["dhcp"][0]["range"] = [{"@start" => get_ip(2), "@end" => get_ip(254)}]
      hosts = []
      i = 2
      @vm_ip = {}
      @vm_mac.each do |k, v|
        hosts << {"@mac" => v, "@name" => k, "@ip" => get_ip(i)}
        @vm_ip[k] = get_ip(i)
        i += 1
      end
      nwxml["ip"][0]["dhcp"][0]["host"] = hosts
      if @options[:dryrun]
        puts XmlSimple.xml_out(nwxml, {"RootName" => "network", 'AttrPrefix' => true})
      else
        File.write("#{tmpd}/nw_new.xml", XmlSimple.xml_out(nwxml, {"RootName" => "network", 'AttrPrefix' => true}))
      end

      etchosts = File.read("/etc/hosts").chomp.split("\n")
      etchosts.delete_if do |h|
        @vm_mac.any? {|k, v| h =~ Regexp.new(" #{k}$")}
      end
      etchosts.delete_if do |h|
        @options[:baseaddr].split(".")[0..2] == h.split(" ")[0].split(".")[0..2]
      end
      etchosts.delete_if do |h|
        @vm_ip.any? {|k, v| h =~ Regexp.new(" #{k}$")}
      end
      @vm_ip.each do |k, v|
        etchosts << "#{v} #{k}"
      end
      if @options[:dryrun]
        puts etchosts.join("\n")
      else
        etchosts << "" # to add newline on the EOF
        File.write("/etc/hosts", etchosts.join("\n"))
        system "virsh net-define #{tmpd}/nw_new.xml"
      end
    end
  end

  def restart_libvirtd
    sleep 1
    system "systemctl stop libvirtd"
    puts "rm -f /var/lib/libvirt/dnsmasq/#{@virbr}.status"
    system "rm -f /var/lib/libvirt/dnsmasq/#{@virbr}.status"
    puts "pkill -9 -f /sbin/dnsmasq"
    system "pkill -9 -f /sbin/dnsmasq"
    puts "systemctl start libvirtd"
    system "systemctl restart libvirtd"
    system "systemctl restart libvirtd"
    sleep 5
  end

  def restart_vms
    @vm_running.each do |vm|
      system "virst start #{vm}"
    end
  end

  def arg_check argv
    @options = {
      :baseaddr => "10.10.10.1",
      :network => "default",
    }

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [-options] <targetcommit>"
      opts.on("-g gitdir", "--git-dir", "change GIT_DIR") do |d|
        ENV['GIT_DIR'] = d =~ /\.git$/ ? d : d + "/.git"
      end
      opts.on("--dry-run") do
        @options[:dryrun] = true
      end
      opts.on("--network network") do |nw|
        @options[:network] = nw
      end
      opts.on("--baseaddr ip") do |ip|
        @options[:baseaddr] = ip
      end
      opts.on("--shutoff-guests") do
        @options[:reset_guests] = :shutdown
      end
      opts.on("--reboot-guests") do
        @options[:reset_guests] = :reboot
      end
      opts.on("--show") do
        system "
          virsh net-dumpxml #{@options[:network]}
          cat /etc/hosts
        "
        exit
      end
    end.parse! argv
  end
end

if $0 == __FILE__
  SetupVirtNet.new ARGV
end
