# spec/client_spec.cr
require "./spec_helper"

describe LSP::Transport do
  it "frames messages with a content length and reads headers in any case" do
    reader, writer = IO.pipe
    LSP::Transport.new(IO::Memory.new, writer).write(%({"a":"é"}))
    writer << "content-length: 2\r\nContent-Type: x\r\n\r\n{}"
    writer.close
    transport = LSP::Transport.new(reader, IO::Memory.new)
    transport.read.should eq(%({"a":"é"}))
    transport.read.should eq("{}")
    transport.read.should be_nil
  end
end

describe LSP::Client do
  it "negotiates the position encoding and announces itself" do
    server = started(FakeServer.new(encoding: "utf-8"))
    server.client.encoding.should eq(Scribe::Units::Bytes)
    params = server.messages("initialize").first["params"]
    params["capabilities"]["general"]["positionEncodings"].as_a.map(&.as_s).should eq(["utf-8", "utf-16"])
    params["rootUri"].as_s.should eq("file:///work")
    params["workspaceFolders"][0]["name"].as_s.should eq("work")
    eventually { server.messages("initialized").size == 1 }
  end

  it "falls back to UTF-16 when the server names no encoding" do
    server = started(FakeServer.new(encoding: nil))
    server.client.encoding.should eq(Scribe::Units::Utf16)
  end

  it "holds traffic until the server is initialized and keeps its order" do
    server = FakeServer.new
    server.client.notify("first", {n: 1})
    server.client.notify("second", {n: 2})
    server.received.should be_empty
    started(server)
    eventually { server.messages("second").size == 1 }
    methods = server.received.compact_map(&.["method"]?.try(&.as_s))
    methods.should eq(["initialize", "initialized", "first", "second"])
  end

  it "routes results and errors to the right request" do
    server = started(FakeServer.new)
    server.on("echo") { |params| params }
    results = [] of JSON::Any
    errors  = [] of LSP::ResponseError
    server.client.request("echo", {v: 1}) { |result| results << result; nil }
    server.client.request("missing", nil, ->(error : LSP::ResponseError) { errors << error; nil }) { |_result| nil }
    eventually { results.size == 1 && errors.size == 1 }
    results.first["v"].as_i.should eq(1)
    errors.first.code.should eq(-32601)
  end

  it "answers the server's requests and delivers its notifications" do
    server = started(FakeServer.new)
    seen   = [] of String
    stop   = server.client.on("window/logMessage") { |params| seen << params["message"].as_s; nil }
    server.notify("window/logMessage", {type: 3, message: "hello"})
    eventually { seen == ["hello"] }
    stop.call
    server.ask("workspace/configuration", {items: [{section: "a"}, {section: "b"}]})
    eventually { server.replies.size == 1 }
    server.replies.first["result"].as_a.size.should eq(2)
    server.ask("custom/thing", nil)
    eventually { server.replies.size == 2 }
    server.replies.last["error"]["code"].as_i.should eq(-32601)
  end

  it "cancels pending requests, shuts down and reports when the server goes away" do
    server = started(FakeServer.new)
    server.on("shutdown") { |_params| JSON::Any.new(nil) }
    id = server.client.request("slow", nil) { |_result| raise "never" }
    server.client.cancel(id)
    eventually { server.messages("$/cancelRequest").size == 1 }
    done   = false
    closed = false
    server.client.on_close { closed = true; nil }
    server.client.shutdown { done = true; nil }
    eventually { done }
    eventually { server.messages("exit").size == 1 }
    server.close
    eventually { closed }
    server.client.closed?.should be_true
  end

  it "reads nested capabilities" do
    server = started(FakeServer.new(%({"textDocumentSync": {"change": 2, "save": {"includeText": true}}})))
    server.client.capability("textDocumentSync", "save", "includeText").try(&.as_bool).should be_true
    server.client.capability("nope", "deeper").should be_nil
  end
end

describe LSP::Snippet do
  it "flattens tab stops, placeholders, choices, variables and escapes" do
    LSP::Snippet.plain("foo(${1:bar}, $2)$0").should eq("foo(bar, )")
    LSP::Snippet.plain("${1:outer ${2:inner}}").should eq("outer inner")
    LSP::Snippet.plain("${1|one,two|}!").should eq("one!")
    LSP::Snippet.plain("\\$1 costs \\} $TM_FILENAME$").should eq("$1 costs } $")
  end
end
