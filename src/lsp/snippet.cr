# src/lsp/snippet.cr
module LSP
  module Snippet
    extend self

    def plain(source : String) : String
      String.build { |io| expand(Char::Reader.new(source), io, nil) }
    end

    private def expand(reader : Char::Reader, io : IO, stop : Char?) : Char::Reader
      while reader.has_next?
        char = reader.current_char
        return reader if char == stop

        case char
        when '\\'
          reader.next_char
          if reader.has_next?
            io << reader.current_char
            reader.next_char
          end
        when '$'
          reader.next_char
          reader = placeholder(reader, io)
        else
          io << char
          reader.next_char
        end
      end
      reader
    end

    private def placeholder(reader : Char::Reader, io : IO) : Char::Reader
      unless reader.has_next?
        io << '$'
        return reader
      end

      if reader.current_char.ascii_number?
        return skip(reader) { |char| char.ascii_number? }
      end

      unless reader.current_char == '{'
        return skip(reader) { |char| char.alphanumeric? || char == '_' } if name_start?(reader.current_char)

        io << '$'
        return reader
      end

      reader.next_char
      reader = skip(reader) { |char| char.alphanumeric? || char == '_' }

      case reader.current_char
      when ':'
        reader.next_char
        reader = expand(reader, io, '}')
      when '|'
        reader.next_char
        first = true
        while reader.has_next? && reader.current_char != '|'
          first = false if reader.current_char == ','
          io << reader.current_char if first
          reader.next_char
        end
        reader.next_char if reader.has_next?
      end

      reader.next_char if reader.has_next? && reader.current_char == '}'
      reader
    end

    private def skip(reader : Char::Reader, & : Char -> Bool) : Char::Reader
      while reader.has_next? && yield reader.current_char
        reader.next_char
      end
      reader
    end

    private def name_start?(char : Char) : Bool
      char.letter? || char == '_'
    end
  end
end
