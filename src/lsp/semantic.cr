# src/lsp/semantic.cr
module LSP
  class Semantic
    include Scribe::TokenSource

    getter types     : Array(String)
    getter modifiers : Array(String)
    getter revision  : Int32

    @lines : Hash(Int32, Array(Scribe::Token))
    @kinds : Hash(UInt32, String)

    def self.legend(capability : JSON::Any?) : Semantic
      found     = capability.try(&.["legend"]?)
      types     = names(found.try(&.["tokenTypes"]?)) || SEMANTIC_TYPES
      modifiers = names(found.try(&.["tokenModifiers"]?)) || SEMANTIC_MODIFIERS
      new(types, modifiers)
    end

    def self.names(json : JSON::Any?) : Array(String)?
      list = json.try(&.as_a?) || return nil
      found = list.compact_map(&.as_s?)
      found.empty? ? nil : found
    end

    def initialize(@types : Array(String) = SEMANTIC_TYPES, @modifiers : Array(String) = SEMANTIC_MODIFIERS)
      @lines    = {} of Int32 => Array(Scribe::Token)
      @kinds    = {} of UInt32 => String
      @revision = -1
    end

    def empty? : Bool
      @lines.empty?
    end

    def size : Int32
      @lines.sum { |_line, found| found.size }
    end

    def clear : Nil
      @lines = {} of Int32 => Array(Scribe::Token)
      @revision = -1
    end

    def stale?(buffer : Scribe::Buffer) : Bool
      @revision != buffer.revision
    end

    def replace(data : Array(Int32), buffer : Scribe::Buffer, units : Scribe::Units) : Nil
      fresh = {} of Int32 => Array(Scribe::Token)
      line  = 0
      start = 0
      index = 0

      while index + 4 < data.size
        ahead  = data[index]
        offset = data[index + 1]
        length = data[index + 2]
        type   = data[index + 3]
        extras = data[index + 4]
        index += 5

        if ahead > 0
          line += ahead
          start = offset
        else
          start += offset
        end
        next unless 0 <= line < buffer.line_count
        next if length <= 0

        row  = buffer.line(line)
        from = row.column_for(start, units)
        to   = row.column_for(start + length, units)
        next if to <= from

        (fresh[line] ||= [] of Scribe::Token) << Scribe::Token.new(from, to - from, kind(type, extras))
      end

      fresh.each_value(&.sort_by!(&.start))
      @lines    = fresh
      @revision = buffer.revision
    end

    def tokens(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      @lines[line]? || Scribe::TokenSource::NO_TOKENS
    end

    private def kind(type : Int32, extras : Int32) : String
      key = (type.to_u32 << 16) | (extras.to_u32 & 0xffff_u32)
      @kinds[key] ||= begin
        name = @types[type]? || "other"
        @modifiers.each_with_index do |modifier, bit|
          name = "#{name}.#{modifier}" if extras.bit(bit) == 1
        end
        name
      end
    end
  end
end
