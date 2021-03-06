require 'forwardable'
require 'protobuf'
require 'protobuf/common/logger'
require 'protobuf/rpc/error'
require 'protobuf/rpc/connector'

module Protobuf
  module Rpc
    class Client
      extend Forwardable
      include Protobuf::Logger::LogMethods
      
      delegate [:options, :complete_cb, :success_cb, :failure_cb, :async?] => :@connector
      attr_reader :connector
      
      # Create a new client with default options (defined in ClientConnection)
      # See Service#client for a more convenient way to create a client, as well
      # as Client#method_missing defined below.
      # 
      #   request = WidgetFindRequest.new
      #   client = Client.new({
      #     :service => WidgetService,
      #     :method => "find",
      #     :request_type => "WidgetFindRequest",
      #     :response_type => "WidgetList",
      #     :request => request
      #   })
      #
      def initialize(opts={})
        raise "Invalid client configuration. Service must be defined." if opts[:service].nil?
        @connector = Connector.connector_for_client.new(opts)
        log_debug "[#{log_signature}] Initialized with options: %s" % opts.inspect
      end

      def log_signature
        @log_signature ||= "client-#{self.class}"
      end
      
      # Set a complete callback on the client to return the object (self). 
      # Callback is called regardless of :async setting.
      # 
      #   client = Client.new(:service => WidgetService)
      #   client.on_complete {|obj| ... }
      # 
      def on_complete(&complete_cb)
        @connector.complete_cb = complete_cb 
      end

      def on_complete=(callable)
        if callable != nil && !callable.respond_to?(:call) && callable.arity != 1
          raise "callable must take a single argument and respond to :call"
        end
        
        @connector.complete_cb = callable 
      end
      
      # Set a failure callback on the client to return the
      # error returned by the service, if any. If this callback
      # is called, success_cb will NOT be called.
      # Callback is called regardless of :async setting.
      # 
      #   client = Client.new(:service => WidgetService)
      #   client.on_failure {|err| ... }
      # 
      def on_failure(&failure_cb)
        @connector.failure_cb = failure_cb
      end

      def on_failure=(callable)
        if callable != nil && !callable.respond_to?(:call) && callable.arity != 1
          raise "callable must take a single argument and respond to :call"
        end

        @connector.failure_cb = callable 
      end
      
      # Set a success callback on the client to return the
      # successful response from the service when it is returned.
      # If this callback is called, failure_cb will NOT be called.
      # Callback is called regardless of :async setting.
      # 
      #   client = Client.new(:service => WidgetService)
      #   client.on_success {|res| ... }
      # 
      def on_success(&success_cb)
        @connector.success_cb = success_cb
      end

      def on_success=(callable)
        if callable != nil && !callable.respond_to?(:call) && callable.arity != 1
          raise "callable must take a single argument and respond to :call"
        end

        @connector.success_cb = callable 
      end
      
      # Provides a mechanism to call the service method against the client
      # which will automatically setup the service_class and method_name
      # in the wrapper protobuf request.
      #
      #   # The :find method is not defined by Client which will trigger method_missing
      #   Client.new(:service => WidgetService).find do |c|
      #     # This block will be invoked before the request is made
      #     # `c` in this case is the client object you created above
      #     c.on_success {|res| ... }
      #     c.on_failure {|err| ... }
      #   end
      # 
      def method_missing(method, *params)
        service = options[:service]
        unless service.rpcs[service].keys.include?(method)
          log_error "[#{log_signature}] %s#%s not rpc method, passing to super" % [service.name, method.to_s]
          super(method, *params)
        else
          log_debug "[#{log_signature}] %s#%s" % [service.name, method.to_s]
          rpc = service.rpcs[service][method.to_sym]
          options[:request_type] = rpc.request_type
          log_debug "[#{log_signature}] Request Type: %s" % options[:request_type].name
          options[:response_type] = rpc.response_type
          log_debug "[#{log_signature}] Response Type: %s" % options[:response_type].name
          options[:method] = method.to_s
          options[:request] = params[0].is_a?(Hash) ? options[:request_type].new(params[0]) : params[0]
          log_debug "[#{log_signature}] Request Data: %s" % options[:request].inspect
          
          # Call client to setup on_success and on_failure event callbacks
          if block_given?
            log_debug "[#{log_signature}] client setup callback given, invoking"
            yield(self)
          else
            log_debug "[#{log_signature}] no block given for callbacks"
          end
      
          send_request
        end
      end
      
      # Send the request to the service through eventmachine.
      # This method is usually never called directly
      # but is invoked by method_missing (see docs above).
      #
      #   request = WidgetFindRequest.new
      #   client = Client.new({
      #     :service => WidgetService,
      #     :method => "find",
      #     :request_type => "WidgetFindRequest",
      #     :response_type => "WidgetList",
      #     :request => request
      #   })
      # 
      #   client.on_success do |res|
      #     res.widgets.each{|w| puts w.inspect }
      #   end
      #
      #   client.on_failure do |err|
      #     puts err.message
      #   end
      # 
      #   client.send_request
      #
      def send_request
        @connector.send_request
      end
      
    end
  end
end
