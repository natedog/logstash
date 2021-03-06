require "logstash/filters/base"
require "logstash/namespace"
gem "jls-grok", ">=0.3.3209"
require "grok" # rubygem 'jls-grok'

class LogStash::Filters::Grokdiscovery < LogStash::Filters::Base

  config_name "grokdiscovery"

  public
  def initialize(config = {})
    super

    @discover_fields = {}
  end # def initialize

  public
  def register
    # TODO(sissel): Make patterns files come from the config
    @config.each do |type, typeconfig|
      @logger.debug("Registering type with grok: #{type}")
      @grok = Grok.new
      Dir.glob("patterns/*").each do |path|
        @grok.add_patterns_from_file(path)
      end
      @discover_fields[type] = typeconfig
      @logger.debug(["Enabling discovery", { :type => type, :fields => typeconfig }])
      @logger.warn(@discover_fields)
    end # @config.each
  end # def register

  public
  def filter(event)
    # parse it with grok
    message = event.message
    match = false

    if event.type and @discover_fields.include?(event.type)
      discover = @discover_fields[event.type] & event.fields.keys
      discover.each do |field|
        value = event.fields[field]
        value = [value] if value.is_a?(String)

        value.each do |v| 
          pattern = @grok.discover(v)
          @logger.warn("Trying #{v} => #{pattern}")
          @grok.compile(pattern)
          match = @grok.match(v)
          if match
            @logger.warn(["Match", match.captures])
            event.fields.merge!(match.captures) do |key, oldval, newval|
              @logger.warn(["Merging #{key}", oldval, newval])
              oldval + newval # should both be arrays...
            end
          else
            @logger.warn(["Discovery produced something not matchable?", { :input => v }])
          end
        end # value.each
      end # discover.each
    else
      @logger.info("Unknown type for #{event.source} (type: #{event.type})")
      @logger.debug(event.to_hash)
    end
    @logger.debug(["Event now: ", event.to_hash])
  end # def filter
end # class LogStash::Filters::Grokdiscovery
