#
# Copyright (c) 2009-2012 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module RightAMQP

  # Client for multiple AMQP brokers used together to achieve a high availability
  # messaging routing service
  class HABrokerClient

    include RightSupport::Log::Mixin

    class NoUserData < Exception; end
    class NoBrokerHosts < Exception; end
    class NoConnectedBrokers < Exception; end

    # Message publishing context
    class Context

      # (String) Message class name in lower snake case
      attr_reader :name

      # (String) Request type if applicable
      attr_reader :type

      # (String) Original sender of message if applicable
      attr_reader :from

      # (String) Generated message identifier if applicable
      attr_reader :token

      # (Boolean) Whether the packet is one that does not have an associated response
      attr_reader :one_way

      # (Hash) Options used to publish message
      attr_reader :options

      # (Array) Identity of candidate brokers when message was published
      attr_reader :brokers

      # (Array) Identity of brokers that have failed to deliver message with last one at end
      attr_reader :failed

      # Create context
      #
      # === Parameters
      # packet(Packet):: Packet being published
      # options(Hash):: Publish options
      # brokers(Array):: Identity of candidate brokers
      def initialize(packet, options, brokers)
        @name    = (packet.respond_to?(:name) ? packet.name : packet.class.name.snake_case)
        @type    = (packet.type if packet.respond_to?(:type) && packet.type != packet.class)
        @from    = (packet.from if packet.respond_to?(:from))
        @token   = (packet.token if packet.respond_to?(:token))
        @one_way = (packet.respond_to?(:one_way) ? packet.one_way : true)
        @options = options
        @brokers = brokers
        @failed  = []
      end

      # Record delivery failure
      #
      # === Parameters
      # identity(String):: Identity of broker that failed delivery
      #
      # === Return
      # true:: Always return true
      def record_failure(identity)
        @failed << identity
      end

    end

    # Default number of seconds between reconnect attempts
    RECONNECT_INTERVAL = 60

    # (Array(Broker)) Priority ordered list of AMQP broker clients (exposed only for unit test purposes)
    attr_accessor :brokers

    # Create connections to all configured AMQP brokers
    # The constructed broker client list is in priority order
    #
    # === Parameters
    # serializer(Serializer):: Serializer used for marshaling packets being published or
    #   unmarshaling received messages to packets (responds to :dump and :load); if nil, has
    #   same effect as setting subscribe option :no_serialize and publish option :no_unserialize
    # options(Hash):: Configuration options
    #   :user(String):: User name
    #   :pass(String):: Password
    #   :vhost(String):: Virtual host path name
    #   :insist(Boolean):: Whether to suppress redirection of connection
    #   :reconnect_interval(Integer):: Number of seconds between reconnect attempts, defaults to RECONNECT_INTERVAL
    #   :heartbeat(Integer):: Number of seconds between AMQP connection heartbeats used to keep
    #     connection alive (e.g., when AMQP broker is behind a firewall), nil or 0 means disable
    #   :host{String):: Comma-separated list of AMQP broker host names; if only one, it is reapplied
    #     to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #     and a short string to be used as a broker index; the index defaults to the list index,
    #     e.g., "host_a:0, host_c:2"
    #   :port(String|Integer):: Comma-separated list of AMQP broker port numbers corresponding to :host list;
    #     if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #   :prefetch(Integer):: Maximum number of messages the AMQP broker is to prefetch for the agent
    #     before it receives an ack. Value 1 ensures that only last unacknowledged gets redelivered
    #     if the agent crashes. Value 0 means unlimited prefetch.
    #   :order(Symbol):: Broker selection order when publishing a message: :random or :priority,
    #     defaults to :priority, value can be overridden on publish call
    #   :exception_callback(Proc):: Callback activated on exception events with parameters
    #     exception(Exception):: Exception
    #     message(Packet):: Message being processed
    #     client(HABrokerClient):: Reference to this client
    #   :exception_on_receive_callback(Proc):: Callback activated on a receive exception with parameters
    #     message(String):: Message content that caused an exception
    #     exception(Exception):: Exception that was raised
    #
    # === Raise
    # ArgumentError:: If :host and :port are not matched lists or if serializer does not respond
    #   to :dump and :load
    def initialize(serializer, options = {})
      @options = options.dup
      @options[:update_status_callback] = lambda { |b, c| update_status(b, c) }
      @options[:reconnect_interval] ||= RECONNECT_INTERVAL
      @connection_status = {}
      unless serializer.nil? || [:dump, :load].all? { |m| serializer.respond_to?(m) }
        raise ArgumentError, "serializer must be a class/object that responds to :dump and :load"
      end
      @serializer = serializer
      @published = Published.new
      reset_stats
      @select = @options[:order] || :priority
      @brokers = connect_all
      @closed = false
      @brokers_hash = {}
      @brokers.each { |b| @brokers_hash[b.identity] = b }
      return_message { |i, r, m, t, c| handle_return(i, r, m, t, c) }
    end

    # Parse agent user data to extract broker host and port configuration
    # An agent is permitted to only support using one broker
    #
    # === Parameters
    # user_data(String):: Agent user data in <name>=<value>&<name>=<value>&... form
    #   with required name RS_rn_url and optional names RS_rn_host and RS_rn_port
    #
    # === Return
    # (Array):: Broker hosts and ports as comma-separated list in priority order in the form
    #   <hostname>:<index>,<hostname>:<index>,...
    #   <port>:<index>,<port>:<index>,... or nil if none specified
    #
    # === Raise
    # NoUserData:: If the user data is missing
    # NoBrokerHosts:: If no brokers could be extracted from the user data
    def self.parse_user_data(user_data)
      raise NoUserData.new("User data is missing") if user_data.nil? || user_data.empty?
      hosts = ""
      ports = nil
      user_data.split("&").each do |data|
        name, value = data.split("=")
        if name == "RS_rn_url"
          h = value.split("@").last.split("/").first
          # Translate host name used by very old agents using only one broker
          h = "broker1-1.rightscale.com" if h == "broker.rightscale.com"
          hosts = h + hosts
        end
        if name == "RS_rn_host"
          hosts << value
        end
        if name == "RS_rn_port"
          ports = value
        end
      end
      raise NoBrokerHosts.new("No brokers found in user data") if hosts.empty?
      [hosts, ports]
    end

    # Parse host and port information to form list of broker address information
    #
    # === Parameters
    # host{String):: Comma-separated list of broker host names; if only one, it is reapplied
    #   to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #   and a short string to be used as a broker index; the index defaults to the list index,
    #   e.g., "host_a:0, host_c:2"
    # port(String|Integer):: Comma-separated list of broker port numbers corresponding to :host list;
    #   if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #
    # === Returns
    # (Array(Hash)):: List of broker addresses with keys :host, :port, :index
    #
    # === Raise
    # ArgumentError:: If host and port are not matched lists
    def self.addresses(host, port)
      hosts = if host && !host.empty? then host.split(/,\s*/) else [ "localhost" ] end
      ports = if port && port.size > 0 then port.to_s.split(/,\s*/) else [ ::AMQP::PORT ] end
      if hosts.size != ports.size && hosts.size != 1 && ports.size != 1
        raise ArgumentError.new("Unmatched AMQP host/port lists -- hosts: #{host.inspect} ports: #{port.inspect}")
      end
      i = -1
      if hosts.size > 1
        hosts.map do |host|
          i += 1
          h = host.split(/:\s*/)
          port = if ports[i] then ports[i].to_i else ports[0].to_i end
          port = port.to_s.split(/:\s*/)[0]
          {:host => h[0], :port => port.to_i, :index => (h[1] || i.to_s).to_i}
        end
      else
        ports.map do |port|
          i += 1
          p = port.to_s.split(/:\s*/)
          host = if hosts[i] then hosts[i] else hosts[0] end
          host = host.split(/:\s*/)[0]
          {:host => host, :port => p[0].to_i, :index => (p[1] || i.to_s).to_i}
        end
      end
    end

    # Parse host and port information to form list of broker identities
    #
    # === Parameters
    # host{String):: Comma-separated list of broker host names; if only one, it is reapplied
    #   to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #   and a short string to be used as a broker index; the index defaults to the list index,
    #   e.g., "host_a:0, host_c:2"
    # port(String|Integer):: Comma-separated list of broker port numbers corresponding to :host list;
    #   if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #
    # === Returns
    # (Array):: Identity of each broker
    #
    # === Raise
    # ArgumentError:: If host and port are not matched lists
    def self.identities(host, port = nil)
      addresses(host, port).map { |a| identity(a[:host], a[:port]) }
    end

    # Construct a broker serialized identity from its host and port of the form
    # rs-broker-host-port, with any '-'s in host replaced by '~'
    #
    # === Parameters
    # host{String):: IP host name or address for individual broker
    # port(Integer):: TCP port number for individual broker, defaults to ::AMQP::PORT
    #
    # === Returns
    # (String):: Broker serialized identity
    def self.identity(host, port = nil)
      port ||= ::AMQP::PORT
      "rs-broker-#{host.gsub('-', '~')}-#{port.to_i}"
    end

    # Break broker serialized identity down into individual parts if exists
    #
    # === Parameters
    # id(Integer|String):: Broker alias or serialized identity
    #
    # === Return
    # (Array):: Host, port, index, and priority, or all nil if broker not found
    def identity_parts(id)
      @brokers.each do |b|
        return [b.host, b.port, b.index, priority(b.identity)] if b.identity == id || b.alias == id
      end
      [nil, nil, nil, nil]
    end

    # Convert broker identities to aliases
    #
    # === Parameters
    # identities(Array):: Broker identities
    #
    # === Return
    # (Array):: Broker aliases
    def aliases(identities)
      identities.map { |i| alias_(i) }
    end

    # Convert broker serialized identity to its alias
    #
    # === Parameters
    # identity(String):: Broker serialized identity
    #
    # === Return
    # (String|nil):: Broker alias, or nil if not a known broker
    def alias_(identity)
      @brokers_hash[identity].alias rescue nil
    end

    # Form string of hosts and associated indices
    #
    # === Return
    # (String):: Comma separated list of host:index
    def hosts
      @brokers.map { |b| "#{b.host}:#{b.index}" }.join(",")
    end

    # Form string of ports and associated indices
    #
    # === Return
    # (String):: Comma separated list of port:index
    def ports
      @brokers.map { |b| "#{b.port}:#{b.index}" }.join(",")
    end

    # Get broker serialized identity if client exists
    #
    # === Parameters
    # id(Integer|String):: Broker alias or serialized identity
    #
    # === Return
    # (String|nil):: Broker serialized identity if client found, otherwise nil
    def get(id)
      @brokers.each { |b| return b.identity if b.identity == id || b.alias == id }
      nil
    end

    # Check whether connected to broker
    #
    # === Parameters
    # identity{String):: Broker serialized identity
    #
    # === Return
    # (Boolean):: true if connected to broker, otherwise false, or nil if broker unknown
    def connected?(identity)
      @brokers_hash[identity].connected? rescue nil
    end

    # Get serialized identity of connected brokers
    #
    # === Return
    # (Array):: Serialized identity of connected brokers
    def connected
      @brokers.inject([]) { |c, b| if b.connected? then c << b.identity else c end }
    end

    # Get serialized identity of brokers that are usable, i.e., connecting or confirmed connected
    #
    # === Return
    # (Array):: Serialized identity of usable brokers
    def usable
      each_usable.map { |b| b.identity }
    end

    # Get serialized identity of unusable brokers
    #
    # === Return
    # (Array):: Serialized identity of unusable brokers
    def unusable
      @brokers.map { |b| b.identity } - each_usable.map { |b| b.identity }
    end

    # Get serialized identity of all brokers
    #
    # === Return
    # (Array):: Serialized identity of all brokers
    def all
      @brokers.map { |b| b.identity }
    end

    # Get serialized identity of failed broker clients, i.e., ones that were never successfully
    # connected, not ones that are just disconnected
    #
    # === Return
    # (Array):: Serialized identity of failed broker clients
    def failed
      @brokers.inject([]) { |c, b| b.failed? ? c << b.identity : c }
    end

    # Change connection heartbeat frequency to be used for any new connections
    #
    # === Parameters
    # heartbeat(Integer):: Number of seconds between AMQP connection heartbeats used to keep
    #   connection alive (e.g., when AMQP broker is behind a firewall), nil or 0 means disable
    #
    # === Return
    # (Integer|nil):: New heartbeat setting
    def heartbeat=(heartbeat)
      @options[:heartbeat] = heartbeat
    end

    # Make new connection to broker at specified address unless already connected
    # or currently connecting
    #
    # === Parameters
    # host{String):: IP host name or address for individual broker
    # port(Integer):: TCP port number for individual broker
    # index(Integer):: Unique index for broker within set for use in forming alias
    # priority(Integer|nil):: Priority position of this broker in set for use by this agent
    #   with nil or a value that would leave a gap in the list meaning add to end of list
    # force(Boolean):: Reconnect even if already connected
    #
    # === Block
    # Optional block with following parameters to be called after initiating the connection
    # unless already connected to this broker:
    #   identity(String):: Broker serialized identity
    #
    # === Return
    # (Boolean):: true if connected, false if no connect attempt made
    #
    # === Raise
    # Exception:: If host and port do not match an existing broker but index does
    def connect(host, port, index, priority = nil, force = false, &blk)
      identity = self.class.identity(host, port)
      existing = @brokers_hash[identity]
      if existing && existing.usable? && !force
        logger.info("Ignored request to reconnect #{identity} because already #{existing.status.to_s}")
        false
      else
        old_identity = identity
        @brokers.each do |b|
          if index == b.index
            # Changing host and/or port of existing broker client
            old_identity = b.identity
            break
          end
        end unless existing

        address = {:host => host, :port => port, :index => index}
        broker = BrokerClient.new(identity, address, @serializer, @exceptions, @options, existing)
        p = priority(old_identity)
        if priority && priority < p
          @brokers.insert(priority, broker)
        elsif priority && priority > p
          logger.info("Reduced priority setting for broker #{identity} from #{priority} to #{p} to avoid gap in list")
          @brokers.insert(p, broker)
        else
          @brokers[p].close if @brokers[p]
          @brokers[p] = broker
        end
        @brokers_hash[identity] = broker
        yield broker.identity if block_given?
        true
      end
    end

    # Subscribe an AMQP queue to an AMQP exchange on all broker clients that are connected or still connecting
    # Allow connecting here because subscribing may happen before all have confirmed connected
    # Do not wait for confirmation from broker client that subscription is complete
    # When a message is received, acknowledge, unserialize, and log it as specified
    # If the message is unserialized and it is not of the right type, it is dropped after logging a warning
    #
    # === Parameters
    # queue(Hash):: AMQP queue being subscribed with keys :name and :options,
    #   which are the standard AMQP ones plus
    #     :no_declare(Boolean):: Whether to skip declaring this queue on the broker
    #       to cause its creation; for use when client does not have permission to create or
    #       knows the queue already exists and wants to avoid declare overhead
    # exchange(Hash|nil):: AMQP exchange to subscribe to with keys :type, :name, and :options,
    #   nil means use empty exchange by directly subscribing to queue; the :options are the
    #   standard AMQP ones plus
    #     :no_declare(Boolean):: Whether to skip declaring this exchange on the broker
    #       to cause its creation; for use when client does not have create permission or
    #       knows the exchange already exists and wants to avoid declare overhead
    # options(Hash):: Subscribe options:
    #   :ack(Boolean):: Explicitly acknowledge received messages to AMQP
    #   :no_unserialize(Boolean):: Do not unserialize message, this is an escape for special
    #     situations like enrollment, also implicitly disables receive filtering and logging;
    #     this option is implicitly invoked if initialize without a serializer
    #   (packet class)(Array(Symbol)):: Filters to be applied in to_s when logging packet to :info,
    #     only packet classes specified are accepted, others are not processed but are logged with error
    #   :category(String):: Packet category description to be used in error messages
    #   :log_data(String):: Additional data to display at end of log entry
    #   :no_log(Boolean):: Disable receive logging unless debug level
    #   :exchange2(Hash):: Additional exchange to which same queue is to be bound
    #   :brokers(Array):: Identity of brokers for which to subscribe, defaults to all usable if nil or empty
    #
    # === Block
    # Block with following parameters to be called each time exchange matches a message to the queue:
    #   identity(String):: Serialized identity of broker delivering the message
    #   message(Packet|String):: Message received, which is unserialized unless :no_unserialize was specified
    #   header(AMQP::Protocol::Header):: Message header (optional block parameter)
    #
    # === Return
    # identities(Array):: Identity of brokers where successfully subscribed
    def subscribe(queue, exchange = nil, options = {}, &blk)
      identities = []
      brokers = options.delete(:brokers)
      each_usable(brokers) { |b| identities << b.identity if b.subscribe(queue, exchange, options, &blk) }
      logger.info("Could not subscribe to queue #{queue.inspect} on exchange #{exchange.inspect} " +
                  "on brokers #{each_usable(brokers).inspect} when selected #{brokers.inspect} " +
                  "from usable #{usable.inspect}") if identities.empty?
      identities
    end

    # Unsubscribe from the specified queues on usable broker clients
    # Silently ignore unknown queues
    #
    # === Parameters
    # queue_names(Array):: Names of queues previously subscribed to
    # timeout(Integer):: Number of seconds to wait for all confirmations, defaults to no timeout
    #
    # === Block
    # Optional block with no parameters to be called after all queues are unsubscribed
    #
    # === Return
    # true:: Always return true
    def unsubscribe(queue_names, timeout = nil, &blk)
      count = each_usable.inject(0) do |c, b|
        c + b.queues.inject(0) { |c, q| c + (queue_names.include?(q.name) ? 1 : 0) }
      end
      if count == 0
        blk.call if blk
      else
        handler = CountedDeferrable.new(count, timeout)
        handler.callback { blk.call if blk }
        each_usable { |b| b.unsubscribe(queue_names) { handler.completed_one } }
      end
      true
    end

    # Declare queue or exchange object but do not subscribe to it
    #
    # === Parameters
    # type(Symbol):: Type of object: :queue, :direct, :fanout or :topic
    # name(String):: Name of object
    # options(Hash):: Standard AMQP declare options plus
    #   :brokers(Array):: Identity of brokers for which to declare, defaults to all usable if nil or empty
    #
    # === Return
    # identities(Array):: Identity of brokers where successfully declared
    def declare(type, name, options = {})
      identities = []
      brokers = options.delete(:brokers)
      each_usable(brokers) { |b| identities << b.identity if b.declare(type, name, options) }
      logger.info("Could not declare #{type.to_s} #{name.inspect} on brokers #{each_usable(brokers).inspect} " +
                  "when selected #{brokers.inspect} from usable #{usable.inspect}") if identities.empty?
      identities
    end

    # Publish message to AMQP exchange of first connected broker
    #
    # === Parameters
    # exchange(Hash):: AMQP exchange to subscribe to with keys :type, :name, and :options,
    #   which are the standard AMQP ones plus
    #     :no_declare(Boolean):: Whether to skip declaring this exchange or queue on the broker
    #       to cause its creation; for use when client does not have create permission or
    #       knows the object already exists and wants to avoid declare overhead
    #     :declare(Boolean):: Whether to delete this exchange or queue from the AMQP cache
    #       to force it to be declared on the broker and thus be created if it does not exist
    # packet(Packet):: Message to serialize and publish
    # options(Hash):: Publish options -- standard AMQP ones plus
    #   :fanout(Boolean):: true means publish to all connected brokers
    #   :brokers(Array):: Identity of brokers selected for use, defaults to all home brokers
    #     if nil or empty
    #   :order(Symbol):: Broker selection order: :random or :priority,
    #     defaults to @select if :brokers is nil, otherwise defaults to :priority
    #   :no_serialize(Boolean):: Do not serialize packet because it is already serialized,
    #     this is an escape for special situations like enrollment, also implicitly disables
    #     publish logging; this option is implicitly invoked if initialize without a serializer
    #   :log_filter(Array(Symbol)):: Filters to be applied in to_s when logging packet to :info
    #   :log_data(String):: Additional data to display at end of log entry
    #   :no_log(Boolean):: Disable publish logging unless debug level
    #
    # === Return
    # identities(Array):: Identity of brokers where packet was successfully published
    #
    # === Raise
    # NoConnectedBrokers:: If cannot find a connected broker
    def publish(exchange, packet, options = {})
      identities = []
      no_serialize = options[:no_serialize] || @serializer.nil?
      message = if no_serialize then packet else @serializer.dump(packet) end
      brokers = use(options)
      brokers.each do |b|
        if b.publish(exchange, packet, message, options.merge(:no_serialize => no_serialize))
          identities << b.identity
          if options[:mandatory] && !no_serialize
            context = Context.new(packet, options, brokers.map { |b| b.identity })
            @published.store(message, context)
          end
          break unless options[:fanout]
        end
      end
      if identities.empty?
        selected = "selected " if options[:brokers]
        list = aliases(brokers.map { |b| b.identity }).join(", ")
        raise NoConnectedBrokers, "None of #{selected}brokers [#{list}] are usable for publishing"
      end
      identities
    end

    # Register callback to be activated when a broker returns a message that could not be delivered
    # A message published with :mandatory => true is returned if the exchange does not have any associated queues
    # or if all the associated queues do not have any consumers
    # A message published with :immediate => true is returned for the same reasons as :mandatory plus if all
    # of the queues associated with the exchange are not immediately ready to consume the message
    # Remove any previously registered callback
    #
    # === Block
    # Required block to be called when a message is returned with parameters
    #   identity(String):: Broker serialized identity
    #   reason(String):: Reason for return
    #     "NO_ROUTE" - queue does not exist
    #     "NO_CONSUMERS" - queue exists but it has no consumers, or if :immediate was specified,
    #       all consumers are not immediately ready to consume
    #     "ACCESS_REFUSED" - queue not usable because broker is in the process of stopping service
    #   message(String):: Returned serialized message
    #   to(String):: Queue to which message was published
    #   context(Context|nil):: Message publishing context, or nil if not available
    #
    # === Return
    # true:: Always return true
    def return_message(&blk)
      each_usable do |b|
        b.return_message do |to, reason, message|
          context = @published.fetch(message)
          context.record_failure(b.identity) if context
          blk.call(b.identity, reason, message, to, context)
        end
      end
      true
    end

    # Provide callback to be activated when a message cannot be delivered
    #
    # === Block
    # Required block with parameters
    #   reason(String):: Non-delivery reason
    #     "NO_ROUTE" - queue does not exist
    #     "NO_CONSUMERS" - queue exists but it has no consumers, or if :immediate was specified,
    #       all consumers are not immediately ready to consume
    #     "ACCESS_REFUSED" - queue not usable because broker is in the process of stopping service
    #   type(String|nil):: Request type, or nil if not applicable
    #   token(String|nil):: Generated message identifier, or nil if not applicable
    #   from(String|nil):: Identity of original sender of message, or nil if not applicable
    #   to(String):: Queue to which message was published
    #
    # === Return
    # true:: Always return true
    def non_delivery(&blk)
      @non_delivery = blk
      true
    end

    # Delete queue in all usable brokers or all selected brokers that are usable
    #
    # === Parameters
    # name(String):: Queue name
    # options(Hash):: Queue declare options plus
    #   :brokers(Array):: Identity of brokers in which queue is to be deleted
    #
    # === Return
    # identities(Array):: Identity of brokers where queue was deleted
    def delete(name, options = {})
      identities = []
      u = usable
      brokers = options.delete(:brokers)
      ((brokers || u) & u).each { |i| identities << i if (b = @brokers_hash[i]) && b.delete(name, options) }
      identities
    end

    # Delete queue resources from AMQP in all usable brokers
    #
    # === Parameters
    # name(String):: Queue name
    # options(Hash):: Queue declare options plus
    #   :brokers(Array):: Identity of brokers in which queue is to be deleted
    #
    # === Return
    # identities(Array):: Identity of brokers where queue was deleted
    def delete_amqp_resources(name, options = {})
      identities = []
      u = usable
      ((options[:brokers] || u) & u).each { |i| identities << i if (b = @brokers_hash[i]) && b.delete_amqp_resources(:queue, name) }
      identities
    end

    # Remove a broker client from the configuration
    # Invoke connection status callbacks only if connection is not already disabled
    # There is no check whether this is the last usable broker client
    #
    # === Parameters
    # host{String):: IP host name or address for individual broker
    # port(Integer):: TCP port number for individual broker
    #
    # === Block
    # Optional block with following parameters to be called after removing the connection
    # unless broker is not configured
    #   identity(String):: Broker serialized identity
    #
    # === Return
    # identity(String|nil):: Serialized identity of broker removed, or nil if unknown
    def remove(host, port, &blk)
      identity = self.class.identity(host, port)
      if broker = @brokers_hash[identity]
        logger.info("Removing #{identity}, alias #{broker.alias} from broker list")
        broker.close(propagate = true, normal = true, log = false)
        @brokers_hash.delete(identity)
        @brokers.reject! { |b| b.identity == identity }
        yield identity if block_given?
      else
        logger.info("Ignored request to remove #{identity} from broker list because unknown")
        identity = nil
      end
      identity
    end

    # Declare a broker client as unusable
    #
    # === Parameters
    # identities(Array):: Identity of brokers
    #
    # === Return
    # true:: Always return true
    #
    # === Raises
    # Exception:: If identified broker is unknown
    def declare_unusable(identities)
      identities.each do |id|
        broker = @brokers_hash[id]
        raise Exception, "Cannot mark unknown broker #{id} unusable" unless broker
        broker.close(propagate = true, normal = false, log = false)
      end
    end

    # Close all broker client connections
    #
    # === Block
    # Optional block with no parameters to be called after all connections are closed
    #
    # === Return
    # true:: Always return true
    def close(&blk)
      if @closed
        blk.call if blk
      else
        @closed = true
        @connection_status = {}
        handler = CountedDeferrable.new(@brokers.size)
        handler.callback { blk.call if blk }
        @brokers.each do |b|
          begin
            b.close(propagate = false) { handler.completed_one }
          rescue Exception => e
            handler.completed_one
            logger.exception("Failed to close broker #{b.alias}", e, :trace)
            @exceptions.track("close", e)
          end
        end
      end
      true
    end

    # Close an individual broker client connection
    #
    # === Parameters
    # identity(String):: Broker serialized identity
    # propagate(Boolean):: Whether to propagate connection status updates
    #
    # === Block
    # Optional block with no parameters to be called after connection closed
    #
    # === Return
    # true:: Always return true
    #
    # === Raise
    # Exception:: If broker unknown
    def close_one(identity, propagate = true, &blk)
      broker = @brokers_hash[identity]
      raise Exception, "Cannot close unknown broker #{identity}" unless broker
      broker.close(propagate, &blk)
      true
    end

    # Register callback to be activated when there is a change in connection status
    # Can be called more than once without affecting previous callbacks
    #
    # === Parameters
    # options(Hash):: Connection status monitoring options
    #   :one_off(Integer):: Seconds to wait for status change; only send update once;
    #     if timeout, report :timeout as the status
    #   :boundary(Symbol):: :any if only report change on any (0/1) boundary,
    #     :all if only report change on all (n-1/n) boundary, defaults to :any
    #   :brokers(Array):: Only report a status change for these identified brokers
    #
    # === Block
    # Required block activated when connected count crosses a status boundary with following parameters
    #   status(Symbol):: Status of connection: :connected, :disconnected, or :failed, with
    #     :failed indicating that all selected brokers or all brokers have failed
    #
    # === Return
    # id(String):: Identifier associated with connection status request
    def connection_status(options = {}, &callback)
      id = generate_id
      @connection_status[id] = {:boundary => options[:boundary], :brokers => options[:brokers], :callback => callback}
      if timeout = options[:one_off]
        @connection_status[id][:timer] = EM::Timer.new(timeout) do
          if @connection_status[id]
            if @connection_status[id][:callback].arity == 2
              @connection_status[id][:callback].call(:timeout, nil)
            else
              @connection_status[id][:callback].call(:timeout)
            end
            @connection_status.delete(id)
          end
        end
      end
      id
    end

    # Get status summary
    #
    # === Return
    # (Array(Hash)):: Status of each configured broker with keys
    #   :identity(String):: Broker serialized identity
    #   :alias(String):: Broker alias used in logs
    #   :status(Symbol):: Status of connection
    #   :disconnects(Integer):: Number of times lost connection
    #   :failures(Integer):: Number of times connect failed
    #   :retries(Integer):: Number of attempts to connect after failure
    def status
      @brokers.map { |b| b.summary }
    end

    # Get broker client statistics
    #
    # === Parameters:
    # reset(Boolean):: Whether to reset the statistics after getting the current ones
    #
    # === Return
    # stats(Hash):: Broker client stats with keys
    #   "brokers"(Array):: Stats for each broker client in priority order
    #   "exceptions"(Hash|nil):: Exceptions raised per category, or nil if none
    #     "total"(Integer):: Total exceptions for this category
    #     "recent"(Array):: Most recent as a hash of "count", "type", "message", "when", and "where"
    #   "heartbeat"(Integer|nil):: Number of seconds between AMQP heartbeats, or nil if heartbeat disabled
    #   "returns"(Hash|nil):: Message return activity stats with keys "total", "percent", "last", and "rate"
    #     with percentage breakdown per return reason, or nil if none
    def stats(reset = false)
      stats = {
        "brokers"    => @brokers.map { |b| b.stats },
        "exceptions" => @exceptions.stats,
        "heartbeat"  => @options[:heartbeat],
        "returns"    => @returns.all
      }
      reset_stats if reset
      stats
    end

    # Reset broker client statistics
    # Do not reset disconnect and failure stats because they might then be
    # inconsistent with underlying connection status
    #
    # === Return
    # true:: Always return true
    def reset_stats
      @returns = RightSupport::Stats::Activity.new
      @exceptions = RightSupport::Stats::Exceptions.new(self, @options[:exception_callback])
      true
    end

    protected

    # Connect to all configured brokers
    #
    # === Return
    # (Array):: Broker clients created
    def connect_all
      self.class.addresses(@options[:host], @options[:port]).map do |a|
        identity = self.class.identity(a[:host], a[:port])
        BrokerClient.new(identity, a, @serializer, @exceptions, @options, nil)
      end
    end

    # Determine priority of broker
    # If broker not found, assign next available priority
    #
    # === Parameters
    # identity(String):: Broker identity
    #
    # === Return
    # (Integer):: Priority position of broker
    def priority(identity)
      priority = 0
      @brokers.each do |b|
        break if b.identity == identity
        priority += 1
      end
      priority
    end

    # Generate unique identity
    #
    # === Return
    # (String):: Random 128-bit hexadecimal string
    def generate_id
      bytes = ''
      16.times { bytes << rand(0xff) }
      # Transform into hex string
      bytes.unpack('H*')[0]
    end

    # Iterate over clients that are usable, i.e., connecting or confirmed connected
    #
    # === Parameters
    # identities(Array):: Identity of brokers to be considered, nil or empty array means all brokers
    #
    # === Block
    # Optional block with following parameters to be called for each usable broker client
    #   broker(BrokerClient):: Broker client
    #
    # === Return
    # (Array):: Usable broker clients
    def each_usable(identities = nil)
      choices = if identities && !identities.empty?
        choices = identities.inject([]) { |c, i| if b = @brokers_hash[i] then c << b else c end }
      else
        @brokers
      end
      choices.select do |b|
        if b.usable?
          yield(b) if block_given?
          true
        end
      end
    end

    # Select the broker clients to be used in the desired order
    #
    # === Parameters
    # options(Hash):: Selection options:
    #   :brokers(Array):: Identity of brokers selected for use, defaults to all home brokers if nil or empty
    #   :order(Symbol):: Broker selection order: :random or :priority,
    #     defaults to @select if :brokers is nil, otherwise defaults to :priority
    #
    # === Return
    # (Array):: Allowed BrokerClients in the order to be used
    def use(options)
      choices = []
      select = options[:order]
      if options[:brokers] && !options[:brokers].empty?
        options[:brokers].each do |identity|
          if choice = @brokers_hash[identity]
            choices << choice
          else
            logger.exception("Invalid broker identity #{identity.inspect}, check server configuration")
          end
        end
      else
        choices = @brokers
        select ||= @select
      end
      if select == :random
        choices.sort_by { rand }
      else
        choices
      end
    end
 
    # Callback from broker client with connection status update
    # Makes client callback with :connected or :disconnected status if boundary crossed,
    # or with :failed if all selected brokers or all brokers have failed
    #
    # === Parameters
    # broker(BrokerClient):: Broker client reporting status update
    # connected_before(Boolean):: Whether client was connected before this update
    #
    # === Return
    # true:: Always return true
    def update_status(broker, connected_before)
      after = connected
      before = after.clone
      before.delete(broker.identity) if broker.connected? && !connected_before
      before.push(broker.identity) if !broker.connected? && connected_before
      unless before == after
        logger.info("[status] Broker #{broker.alias} is now #{broker.status}, " +
                    "connected brokers: [#{aliases(after).join(", ")}]")
      end
      @connection_status.reject! do |k, v|
        reject = false
        if v[:brokers].nil? || v[:brokers].include?(broker.identity)
          b, a, n, f = if v[:brokers].nil?
            [before, after, @brokers.size, all]
          else
            [before & v[:brokers], after & v[:brokers], v[:brokers].size, v[:brokers]]
          end
          update = if v[:boundary] == :all
            if b.size < n && a.size == n
              :connected
            elsif b.size == n && a.size < n
              :disconnected
            elsif (f - failed).empty?
              :failed
            end
          else
            if b.size == 0 && a.size > 0
              :connected
            elsif b.size > 0 && a.size == 0
              :disconnected
            elsif (f - failed).empty?
              :failed
            end
          end
          if update
            v[:callback].call(update)
            if v[:timer]
              v[:timer].cancel
              reject = true
            end
          end
        end
        reject
      end
      true
    end

    # Handle message returned by broker because it could not deliver it
    # If agent still active, resend using another broker
    # If this is last usable broker and persistent is enabled, allow message to be queued
    # on next send even if the queue has no consumers so there is a chance of message
    # eventually being delivered
    # If persistent or one-way request and all usable brokers have failed, try one more time
    # without mandatory flag to give message opportunity to be queued
    # If there are no more usable broker clients, send non-delivery message to original sender
    #
    # === Parameters
    # identity(String):: Identity of broker that could not deliver message
    # reason(String):: Reason for return
    #   "NO_ROUTE" - queue does not exist
    #   "NO_CONSUMERS" - queue exists but it has no consumers, or if :immediate was specified,
    #     all consumers are not immediately ready to consume
    #   "ACCESS_REFUSED" - queue not usable because broker is in the process of stopping service
    # message(String):: Returned message in serialized packet format
    # to(String):: Queue to which message was published
    # context(Context):: Message publishing context
    #
    # === Return
    # true:: Always return true
    def handle_return(identity, reason, message, to, context)
      @brokers_hash[identity].update_status(:stopping) if reason == "ACCESS_REFUSED"

      if context
        @returns.update("#{alias_(identity)} (#{reason.to_s.downcase})")
        name = context.name
        options = context.options || {}
        token = context.token
        one_way = context.one_way
        persistent = options[:persistent]
        mandatory = true
        remaining = (context.brokers - context.failed) & connected
        logger.info("RETURN reason #{reason} token <#{token}> to #{to} from #{context.from} brokers #{context.brokers.inspect} " +
                    "failed #{context.failed.inspect} remaining #{remaining.inspect} connected #{connected.inspect}")
        if remaining.empty?
          if (persistent || one_way) &&
             ["ACCESS_REFUSED", "NO_CONSUMERS"].include?(reason) &&
             !(remaining = context.brokers & connected).empty?
            # Retry because persistent, and this time w/o mandatory so that gets queued even though no consumers
            mandatory = false
          else
            t = token ? " <#{token}>" : ""
            logger.info("NO ROUTE #{aliases(context.brokers).join(", ")} [#{name}]#{t} to #{to}")
            @non_delivery.call(reason, context.type, token, context.from, to) if @non_delivery
          end
        end

        unless remaining.empty?
          t = token ? " <#{token}>" : ""
          p = persistent ? ", persistent" : ""
          m = mandatory ? ", mandatory" : ""
          logger.info("RE-ROUTE #{aliases(remaining).join(", ")} [#{context.name}]#{t} to #{to}#{p}#{m}")
          exchange = {:type => :queue, :name => to, :options => {:no_declare => true}}
          publish(exchange, message, options.merge(:no_serialize => true, :brokers => remaining,
                                                   :persistent => persistent, :mandatory => mandatory))
        end
      else
        @returns.update("#{alias_(identity)} (#{reason.to_s.downcase} - missing context)")
        logger.info("Dropping message returned from broker #{identity} for reason #{reason} " +
                    "because no message context available for re-routing it to #{to}")
      end
      true
    rescue Exception => e
      logger.exception("Failed to handle #{reason} return from #{identity} for message being routed to #{to}", e, :trace)
      @exceptions.track("return", e)
    end

    # Helper for deferring block execution until specified number of actions have completed
    # or timeout occurs
    class CountedDeferrable

      include EM::Deferrable

      # Defer action until completion count reached or timeout occurs
      #
      # === Parameter
      # count(Integer):: Number of completions required for action
      # timeout(Integer|nil):: Number of seconds to wait for all completions and if
      #   reached, proceed with action; nil means no timing
      def initialize(count, timeout = nil)
        @timer = EM::Timer.new(timeout) { succeed } if timeout
        @count = count
      end

      # Completed one part of task
      #
      # === Return
      # true:: Always return true
      def completed_one
        if (@count -= 1) == 0
          @timer.cancel if @timer
          succeed
        end
        true
      end

    end # CountedDeferrable
 
    # Cache for context of recently published messages for use with message returns
    # Applies LRU for managing cache size but only deletes entries when old enough
    class Published

      # Number of seconds since a cache entry was last used before it is deleted
      MAX_AGE = 60

      # Initialize cache
      def initialize
        @cache = {}
        @lru = []
      end

      # Store message context in cache
      #
      # === Parameters
      # message(String):: Serialized message that was published
      # context(Context):: Message publishing context
      #
      # === Return
      # true:: Always return true
      def store(message, context)
        key = identify(message)
        now = Time.now.to_i
        if entry = @cache[key]
          entry[0] = now
          @lru.push(@lru.delete(key))
        else
          @cache[key] = [now, context]
          @lru.push(key)
          @cache.delete(@lru.shift) while (now - @cache[@lru.first][0]) > MAX_AGE
        end
        true
      end

      # Fetch context of previously published message
      #
      # === Parameters
      # message(String):: Serialized message that was published
      #
      # === Return
      # (Context|nil):: Context of message, or nil if not found in cache
      def fetch(message)
        key = identify(message)
        if entry = @cache[key]
          entry[0] = Time.now.to_i
          @lru.push(@lru.delete(key))
          entry[1]
        end
      end

      # Obtain a unique identifier for this message
      #
      # === Parameters
      # message(String):: Serialized message that was published
      #
      # === Returns
      # (String):: Unique id for message
      def identify(message)
        Digest::MD5.hexdigest(message)
      end

    end # Published

  end # HABrokerClient

end # RightAMQP
