# src/lsp/session.cr
module LSP
  record Applied, open : Array(String), written : Array(String), failed : Hash(String, String) do
    def ok? : Bool
      @failed.empty?
    end

    def count : Int32
      @open.size + @written.size
    end
  end

  class Session
    getter client    : Client
    getter documents : Hash(String, Document)

    def initialize(@client : Client)
      @documents = {} of String => Document
      @client.on("textDocument/publishDiagnostics") do |params|
        uri = params["uri"]?.try(&.as_s?) || next
        @documents[uri]?.try(&.receive_diagnostics(params["diagnostics"]?))
      end
    end

    def self.uri(path : String) : String
      "file://" + Path[path].expand.to_s.split('/').map { |part| URI.encode_path_segment(part) }.join('/')
    end

    def open(document : Scribe::Document, uri : String, language : String) : Document
      @documents[uri]?.try(&.close)
      synced = Document.new(self, document, uri, language)
      @documents[uri] = synced
      synced
    end

    def close(uri : String) : Nil
      @documents.delete(uri).try(&.close)
    end

    def apply(changes : Hash(String, Array(RemoteEdit)), graphemes : Scribe::Graphemes,
              units : Scribe::Units, *, write : Bool = true) : Applied
      opened  = [] of String
      written = [] of String
      failed  = {} of String => String

      changes.each do |uri, edits|
        next if edits.empty?

        if synced = @documents[uri]?
          if synced.apply(edits)
            opened << uri
          else
            failed[uri] = "no edit applied"
          end
          next
        end

        unless write
          failed[uri] = "not open"
          next
        end

        begin
          Session.rewrite(uri, edits, graphemes, units)
          written << uri
        rescue error : IO::Error | ArgumentError
          failed[uri] = error.message || error.class.name
        end
      end

      Applied.new(opened, written, failed)
    end

    def self.path(uri : String) : String?
      parsed = URI.parse(uri)
      return nil unless parsed.scheme.nil? || parsed.scheme == "file"

      found = parsed.path
      found.empty? ? nil : URI.decode(found)
    end

    def self.rewrite(uri : String, edits : Array(RemoteEdit), graphemes : Scribe::Graphemes,
                     units : Scribe::Units) : Nil
      path = path(uri) || raise ArgumentError.new("#{uri} is not a local file")
      text = Scribe::Document.new(graphemes, File.read(path), filter: Scribe::MultiLine.new)
      ranges = edits.map do |edit|
        from = text.buffer.offset_at(edit.span.start, units)
        to   = text.buffer.offset_at(edit.span.stop, units)
        Scribe::Edit.new(Math.min(from, to)...Math.max(from, to), edit.text)
      end
      return if ranges.empty?

      text.replace_ranges(ranges)
      File.write(path, text.export)
    end

    protected def forget(uri : String) : Nil
      @documents.delete(uri)
    end
  end
end
