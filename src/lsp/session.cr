# src/lsp/session.cr
module LSP
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

    protected def forget(uri : String) : Nil
      @documents.delete(uri)
    end
  end
end
