# frozen_string_literal: true

module Rails # :nodoc:
  module GraphQL # :nodoc:
    # Error class tha wrappes all the other error classes
    StandardError = Class.new(::StandardError)

    # Error class related to problems during the definition process
    DefinitionError = Class.new(StandardError)

    # Errors that can happen related to the arguments given to a method
    ArgumentError = Class.new(DefinitionError)

    # Errors related to the name of the objects
    NameError = Class.new(DefinitionError)

    # Error class related to problems during the execution process
    ExecutionError = Class.new(StandardError)

    # Error related to the parsing process
    ParseError = Class.new(ExecutionError)
  end
end
