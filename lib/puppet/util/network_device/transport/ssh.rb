
require 'puppet/util/network_device'
require 'puppet/util/network_device/transport'
require 'puppet/util/network_device/transport/base'

# This is an adaptation/simplification of gem net-ssh-telnet, which aims to have
# a sane interface to Net::SSH. Credits goes to net-ssh-telnet authors
class Puppet::Util::NetworkDevice::Transport::Ssh < Puppet::Util::NetworkDevice::Transport::Base
  attr_accessor :buf, :ssh, :channel

  def initialize(verbose = false)
    super()
    @verbose = verbose
    raise _('Connecting with ssh to a network device requires the \'net/ssh\' ruby library') unless Puppet.features.ssh?
  end

  # returns true
  def handles_login?
    true
  end

  # Returns if we have reached the end of file
  def eof?
    if [true, false].include? @eof
      @eof
    else
      !@eof.nil?
    end
  end

  # Opens an ssh connection
  def connect(&block)
    @output = []
    @channel_data = ''

    begin
      Puppet.debug("connecting to #{host} as #{user}")
      @ssh = Net::SSH.start(host, user, port: port, password: password, timeout: timeout)
    rescue TimeoutError
      raise TimeoutError, _('timed out while opening an ssh connection to the host'), $ERROR_INFO.backtrace
    rescue Net::SSH::AuthenticationFailed
      raise Puppet::Error, _('SSH authentication failure connecting to %{host} as %{user}') % { host: host, user: user }, $ERROR_INFO.backtrace
    rescue Net::SSH::Exception
      raise Puppet::Error, _('SSH connection failure to %{host}') % { host: host }, $ERROR_INFO.backtrace
    end

    @buf = ''
    @eof = false
    @channel = nil
    @ssh.open_channel do |channel|
      channel.request_pty { |_ch, success| raise _('failed to open pty') unless success }

      channel.send_channel_request('shell') do |ch, success|
        raise _('failed to open ssh shell channel') unless success

        ch.on_data { |_, data| @buf << data }
        ch.on_extended_data { |_, type, data| @buf << data if type == 1 }
        ch.on_close { @eof = true }

        @channel = ch
        expect(default_prompt, &block)
        # this is a little bit unorthodox, we're trying to escape
        # the ssh loop there while still having the ssh connection up
        # otherwise we wouldn't be able to return ssh stdout/stderr
        # for a given call of command.
        # rubocop:disable Lint/NonLocalExitFromIterator
        return
        # rubocop:enable Lint/NonLocalExitFromIterator
      end
    end
    @ssh.loop
  end

  # Closes ssh connection
  def close
    @channel.close if @channel
    @channel = nil
    @ssh.close if @ssh
  rescue IOError
    Puppet.debug 'device terminated ssh session impolitely'
  end

  # expect a return from ssh connection
  def expect(prompt)
    line = ''
    sock = @ssh.transport.socket

    until @eof
      break if line =~ prompt && @buf == ''
      break if sock.closed?

      IO.select([sock], [sock], nil, nil)

      process_ssh

      # at this point we have accumulated some data in @buf
      # or the channel has been closed
      if @buf != ''
        line += @buf.gsub(%r{\r\n}no, "\n")
        @buf = ''
        yield line if block_given?
      elsif @eof
        # channel has been closed
        break if line =~ prompt
        line = nil if line == ''
        yield nil if block_given? && line.nil?
        break
      end
    end
    Puppet.debug("ssh: expected #{line}") if @verbose
    line
  end

  # Send data over ssh connection
  def send(line)
    Puppet.debug("ssh: send #{line}") if @verbose
    @channel.send_data(line + "\n")
  end

  # Process ssh connection
  def process_ssh
    while @buf == '' && !eof?
      begin
        @channel.connection.process(0.1)
      rescue IOError
        @eof = true
      end
    end
  end
end
