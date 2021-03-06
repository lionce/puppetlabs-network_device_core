require 'puppet'
require 'puppet/util'
require 'puppet/util/network_device/base'
require 'puppet/util/network_device/ipcalc'
require 'puppet/util/network_device/cisco/interface'
require 'puppet/util/network_device/cisco/facts'
require 'ipaddr'

# Cisco Device
class Puppet::Util::NetworkDevice::Cisco::Device < Puppet::Util::NetworkDevice::Base
  include Puppet::Util::NetworkDevice::IPCalc

  attr_accessor :enable_password

  # Create a new
  def initialize(url, options = {})
    super(url, options)
    @enable_password = options[:enable_password] || parse_enable(@url.query)
    transport.default_prompt = %r{[#>]\s?\z}n
  end

  # Parse the `enable` parameter
  def parse_enable(query)
    params = CGI.parse(query) if query
    params['enable'].first unless params.nil? || params['enable'].empty?
  end

  # Connect to the transport
  def connect
    transport.connect
    login
    transport.command('terminal length 0') do |out|
      enable if out =~ %r{>\s?\z}n
    end
    find_capabilities
  end

  # Close the connection
  def disconnect
    transport.close
  end

  # Execute command and return the resulting output
  def command(cmd = nil)
    connect
    out = execute(cmd) if cmd
    yield self if block_given?
    disconnect
    out
  end

  # Execute the command
  def execute(cmd)
    transport.command(cmd) do |out|
      if out =~ %r{^%}mo || out =~ %r{^Command rejected:}mo
        # strip off the command just sent
        error = out.sub(cmd, '')
        Puppet.err _("Error while executing '%{cmd}', device returned: %{error}") % { cmd: cmd, error: error }
      end
    end
  end

  # Login to the transport
  def login
    return if transport.handles_login?
    if @url.user != ''
      transport.command(@url.user, prompt: %r{^Password:})
    else
      transport.expect(%r{^Password:})
    end
    transport.command(@url.password)
  end

  # Enable the transport
  def enable
    raise _("Can't issue \"enable\" to enter privileged, no enable password set") unless enable_password
    transport.command('enable', prompt: %r{^Password:})
    transport.command(enable_password)
  end

  # Return if the vlan brief is supported
  def support_vlan_brief?
    if [true, false].include? @support_vlan_brief
      @support_vlan_brief
    else
      !@support_vlan_brief.nil?
    end
  end

  # Find if vlan brief is supported
  def find_capabilities
    out = execute('sh vlan brief')
    lines = out.split("\n")
    lines.shift
    lines.pop

    @support_vlan_brief = lines.first !~ %r{^%}
  end

  # ifnames for each interface type
  IF = {
    FastEthernet: ['FastEthernet', 'FastEth', 'Fast', 'FE', 'Fa', 'F'],
    GigabitEthernet: ['GigabitEthernet', 'GigEthernet', 'GigEth', 'GE', 'Gi', 'G'],
    TenGigabitEthernet: ['TenGigabitEthernet', 'TE', 'Te'],
    Ethernet: ['Ethernet', 'Eth', 'E'],
    Serial: ['Serial', 'Se', 'S'],
    PortChannel: ['PortChannel', 'Port-Channel', 'Po'],
    POS: ['POS', 'P'],
    VLAN: ['VLAN', 'VL', 'V'],
    Loopback: ['Loopback', 'Loop', 'Lo'],
    ATM: ['ATM', 'AT', 'A'],
    Dialer: ['Dialer', 'Dial', 'Di', 'D'],
    VirtualAccess: ['Virtual-Access', 'Virtual-A', 'Virtual', 'Virt'],
  }.freeze

  # Canonicalize ifnames
  def canonicalize_ifname(interface)
    IF.each do |k, ifnames|
      found = ifnames.find { |ifname| interface =~ %r{^#{ifname}\s*\d}i }
      if found
        found = %r{^#{found}(.+)\Z}i.match(interface)
        return "#{k}#{found[1]}".gsub(%r{\s+}, '')
      end
    end
    interface
  end

  # Return facts for the given transport
  def facts
    @facts ||= Puppet::Util::NetworkDevice::Cisco::Facts.new(transport)
    facts = {}
    command do |_ng|
      facts = @facts.retrieve
    end
    facts
  end

  # Check if the interface is enabled
  def interface(name)
    ifname = canonicalize_ifname(name)
    interface = parse_interface(ifname)
    return { ensure: :absent } if interface.empty?
    interface.merge!(parse_trunking(ifname))
    interface.merge!(parse_interface_config(ifname))
  end

  # Create a new interface
  def new_interface(name)
    Puppet::Util::NetworkDevice::Cisco::Interface.new(canonicalize_ifname(name), transport)
  end

  # Parse interface name
  def parse_interface(name)
    resource = {}
    out = execute("sh interface #{name}")
    lines = out.split("\n")
    lines.shift
    lines.pop
    lines.each do |l|
      if l =~ %r{#{name} is (.+), line protocol is }
        resource[:ensure] = ((Regexp.last_match(1) == 'up') ? :present : :absent)
      end
      if l =~ %r{Auto Speed \(.+\),} || l =~ %r{Auto Speed ,} || l =~ %r{Auto-speed}
        resource[:speed] = :auto
      end
      if l =~ %r{, (.+)Mb/s}
        resource[:speed] = Regexp.last_match(1)
      end
      if l =~ %r{\s+Auto-duplex \((.{4})\),}
        resource[:duplex] = :auto
      end
      if l =~ %r{\s+(.+)-duplex}
        resource[:duplex] = (Regexp.last_match(1) == 'Auto') ? :auto : Regexp.last_match(1).downcase.to_sym
      end
      if l =~ %r{Description: (.+)}
        resource[:description] = Regexp.last_match(1)
      end
    end
    resource
  end

  # Parse interface configg
  def parse_interface_config(name)
    resource = Hash.new { |hash, key| hash[key] = []; }
    out = execute("sh running-config interface #{name} | begin interface")
    lines = out.split("\n")
    lines.shift
    lines.pop
    lines.each do |l|
      if l =~ %r{ip address (#{IP}) (#{IP})\s+secondary\s*$}
        resource[:ipaddress] << [prefix_length(IPAddr.new(Regexp.last_match(2))), IPAddr.new(Regexp.last_match(1)), 'secondary']
      end
      if l =~ %r{ip address (#{IP}) (#{IP})\s*$}
        resource[:ipaddress] << [prefix_length(IPAddr.new(Regexp.last_match(2))), IPAddr.new(Regexp.last_match(1)), nil]
      end
      if l =~ %r{ipv6 address (#{IP})/(\d+) (eui-64|link-local)}
        resource[:ipaddress] << [Regexp.last_match(2).to_i, IPAddr.new(Regexp.last_match(1)), Regexp.last_match(3)]
      end
      if l =~ %r{channel-group\s+(\d+)}
        resource[:etherchannel] = Regexp.last_match(1)
      end
    end
    resource
  end

  # Parse vlans
  def parse_vlans
    vlans = {}
    out = execute(support_vlan_brief? ? 'sh vlan brief' : 'sh vlan-switch brief')
    lines = out.split("\n")
    lines.shift
    lines.shift
    lines.shift
    lines.pop
    vlan = nil
    lines.each do |l|
      case l
      # vlan    name    status
      when %r{^(\d+)\s+(\w+)\s+(\w+)\s+([a-zA-Z0-9,/. ]+)\s*$}
        vlan = { name: Regexp.last_match(1), description: Regexp.last_match(2), status: Regexp.last_match(3), interfaces: [] }
        unless Regexp.last_match(4).strip.empty?
          vlan[:interfaces] = Regexp.last_match(4).strip.split(%r{\s*,\s*}).map { |ifn| canonicalize_ifname(ifn) }
        end
        vlans[vlan[:name]] = vlan
      when %r{^\s+([a-zA-Z0-9,/. ]+)\s*$}
        raise _('invalid sh vlan summary output') unless vlan
        unless Regexp.last_match(1).strip.empty?
          vlan[:interfaces] += Regexp.last_match(1).strip.split(%r{\s*,\s*}).map { |ifn| canonicalize_ifname(ifn) }
        end
      end
    end
    vlans
  end

  # Update vlan
  def update_vlan(id, is = {}, should = {})
    if should[:ensure] == :absent
      Puppet.info _('Removing %{id} from device vlan') % { id: id }
      execute('conf t')
      execute("no vlan #{id}")
      execute('exit')
      return
    end

    # Cisco VLANs are supposed to be alphanumeric only
    if should[:description] =~ %r{[^\w]}
      Puppet.err _("Invalid VLAN name '%{name}' for Cisco device.\nVLAN name must be alphanumeric, no spaces or special characters.") % { name: should[:description] }
      return
    end

    # We're creating or updating an entry
    execute('conf t')
    execute("vlan #{id}")
    [is.keys, should.keys].flatten.uniq.each do |property|
      Puppet.debug("trying property: #{property}: #{should[property]}")
      next if property != :description
      execute("name #{should[property]}")
    end
    execute('exit')
    execute('exit')
  end

  # Parse trunking
  def parse_trunking(interface)
    trunking = {}
    out = execute("sh interface #{interface} switchport")
    lines = out.split("\n")
    lines.shift
    lines.pop
    lines.each do |l|
      case l
      when %r{^Administrative mode:\s+(.*)$}i
        case Regexp.last_match(1)
        when 'trunk'
          trunking[:mode] = :trunk
        when 'static access'
          trunking[:mode] = :access
        when 'dynamic auto'
          trunking[:mode] = 'dynamic auto'
        when 'dynamic desirable'
          trunking[:mode] = 'dynamic desirable'
        else
          raise _('Unknown switchport mode: %{mode} for %{interface}') % { mode: Regexp.last_match(1), interface: interface }
        end
      when %r{^Administrative Trunking Encapsulation:\s+(.*)$}
        case Regexp.last_match(1)
        when 'dot1q', 'isl'
          trunking[:encapsulation] = Regexp.last_match(1).to_sym if trunking[:mode] != :access
        when 'negotiate'
          trunking[:encapsulation] = :negotiate
        else
          raise _('Unknown switchport encapsulation: %{value} for %{interface}') % { value: Regexp.last_match(1), interface: interface }
        end
      when %r{^Access Mode VLAN:\s+(.*) \((.*)\)$}
        trunking[:access_vlan] = Regexp.last_match(1) if Regexp.last_match(2) != '(Inactive)'
      when %r{^Trunking Native Mode VLAN:\s+(.*) \(.*\)$}
        trunking[:native_vlan] = Regexp.last_match(1)
      when %r{^Trunking VLANs Enabled:\s+(.*)$}
        next if trunking[:mode] == :access
        vlans = Regexp.last_match(1)
        trunking[:allowed_trunk_vlans] = case vlans
                                         when %r{all}i
                                           :all
                                         when %r{none}i
                                           :none
                                         else
                                           vlans
                                         end
      end
    end
    trunking
  end
end
