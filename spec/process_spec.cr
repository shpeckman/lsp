# spec/process_spec.cr
require "./spec_helper"

private def fixture : String
  binary = File.join(Dir.tempdir, "lsp-spec-server-#{Process.pid}")
  unless File.exists?(binary)
    status = Process.run("crystal", ["build", File.join(__DIR__, "fixtures", "server.cr"), "-o", binary], output: :inherit, error: :inherit)
    raise "fixture server did not build" unless status.success?
    at_exit { File.delete?(binary) }
  end
  binary
end

describe "LSP::Client.spawn" do
  it "talks to a server process over its standard streams" do
    client = LSP::Client.spawn(fixture)
    ready  = false
    client.start(LSP::Session.uri(Dir.current)) { ready = true }
    eventually(30.seconds) { ready }
    client.encoding.should eq(Scribe::Units::Bytes)

    session = LSP::Session.new(client)
    doc     = text("héllo world")
    session.open(doc, LSP::Session.uri("/tmp/a.txt"), "plaintext")
    eventually { doc.decorations.size == 1 }
    doc.decorations.first.range.should eq(0...5)
    doc.decorations.first.kind.should eq("warning")

    done   = false
    closed = false
    client.on_close { closed = true; nil }
    client.shutdown { done = true; nil }
    eventually { done && closed }
    client.process.not_nil!.wait.success?.should be_true
  end
end
