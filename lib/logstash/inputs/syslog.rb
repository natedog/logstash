require "date"
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/time" # should really use the filters/date.rb bits
require "socket"

class LogStash::Inputs::Syslog < LogStash::Inputs::Base

  config_name "syslog"

  # TCP listen configuration
  config :host, :validate => :string
  config :port, :validate => :number

  public
  def initialize(params)
    super

    @host ||= "0.0.0.0"
    @port ||= 514
  end

  public
  def register
    # This comes from RFC3164, mostly.
    @@syslog_re ||= \
      /<([0-9]{1,3})>([A-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) (\S+) (.*)/
      #<priority       timestamp          Mmm dd hh:mm:ss             host  msg
  end # def register

  public
  def run(output_queue)
    # udp server
    Thread.new do
      LogStash::Util::set_thread_name("input|syslog|udp")
      begin
        udp_listener(output_queue)
      rescue
        @logger.warn("syslog udp listener died: #{$!}")
        sleep(5)
        retry
      end # begin
    end # Thread.new

    # tcp server
    Thread.new do
      LogStash::Util::set_thread_name("input|syslog|tcp")
      begin
        tcp_listener(output_queue)
      rescue
        @logger.warn("syslog tcp listener died: #{$!}")
        sleep(5)
        retry
      end # begin
    end # Thread.new
  end # def run

  private
  def udp_listener(output_queue)
    @logger.info("Starting syslog udp listener on #{@host}:#{@port}")
    s = UDPSocket.new
    s.bind(@host, @port)

    loop do
      line, client = s.recvfrom(1024)
      event = LogStash::Event.new({
        "@message" => line.chomp,
        "@type" => @type,
        "@tags" => @tags.clone,
      })
      source = URI.parse("syslog://#{client[3]}")
      syslog_relay(event, source)
      output_queue << event
    end
  end # def udp_listener

  private
  def tcp_listener(output_queue)
    @logger.info("Starting syslog tcp listener on #{@host}:#{@port}")
    s = TCPServer.new(@host, @port)

    loop do
      Thread.new(s.accept) do |s|
        ip, port = s.peeraddr[3], s.peeraddr[1]
        @logger.warn("got connection from #{ip}:#{port}")
        LogStash::Util::set_thread_name("input|syslog|tcp|#{ip}:#{port}}")
        source_base = URI.parse("syslog://#{ip}")
        s.each do |line|
          event = LogStash::Event.new({
            "@message" => line.chomp,
            "@type" => @type,
            "@tags" => @tags.clone,
          })
          source = source_base.dup
          syslog_relay(event, source)
          output_queue << event
        end
      end
    end
  end # def tcp_listener

  # Following RFC3164 where sane, we'll try to parse a received message
  # as if you were relaying a syslog message to it.
  # If the message cannot be recognized (see @@syslog_re), we'll
  # treat it like the whole event.message is correct and try to fill
  # the missing pieces (host, priority, etc)
  public
  def syslog_relay(event, url)
    match = @@syslog_re.match(event.message)
    if match
      # match[1,2,3,4] = {pri, timestamp, hostname, message}
      # Per RFC3164, priority = (facility * 8) + severity
      #                       = (facility << 3) & (severity)
      priority = match[1].to_i
      severity = priority & 7   # 7 is 111 (3 bits)
      facility = priority >> 3
      event.fields["priority"] = priority
      event.fields["severity"] = severity
      event.fields["facility"] = facility

      # TODO(sissel): Use the date filter, somehow.
      event.timestamp = LogStash::Time.to_iso8601(
        DateTime.strptime(match[2], "%b %d %H:%M:%S"))

      # At least the hostname is simple...
      url.host = match[3]
      url.port = nil
      event.source = url

      event.message = match[4]
    else
      @logger.info(["NOT SYSLOG", event.message])
      url.host = Socket.gethostname if url.host == "127.0.0.1"

      # RFC3164 says unknown messages get pri=13
      priority = 13
      severity = priority & 7   # 7 is 111 (3 bits)
      facility = priority >> 3
      event.fields["priority"] = 13
      event.fields["severity"] = 5   # 13 & 7 == 5
      event.fields["facility"] = 1   # 13 >> 3 == 1

      # Don't need to modify the message, here.
      # event.message = ...

      event.source = url
    end
  end # def syslog_relay
end # class LogStash::Inputs::Syslog
