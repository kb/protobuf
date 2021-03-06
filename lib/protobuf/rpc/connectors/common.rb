module Protobuf
  module Rpc 
    module Connectors
      module Common 
        
        attr_reader :error

        def any_callbacks?
          return [@complete_cb, @failure_cb, @success_cb].inject(false) do |reduction, cb|
            reduction = (reduction || !cb.nil?)
          end
        end

        def complete
          @stats.end
          @stats.log_stats
          log_debug "[#{log_signature}] Response proceessing complete"
          @complete_cb.call(self) unless @complete_cb.nil?
        rescue
          log_error "[#{log_signature}] Complete callback error encountered: %s" % $!.message
          log_error "[#{log_signature}] %s" % $!.backtrace.join("\n")
          raise
        end

        def data_callback(data)
          log_debug "[#{log_signature}] Using data_callback"
          @used_data_callback = true
          @data = data
        end

        def fail(code, message)
          @error =  ClientError.new
          @error.code = code.is_a?(Symbol) ? Protobuf::Socketrpc::ErrorReason.values[code] : code
          @error.message = message
          log_debug "[#{log_signature}] Server failed request (invoking on_failure): %s" % @error.inspect
          
          @failure_cb.call(@error) unless @failure_cb.nil?
        rescue
          log_error "[#{log_signature}] Failure callback error encountered: %s" % $!.message
          log_error "[#{log_signature}] %s" % $!.backtrace.join("\n")
          raise
        ensure
          complete
        end

        def initialize_stats
          @stats = Protobuf::Rpc::Stat.new(:CLIENT, true)
          @stats.server = [@options[:port], @options[:host]]
          @stats.service = @options[:service].name
          @stats.method = @options[:method]
          self
        rescue => ex
          fail(:RPC_ERROR, "Invalid stats configuration. #{ex.message}") 
        end

        def log_signature
          @log_signature ||= "client-#{self.class}"
        end

        def parse_response
          # Close up the connection as we no longer need it
          close_connection

          log_debug "[#{log_signature}] Parsing response from server (connection closed)"
          @stats.response_size = @buffer.size

          # Parse out the raw response
          response_wrapper = Protobuf::Socketrpc::Response.new
          response_wrapper.parse_from_string(@buffer.data)

          # Determine success or failure based on parsed data
          if response_wrapper.has_field?(:error_reason)
            log_debug "[#{log_signature}] Error response parsed"

            # fail the call if we already know the client is failed
            # (don't try to parse out the response payload)
            fail(response_wrapper.error_reason, response_wrapper.error)
          else
            log_debug "[#{log_signature}] Successful response parsed"

            # Ensure client_response is an instance
            response_type = @options[:response_type].new
            parsed = response_type.parse_from_string(response_wrapper.response_proto.to_s)

            if parsed.nil? and not response_wrapper.has_field?(:error_reason)
              fail(:BAD_RESPONSE_PROTO, 'Unable to parse response from server')
            else
              verify_callbacks
              succeed(parsed)
              return @data if @used_data_callback
            end
          end
        end

        # Setup the read buffer for data coming back
        def post_init
          # Setup an object for reponses without callbacks
          @data = nil
          log_debug "[#{log_signature}] Post init, new read buffer created"
          @buffer = Protobuf::Rpc::Buffer.new(:read)
          _send_request unless error?
          log_debug "[#{log_signature}] Post init, new read buffer created just sent"
        rescue
          fail(:RPC_ERROR, 'Connection error: %s' % $!.message)
        end

        # Sends the request to the server, invoked by the connection_completed event
        def _send_request
          request_wrapper = Protobuf::Socketrpc::Request.new
          request_wrapper.service_name = @options[:service].name
          request_wrapper.method_name = @options[:method].to_s

          if @options[:request].class == @options[:request_type]
            request_wrapper.request_proto = @options[:request].serialize_to_string
          else
            expected = @options[:request_type].name
            actual = @options[:request].class.name
            fail :INVALID_REQUEST_PROTO, 'Expected request type to be type of %s, got %s instead' % [expected, actual]
          end

          log_debug "[#{log_signature}] Sending Request: %s" % request_wrapper.inspect
          request_buffer = Protobuf::Rpc::Buffer.new(:write, request_wrapper)
          @stats.request_size = request_buffer.size
          send_data(request_buffer.write)
        end

        def succeed(response)
          log_debug "[#{log_signature}] Server succeeded request (invoking on_success)"
          @success_cb.call(response) unless @success_cb.nil?
        rescue
          log_error "[#{log_signature}] Success callback error encountered: %s" % $!.message
          log_error "[#{log_signature}] %s" % $!.backtrace.join("\n")
          fail :RPC_ERROR, 'An exception occurred while calling on_success: %s' % $!.message
        ensure 
          complete
        end

        def verify_callbacks
          if !any_callbacks?
            log_debug "[#{log_signature}] No callbacks set, using data_callback"
            @success_cb = @failure_cb = self.method(:data_callback)
          end
        end

        def verify_options
          # Verify the options that are necessary and merge them in
          [:service, :method, :host, :port].each do |opt|
            fail(:RPC_ERROR, "Invalid client connection configuration. #{opt} must be a defined option.") if @options[opt].nil?
          end
        end

      end
    end
  end
end
