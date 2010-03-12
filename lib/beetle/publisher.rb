module Beetle
  # Provides the publishing logic implementation.
  class Publisher < Base

    def initialize(client, options = {}) #:nodoc:
      super
      @dead_servers = {}
      @bunnies = {}
    end

    def publish(message_name, data, opts={}) #:nodoc:
      opts = @client.messages[message_name].merge(opts.symbolize_keys)
      exchange_name = opts.delete(:exchange)
      opts.delete(:queue)
      recycle_dead_servers unless @dead_servers.empty?
      if opts[:redundant]
        publish_with_redundancy(exchange_name, message_name, data, opts)
      else
        publish_with_failover(exchange_name, message_name, data, opts)
      end
    end

    def publish_with_failover(exchange_name, message_name, data, opts) #:nodoc:
      tries = @servers.size
      logger.debug "Beetle: sending #{message_name}"
      published = 0
      opts = Message.publishing_options(opts)
      begin
        select_next_server
        bind_queues_for_exchange(exchange_name)
        logger.debug "Beetle: trying to send #{message_name} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        published = 1
      rescue Bunny::ServerDownError, Bunny::ConnectionError
        stop!
        mark_server_dead
        tries -= 1
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
      end
      published
    end

    def publish_with_redundancy(exchange_name, message_name, data, opts) #:nodoc:
      if @servers.size < 2
        logger.error "Beetle: at least two active servers are required for redundant publishing"
        return publish_with_failover(exchange_name, message_name, data, opts)
      end
      published = []
      opts = Message.publishing_options(opts)
      loop do
        break if published.size == 2 || @servers.empty? || published == @servers
        begin
          select_next_server
          next if published.include? @server
          bind_queues_for_exchange(exchange_name)
          logger.debug "Beetle: trying to send #{message_name} to #{@server}"
          exchange(exchange_name).publish(data, opts)
          published << @server
          logger.debug "Beetle: message sent (#{published})!"
        rescue Bunny::ServerDownError, Bunny::ConnectionError
          stop!
          mark_server_dead
        end
      end
      case published.size
      when 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
      when 1
        logger.warn "Beetle: failed to send message redundantly"
      end
      published.size
    end

    RPC_DEFAULT_TIMEOUT = 10 #:nodoc:

    def rpc(message_name, data, opts={}) #:nodoc:
      opts = @client.messages[message_name].merge(opts.symbolize_keys)
      exchange_name = opts.delete(:exchange)
      opts.delete(:queue)
      recycle_dead_servers unless @dead_servers.empty?
      tries = @servers.size
      logger.debug "Beetle: rpc #{message_name}"
      result = nil
      status = "TIMEOUT"
      begin
        select_next_server
        bind_queues_for_exchange(exchange_name)
        # create non durable, autodeleted temporary queue with a server assigned name
        queue = bunny.queue
        opts = Message.publishing_options(opts.merge :reply_to => queue.name)
        logger.debug "Beetle: trying to send #{message_name} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        queue.subscribe(:message_max => 1, :timeout => opts[:timeout] || RPC_DEFAULT_TIMEOUT) do |msg|
          logger.debug "Beetle: received reply!"
          result = msg[:payload]
          status = msg[:header].properties[:headers][:status]
        end
        logger.debug "Beetle: rpc complete!"
      rescue Bunny::ServerDownError, Bunny::ConnectionError
        stop!
        mark_server_dead
        tries -= 1
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
      end
      [status, result]
    end

    def purge(queue_name) #:nodoc:
      each_server do
        queue(queue_name).purge
      end
    end

    def stop #:nodoc:
      each_server { stop! }
    end

    private

    def bunny
      @bunnies[@server] ||= new_bunny
    end

    def new_bunny
      b = Bunny.new(:host => current_host, :port => current_port, :logging => !!@options[:logging])
      b.start
      b
    end

    def recycle_dead_servers
      recycle = []
      @dead_servers.each do |s, dead_since|
        recycle << s if dead_since < 10.seconds.ago
      end
      @servers.concat recycle
      recycle.each {|s| @dead_servers.delete(s)}
    end

    def mark_server_dead
      logger.info "Beetle: server #{@server} down: #{$!}"
      @dead_servers[@server] = Time.now
      @servers.delete @server
      @server = @servers[rand @servers.size]
    end

    def select_next_server
      return logger.error("Beetle: message could not be delivered: #{message_name} - no server available") && 0 if @servers.empty?
      set_current_server(@servers[((@servers.index(@server) || 0)+1) % @servers.size])
    end

    def create_exchange!(name, opts)
      bunny.exchange(name, opts)
    end

    def bind_queues_for_exchange(exchange_name)
      @client.exchanges[exchange_name][:queues].each {|q| queue(q) } if queues.empty?
    end

    # TODO: Refactor, fethch the keys and stuff itself
    def bind_queue!(queue_name, creation_keys, exchange_name, binding_keys)
      logger.debug("Creating queue with opts: #{creation_keys.inspect}")
      queue = bunny.queue(queue_name, creation_keys)
      logger.debug("Binding queue #{queue_name} to #{exchange_name} with opts: #{binding_keys.inspect}")
      queue.bind(exchange(exchange_name), binding_keys)
      queue
    end

    def stop!
      begin
        bunny.stop
      rescue Exception
        Beetle::reraise_expectation_errors!
      ensure
        @bunnies[@server] = nil
        @exchanges[@server] = {}
        @queues[@server] = {}
      end
    end
  end
end
