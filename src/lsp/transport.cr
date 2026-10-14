# src/lsp/transport.cr
module LSP
  class Transport
    HEADER = "Content-Length"

    def initialize(@input : IO, @output : IO)
      @lock = Mutex.new
    end

    def write(body : String) : Nil
      @lock.synchronize do
        @output << HEADER << ": " << body.bytesize << "\r\n\r\n" << body
        @output.flush
      end
    end

    def read : String?
      size = nil.as(Int32?)

      loop do
        line = @input.gets(chomp: true) || return nil
        break if line.empty?

        name, _, value = line.partition(':')
        size = value.strip.to_i? if name.strip.compare(HEADER, case_insensitive: true) == 0
      end

      length = size || raise Error.new("message without #{HEADER}")
      body   = Bytes.new(length)
      @input.read_fully(body)
      String.new(body)
    rescue IO::EOFError
      nil
    end

    def close : Nil
      @input.close
      @output.close
    rescue IO::Error
    end
  end
end
