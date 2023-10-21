require "net/http"

module Noticed
  module DeliveryMethods
    class Base < Noticed.parent_class.constantize
      extend ActiveModel::Callbacks
      define_model_callbacks :deliver

      class_attribute :option_names, instance_writer: false, default: []

      attr_reader :notification, :options, :params, :recipient, :record, :logger

      class << self
        # Copy option names from parent
        def inherited(base) # :nodoc:
          base.option_names = option_names.dup
          super
        end

        def options(*names)
          option_names.concat Array.wrap(names)
        end
        alias_method :option, :options

        def validate!(delivery_method_options)
          option_names.each do |option_name|
            unless delivery_method_options.key? option_name
              raise ValidationError, "option `#{option_name}` must be set for #{name}"
            end
          end
        end
      end

      def assign_args(args)
        @notification = args.fetch(:notification_class).constantize.new(args[:params])
        @options = args[:options] || {}
        @params = args[:params]
        @recipient = args[:recipient]
        @record = args[:record]

        # Set the default logger
        @logger = @options.fetch(:logger, Rails.logger)

        # Make notification aware of database record and recipient during delivery
        @notification.record = args[:record]
        @notification.recipient = args[:recipient]
        self
      end

      def perform(args)
        assign_args(args)

        return if (condition = @options[:if]) && !@notification.send(condition)
        return if (condition = @options[:unless]) && @notification.send(condition)

        run_callbacks :deliver do
          deliver
        end
      end

      def deliver
        raise NotImplementedError, "Delivery methods must implement a deliver method"
      end

      private

      # Helper method for making POST requests from delivery methods
      #
      # Usage:
      #   post("http://example.com", basic_auth: {user:, pass:}, headers: {}, json: {}, form: {})
      #
      def post(url, args = {})
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if uri.instance_of? URI::HTTPS

        request = Net::HTTP::Post.new(uri.request_uri, args.delete(:headers))

        if (basic_auth = args.delete(:basic_auth))
          request.basic_auth basic_auth.fetch(:user), basic_auth.fetch(:pass)
        end

        if (json = args.delete(:json))
          request.body = json.to_json
        elsif (form = args.delete(:form))
          request.set_form(form, "multipart/form-data")
        end

        response = http.request(request)

        if options[:debug]
          logger.debug("POST #{url}")
          logger.debug("Response: #{response.code}: #{response.body}")
        end

        if !options[:ignore_failure] && !response.code.start_with?("20")
          logger.debug response.code
          logger.debug response.body
          raise ResponseUnsuccessful.new(response)
        end

        response
      end
    end
  end
end
