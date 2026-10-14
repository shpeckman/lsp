# spec/spec_helper.cr
require "spec"
require "../src/lsp"

struct Plain
  include Scribe::Graphemes

  def boundaries(text : String) : Array(Int32)
    marks = [0]
    text.each_grapheme { |grapheme| marks << marks.last + grapheme.to_s.bytesize }
    marks
  end

  def kind(cluster : Bytes) : Scribe::ClusterKind
    char = String.new(cluster)[0]? || return Scribe::ClusterKind::Other
    return Scribe::ClusterKind::Space if char.whitespace?
    return Scribe::ClusterKind::Word if char.alphanumeric? || char == '_'

    Scribe::ClusterKind::Punct
  end

  def width(cluster : Bytes) : Int32
    1
  end
end

GRAPHEMES = Plain.new

class FakeServer
  getter received        = [] of JSON::Any
  getter client          : LSP::Client
  getter mirror          = ""
  getter replies         = [] of JSON::Any
  property encoding      = "utf-16"
  property capabilities  : JSON::Any

  @transport : LSP::Transport
  @handlers  : Hash(String, Proc(JSON::Any, JSON::Any))

  def initialize(capabilities : String = %({"textDocumentSync": 2}), encoding : String? = "utf-16")
    client_read, server_write = IO.pipe
    server_read, client_write = IO.pipe
    @transport    = LSP::Transport.new(server_read, server_write)
    @capabilities = JSON.parse(capabilities)
    @handlers     = {} of String => Proc(JSON::Any, JSON::Any)
    @encoding     = encoding || "utf-16"
    on("initialize") do |_params|
      caps = @capabilities.as_h.dup
      caps["positionEncoding"] = JSON::Any.new(@encoding) if encoding
      JSON.parse({capabilities: caps}.to_json)
    end
    @client = LSP::Client.new(LSP::Transport.new(client_read, client_write))
    spawn { serve }
  end

  def on(method : String, &handler : JSON::Any -> JSON::Any) : Nil
    @handlers[method] = handler
  end

  def notify(method : String, params) : Nil
    @transport.write({jsonrpc: "2.0", method: method, params: params}.to_json)
  end

  def ask(method : String, params) : Nil
    @transport.write({jsonrpc: "2.0", id: 900, method: method, params: params}.to_json)
  end

  def messages(method : String) : Array(JSON::Any)
    @received.select { |message| message["method"]?.try(&.as_s?) == method }
  end

  def close : Nil
    @transport.close
  end

  private def serve : Nil
    while body = @transport.read
      message = JSON.parse(body)
      @received << message
      method = message["method"]?.try(&.as_s?)

      if method.nil?
        @replies << message
        next
      end

      track(method, message["params"]? || JSON::Any.new(nil))
      if id = message["id"]?
        if handler = @handlers[method]?
          @transport.write({jsonrpc: "2.0", id: id, result: handler.call(message["params"]? || JSON::Any.new(nil))}.to_json)
        else
          @transport.write({jsonrpc: "2.0", id: id, error: {code: -32601, message: "no #{method}"}}.to_json)
        end
      end
    end
  rescue IO::Error
  end

  private def track(method : String, params : JSON::Any) : Nil
    case method
    when "textDocument/didOpen"
      @mirror = params["textDocument"]["text"].as_s
    when "textDocument/didChange"
      params["contentChanges"].as_a.each do |change|
        if range = change["range"]?
          start  = index(range["start"])
          stop   = index(range["end"])
          @mirror = @mirror.byte_slice(0, start) + change["text"].as_s + @mirror.byte_slice(stop, @mirror.bytesize - stop)
        else
          @mirror = change["text"].as_s
        end
      end
    end
  end

  private def index(point : JSON::Any) : Int32
    lines = @mirror.split('\n')
    line  = point["line"].as_i
    byte  = lines[0, line].sum { |part| part.bytesize + 1 }
    text  = lines[line]? || ""
    units = 0
    text.each_char do |char|
      break if units >= point["character"].as_i

      units += @encoding == "utf-8" ? char.bytesize : (@encoding == "utf-32" ? 1 : (char.ord > 0xFFFF ? 2 : 1))
      byte  += char.bytesize
    end
    byte
  end
end

def eventually(limit : Time::Span = 2.seconds, &) : Nil
  deadline = Time.instant + limit
  until yield
    raise "condition not met in time" if Time.instant > deadline
    sleep 1.millisecond
  end
end

def started(server : FakeServer) : FakeServer
  ready = false
  server.client.start("file:///work") { ready = true }
  eventually { ready }
  server
end

def text(value : String = "", **options) : Scribe::Document
  Scribe::Document.new(GRAPHEMES, value, **options, filter: Scribe::MultiLine.new)
end
