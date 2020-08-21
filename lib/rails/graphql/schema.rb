# frozen_string_literal: true

module Rails # :nodoc:
  module GraphQL # :nodoc:
    # = GraphQL Schema
    #
    # This is a pure representation of a GraphQL schema.
    # See: http://spec.graphql.org/June2018/#SchemaDefinition
    #
    # In addition to the spec implementation, this also allows separation by
    # namespaces, where each schema is associated with one and only one
    # namespace, guiding requests and types searching.
    #
    # This class works similary to the {TypeMap}[rdoc-ref:Rails::base_classMap]
    # class, where its purpose is to know which QueryFields, Mutations, and
    # Subscriptions are available. The main difference is that it doesn't hold
    # namespace-based objects, since each schema is associated to a single
    # namespace.
    class Schema
      extend Helpers::WithSchemaFields
      extend Helpers::WithDirectives
      extend GraphQL::Introspection

      include ActiveSupport::Rescuable
      include GraphQL::Core

      # The namespace associated with the schema
      class_attribute :namespace, instance_writer: false, default: :base

      # The given description of the schema
      class_attribute :description, instance_writer: false

      # The purpose of instantiating an schema is to have access to its
      # public methods. It then runs from the strategy perspective, pointing
      # out any other methods to the manually set event
      delegate_missing_to :@event
      attr_reader :event

      self.directive_location = :schema

      class << self
        alias namespaces namespace

        def kind # :nodoc:
          :schema
        end

        # Mark the given class to be pending of registration
        def inherited(subclass)
          super if defined? super
          pending[subclass] ||= caller(1).find do |item|
            !item.end_with?("`inherited'")
          end
        end

        # :singleton-method:
        # Use a soft mode to find a schema associated with a namespace
        def find(namespace)
          # eager_load! # Load schemas defined on Rails application and engines
          descendants.find { |schema| schema.namespace === namespace }
        end

        # :singleton-method:
        # Find the schema associated to the given namespace
        def find!(namespace)
          organize!
          schemas[namespace.to_sym]
        end

        # Checks if a given method can act as resolver
        def gql_resolver?(method_name)
          (instance_methods - GraphQL::Schema.instance_methods).include?(method_name)
        end

        # Find a given +type+ associated with the schema
        def find_type(type, **xargs)
          xargs[:base_class] = :Type
          xargs[:namespaces] = namespaces
          @@type_map.fetch(type, **xargs)
        end

        # Find a given +type+ associated with the schema. It will raise an
        # exception if the +type+ can not be found
        def find_type!(type, **xargs)
          xargs[:base_class] = :Type
          xargs[:namespaces] = namespaces
          @@type_map.fetch!(type, **xargs)
        end

        # Find a given +directive+ associated with the schema. It will raise an
        # exception if the +directive+ can not be found
        def find_directive!(directive, **xargs)
          xargs[:base_class] = :Directive
          xargs[:namespaces] = namespaces
          @@type_map.fetch!(directive, **xargs)
        end

        # Describe a schema as a GraphQL string
        def to_gql(**xargs)
          ToGQL.describe(self, **xargs)
        end

        protected

          # TODO: Maybe provide an optional 'Any' scalar

          # Generate the helper methods to easily create types within the
          # definition of the schema
          GraphQL::Type::KINDS.each do |kind|
            class_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{kind.underscore}(name, **xargs, &block)
                create_type(name, GraphQL::Type.const_get(:#{kind}), **xargs, &block)
              end
            RUBY
          end

          # Rewrite the object method to check if it should use an assigned one
          def object(name_or_object, **xargs, &block)
            return create_type(name_or_object, Type::Object, &block) \
              unless name_or_object.is_a?(Module)

            create_type(name_or_object, Type::Object::AssignedObject, **xargs) do
              self.assigned_to = name_or_object
              class_eval(&block) if block.present?
            end
          end

          # A simpler way to create a new type object without having to create
          # a class in a different file
          def create_type(name, superclass, **xargs, &block)
            xargs[:suffix] = superclass.base_type.name.demodulize
            create_klass(name, superclass, GraphQL::Type, **xargs, &block)
          end

          # Helper method to create a single source
          def source(object, superclass = nil, **xargs, &block)
            superclass ||= GraphQL::Source.find_for!(object)

            xargs[:suffix] = 'Source'
            schema_namespace = namespace
            create_klass(object, superclass, GraphQL::Source, **xargs) do
              set_namespace schema_namespace
              class_eval(&block) if block.present?
              build!
            end
          end

          # Helper method to create multiple sources with the same type
          def sources(*list, of_type: nil, &block)
            list = list.flatten

            of_type ||= GraphQL::Source.find_for!(list.first)
            list.each { |object| source(object, of_type, &block) }
          end

        private

          # The list of schemas keyd by their corresponding namespace
          def schemas
            @@schemas ||= {}
          end

          # The list of pending schames to be registered asscoaited to where
          # they were defined
          def pending
            @@pending ||= {}
          end

          # Organize the pending classes into their specific namespace to easy
          # identification and also ensuring a single schema per namespace
          def organize!
            while (klass, source = pending.shift)
              raise ArgumentError, <<~MSG.squish if schemas.key?(klass.namespace)
                The #{klass.namespace.inspect} namespace is already assigned to
                "#{schemas[klass.namespace].name}". Please change the value for
                "#{klass.name}" class defined at: #{source}.
              MSG

              klass.validate!
              schemas[klass.namespace] = klass
            end
          end

          # Helper to create objects that are actually classes of a given
          # +superclass+ ensuring that it inherits from +base_class+.
          #
          # The +suffix+ option can ensures that the name of the created
          # class ends with a specific suffix.
          def create_klass(name_or_object, superclass, base_class = nil, **xargs, &block)
            name = name_or_object.is_a?(Module) ? name_or_object.name : name_or_object.to_s

            base_module = name.classify.deconstantize
            base_module.prepend('GraphQL::') unless base_module =~ /^GraphQL(::|$)/
            base_module = base_module.delete_suffix('::').constantize

            klass_name = name.classify.demodulize
            klass_name += xargs[:suffix] if xargs.key?(:suffix) &&
              !klass_name.ends_with?(xargs[:suffix])

            if base_module.const_defined?(klass_name)
              klass = base_module.const_get(klass_name)

              raise DuplicatedError, <<~MSG.squish unless !xargs[:once] && klass < superclass
                A constant named "#{klass_name}" already exists for the
                "#{base_module.name}" module.
              MSG
            else
              base_class ||= superclass.ancestors.find { |klass| klass.superclass === Class }

              valid = superclass.is_a?(Module) && superclass < base_class
              raise DefinitionError, <<~MSG.squish unless valid
                The given "#{superclass}" superclass does not inherites from
                #{base_class.name} class.
              MSG

              klass = base_module.const_set(klass_name, Class.new(superclass))
            end

            klass.class_eval(&block) if block.present?
            klass
          end
      end
    end

    ActiveSupport.run_load_hooks(:graphql, Schema)
  end
end
