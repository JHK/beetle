module Beetle
  class Client
    attr_reader :servers, :exchanges, :queues, :messages

    def initialize(options = {})
      @servers = (options[:servers] || Beetle.config.servers).split(/ *, */)
      @exchanges = {}
      @queues = {}
      @messages = {}
      @options = options
    end

    # type: "topic"
    # durable: true

    def register_exchange(name, opts={})
      raise ConfigurationError.new("exchange #{name} already configured") if exchanges.include?(name)
      exchanges[name] = opts.symbolize_keys.merge(:type => :topic, :durable => true)
    end

    # passive: false       # amqp default is false
    # durable: true        # amqp default is false
    # exclusive: false     # amqp default is false
    # auto_delete: false   # amqp default is false
    # nowait: true         # amqp default is true
    # key: "#"             # listen to every message

    def register_queue(name, opts={})
      raise ConfigurationError.new("queue #{name} already configured") if queues.include?(name)
      opts = {:exchange => name}.merge!(opts.symbolize_keys)
      opts.merge! :durable => true, :passive => false
      queues[name] = opts
      exchange = opts[:exchange]
      register_exchange(exchange) unless exchanges.include?(exchange)
      (exchanges[opts[:exchange]][:queues] ||= []) << name
    end

    # queue: "test"
    ### Spefify the queue for listeners (default is message name)
    # key: "test"
    ### Specifies the routing key pattern for message subscription.
    # ttl: <%= 1.hour %>
    ### Specifies the time interval after which messages are silently dropped (seconds)
    # mandatory: true
    ### default is false
    ### Tells the server how to react if the message
    ### cannot be routed to a queue. If set to _true_, the server will return an unroutable message
    ### with a Return method. If this flag is zero, the server silently drops the message.
    # immediate: false
    ### default is false
    ### Tells the server how to react if the message
    ### cannot be routed to a queue consumer immediately. If set to _true_, the server will return an
    ### undeliverable message with a Return method. If set to _false_, the server will queue the message,
    ### but with no guarantee that it will ever be consumed.
    # persistent: true
    ### default is false
    ### Tells the server whether to persist the message
    ### If set to _true_, the message will be persisted to disk and not lost if the server restarts.
    ### If set to _false_, the message will not be persisted across server restart. Setting to _true_
    ### incurs a performance penalty as there is an extra cost associated with disk access.

    def register_message(name, opts={})
      raise ConfigurationError.new("message #{name} already configured") if messages.include?(name)
      opts = {:queue => name}.merge!(opts.symbolize_keys)
      opts[:exchange] = queues[opts[:queue]][:exchange]
      messages[name] = opts
    end

    def register_handler(*args, &block)
      subscriber.register_handler(*args, &block)
    end

    def publish(message_name, data, opts={})
      publisher.publish(message_name, data, opts)
    end

    def purge(queue_name)
      publisher.purge(queue_name)
    end

    def listen(*args, &block)
      subscriber.listen(*args, &block)
    end

    def stop_listening
      subscriber.stop!
    end

    def stop_publishing
      publisher.stop
    end

    def trace
      subscriber.trace = true
      register_handler(messages.keys, :ack => true, :key => '#') do |msg|
        puts "-----===== new message =====-----"
        puts "SERVER: #{msg.server}"
        puts "HEADER: #{msg.header.inspect}"
        puts "UUID: #{msg.uuid}" if msg.uuid
        puts "DATA: #{msg.data}"
      end
      subscriber.listen
    end

    def load(glob)
      b = binding
      Dir[glob].each do |f|
        eval(File.read(f), b, f)
      end
    end

    def logger
      @logger ||= Beetle.config.logger
    end

    private

    def publisher
      @publisher ||= Publisher.new(self)
    end

    def subscriber
      @subscriber ||= Subscriber.new(self)
    end
  end
end
