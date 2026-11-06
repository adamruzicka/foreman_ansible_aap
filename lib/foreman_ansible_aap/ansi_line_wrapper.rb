# frozen_string_literal: true

module ForemanAnsibleAap
  # Wraps long output lines at a byte budget without ever splitting in the
  # middle of an ANSI escape sequence, which would render as garbage such as
  # "[0;32m". The output viewer renders each stored event chunk as one
  # numbered line, so chunks must also align with real line boundaries.
  module AnsiLineWrapper
    ESCAPE_SEQUENCE = /\e\[[0-9;]*[A-Za-z]|./m.freeze

    module_function

    def wrap(line, width)
      return [line] if line.length <= width

      chunks = []
      buffer = +''
      line.scan(ESCAPE_SEQUENCE) { |token| buffer = append_token(chunks, buffer, token, width) }
      chunks << buffer
    end

    def append_token(chunks, buffer, token, width)
      return buffer << token if buffer.length + token.length <= width

      chunks << buffer
      buffer = +''
      buffer << token
    end
  end
end
