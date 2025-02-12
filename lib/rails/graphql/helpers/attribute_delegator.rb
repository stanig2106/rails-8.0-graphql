# frozen_string_literal: true

module Rails
  module GraphQL
    module Helpers
      # This is an extra magic on top of the delegator class from the standard
      # lib that allows fetching a specific property of the delegated object
      class AttributeDelegator < GraphQL::ProxyObject
        def initialize(obj = nil, attribute = nil, cache: true, &block)
          @delegate_sd_attr = attribute
          @delegate_sd_obj = block.presence || obj
          @delegate_cache = cache
        end

        private

          def respond_to_missing?(method_name, include_private = false)
            __getobj__.respond_to?(method_name, include_private) || super
          end

          def method_missing(method_name, *args, **xargs, &block)
            return super unless __getobj__.respond_to?(method_name)
            __getobj__.public_send(method_name, *args, **xargs, &block)
          end

          def __getobj__
            @delegate_cache ? (@delegate_ch_obj ||= __buildobj__) : __buildobj__
          end

          def __buildobj__
            result = @delegate_sd_obj
            result = result.call if result.respond_to?(:call)
            result = result&.public_send(@delegate_sd_attr) if @delegate_sd_attr
            result
          end
      end
    end
  end
end
