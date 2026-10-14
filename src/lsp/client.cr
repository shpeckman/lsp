# src/lsp/client.cr
module LSP
  class Error < Exception
  end

  record ResponseError, code : Int32, message : String, data : JSON::Any? = nil

  class Client
    alias Dispatch = Proc(Proc(Nil), Nil)

    ENCODINGS = {"utf-8" => Scribe::Units::Bytes, "utf-16" => Scribe::Units::Utf16, "utf-32" => Scribe::Units::CodePoints}
    METHOD_NOT_FOUND = -32601
    NULL             = JSON::Any.new(nil)

    record Pending, result : Proc(JSON::Any, Nil), error : Proc(ResponseError, Nil)?

    getter capabilities : JSON::Any
    getter encoding     : Scribe::Units
    getter process      : Process?
    getter? ready       : Bool
    getter? closed      : Bool

    @transport     : Transport
    @dispatch      : Dispatch
    @next_id       : Int64
    @pending       : Hash(Int64, Pending)
    @notifications : Hash(String, Array(Proc(JSON::Any, Nil)))
    @requests      : Hash(String, Proc(JSON::Any, JSON::Any))
    @queue         : Array(String)
    @closers       : Array(Proc(Nil))

    def self.spawn(command : String, args : Enumerable(String) = [] of String, *, chdir : String? = nil,
                   env : Process::Env = nil, dispatch : Dispatch = Client.immediate) : Client
      process = Process.new(command, args, env: env, chdir: chdir, input: :pipe, output: :pipe, error: :close)
      new(Transport.new(process.output, process.input), dispatch: dispatch, process: process)
    end

    def self.immediate : Dispatch
      ->(work : Proc(Nil)) { work.call }
    end

    def initialize(@transport : Transport, *, @dispatch : Dispatch = Client.immediate, @process : Process? = nil)
      @capabilities  = JSON::Any.new({} of String => JSON::Any)
      @encoding      = Scribe::Units::Utf16
      @ready         = false
      @closed        = false
      @next_id       = 0_i64
      @pending       = {} of Int64 => Pending
      @notifications = {} of String => Array(Proc(JSON::Any, Nil))
      @requests      = {} of String => Proc(JSON::Any, JSON::Any)
      @queue         = [] of String
      @closers       = [] of Proc(Nil)
      default_requests
      spawn(name: "lsp.reader") { pump }
    end

    def start(root : String? = nil, name : String = "lsp.cr", &ready : -> Nil) : Nil
      folders = root ? [{uri: root, name: File.basename(URI.parse(root).path)}] : nil
      params  = {
        processId:        Process.pid,
        clientInfo:       {name: name},
        rootUri:          root,
        workspaceFolders: folders,
        capabilities:     CAPABILITIES,
      }

      send_request("initialize", params, ->(result : JSON::Any) {
        @capabilities = result["capabilities"]? || @capabilities
        @encoding     = ENCODINGS[@capabilities["positionEncoding"]?.try(&.as_s?) || "utf-16"]? || Scribe::Units::Utf16
        @transport.write({jsonrpc: "2.0", method: "initialized", params: {} of String => String}.to_json)
        @ready = true
        @queue.each { |body| @transport.write(body) }
        @queue.clear
        ready.call
        nil
      }, nil, now: true)
    end

    def request(method : String, params, on_error : Proc(ResponseError, Nil)? = nil, &result : JSON::Any -> Nil) : Int64
      send_request(method, params, result, on_error)
    end

    def notify(method : String, params) : Nil
      deliver({jsonrpc: "2.0", method: method, params: params}.to_json)
    end

    def cancel(id : Int64) : Nil
      return unless @pending.delete(id)

      notify("$/cancelRequest", {id: id})
    end

    def on(method : String, &handler : JSON::Any -> Nil) : Proc(Nil)
      list = @notifications[method] ||= [] of Proc(JSON::Any, Nil)
      list << handler
      -> { list.delete(handler); nil }
    end

    def on_request(method : String, &handler : JSON::Any -> JSON::Any) : Nil
      @requests[method] = handler
    end

    def on_close(&handler : -> Nil) : Nil
      @closers << handler
    end

    def capability(*path : String) : JSON::Any?
      path.reduce(@capabilities.as(JSON::Any?)) { |found, key| found.try(&.as_h?).try(&.[key]?) }
    end

    def shutdown(&done : -> Nil) : Nil
      return done.call if @closed

      request("shutdown", nil, ->(_error : ResponseError) { done.call; nil }) do |_result|
        notify("exit", nil)
        done.call
        nil
      end
    end

    def close : Nil
      return if @closed

      @closed = true
      @transport.close
      @process.try { |process| process.terminate unless process.terminated? }
    rescue RuntimeError | IO::Error
    end

    private def send_request(method : String, params, result : Proc(JSON::Any, Nil), error : Proc(ResponseError, Nil)?,
                             now : Bool = false) : Int64
      @next_id += 1
      id = @next_id
      @pending[id] = Pending.new(result, error)
      body = {jsonrpc: "2.0", id: id, method: method, params: params}.to_json
      now ? @transport.write(body) : deliver(body)
      id
    end

    private def deliver(body : String) : Nil
      return if @closed

      if @ready
        @transport.write(body)
      else
        @queue << body
      end
    end

    private def pump : Nil
      while body = @transport.read
        message = JSON.parse(body)
        @dispatch.call(-> { receive(message); nil })
      end
    rescue IO::Error | JSON::ParseException | Error
    ensure
      @dispatch.call(-> { finish; nil })
    end

    private def finish : Nil
      @closed = true
      @pending.clear
      @closers.each(&.call)
    end

    private def receive(message : JSON::Any) : Nil
      id     = message["id"]?
      method = message["method"]?.try(&.as_s?)
      params = message["params"]? || NULL

      if method && id
        answer(id, method, params)
      elsif id
        pending = @pending.delete(id.as_i64? || id.as_s?.try(&.to_i64?) || return) || return
        if error = message["error"]?
          pending.error.try(&.call(ResponseError.new(error["code"]?.try(&.as_i?) || 0, error["message"]?.try(&.as_s?) || "", error["data"]?)))
        else
          pending.result.call(message["result"]? || NULL)
        end
      elsif method
        @notifications[method]?.try(&.dup.each(&.call(params)))
      end
    end

    private def answer(id : JSON::Any, method : String, params : JSON::Any) : Nil
      if handler = @requests[method]?
        @transport.write({jsonrpc: "2.0", id: id, result: handler.call(params)}.to_json)
      else
        @transport.write({jsonrpc: "2.0", id: id, error: {code: METHOD_NOT_FOUND, message: "unsupported: #{method}"}}.to_json)
      end
    end

    private def default_requests : Nil
      on_request("workspace/configuration") do |params|
        JSON::Any.new(Array.new(params["items"]?.try(&.as_a?.try(&.size)) || 0) { NULL })
      end
      {"client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
       "window/showMessageRequest"}.each { |method| on_request(method) { |_params| NULL } }
      on_request("workspace/applyEdit") { |_params| JSON.parse(%({"applied":false})) }
    end
  end
end
