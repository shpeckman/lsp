# spec/spread_spec.cr
require "./spec_helper"

private def synced(server : FakeServer, value : String) : {LSP::Document, Scribe::Document}
  session = LSP::Session.new(server.client)
  doc     = text(value)
  {session.open(doc, LSP::Session.uri("#{WORK}/a.cr"), "crystal"), doc}
end

WORK = File.join(Dir.tempdir, "lsp-spread-#{Process.pid}")

describe "LSP::Session#apply" do
  before_each do
    FileUtils.rm_rf(WORK)
    Dir.mkdir_p(WORK)
  end

  after_each { FileUtils.rm_rf(WORK) }

  it "applies to an open document and writes the files that are not open" do
    File.write(File.join(WORK, "b.cr"), "old name here\nsecond line")
    server = started(FakeServer.new(%({"textDocumentSync": 2, "renameProvider": true})))
    server.on("textDocument/rename") do |_params|
      JSON.parse(%({"changes": {
        "#{LSP::Session.uri("#{WORK}/a.cr")}": [
          {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}, "newText": "new"}],
        "#{LSP::Session.uri("#{WORK}/b.cr")}": [
          {"range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 8}}, "newText": "title"}]
      }}))
    end
    synced_doc, doc = synced(server, "old thing")

    result  = nil.as(LSP::Rename?)
    spread  = nil.as(LSP::Applied?)
    synced_doc.rename_everywhere("new") { |renamed, applied| result = renamed; spread = applied; nil }
    eventually { !spread.nil? }

    result.not_nil!.applied.should be_true
    doc.value.should eq("new thing")

    outcome = spread.not_nil!
    outcome.ok?.should be_true
    outcome.written.size.should eq(1)
    outcome.open.should be_empty
    outcome.count.should eq(1)
    File.read(File.join(WORK, "b.cr")).should eq("old title here\nsecond line")
  end

  it "reports a file it cannot reach instead of raising" do
    server  = started(FakeServer.new(%({"textDocumentSync": 2})))
    session = LSP::Session.new(server.client)
    doc     = text("x")
    synced_doc = session.open(doc, LSP::Session.uri("#{WORK}/a.cr"), "crystal")

    missing = LSP::Session.uri("#{WORK}/gone.cr")
    edits   = {missing => [LSP::RemoteEdit.new(
      LSP::Span.new(Scribe::Point.new(0, 0), Scribe::Point.new(0, 1)), "y")]}

    outcome = synced_doc.spread(edits)
    outcome.ok?.should be_false
    outcome.failed.keys.should eq([missing])
    outcome.count.should eq(0)
  end

  it "skips unopened files when asked not to write" do
    File.write(File.join(WORK, "c.cr"), "keep me")
    server  = started(FakeServer.new(%({"textDocumentSync": 2})))
    session = LSP::Session.new(server.client)
    doc     = text("x")
    synced_doc = session.open(doc, LSP::Session.uri("#{WORK}/a.cr"), "crystal")

    uri   = LSP::Session.uri("#{WORK}/c.cr")
    edits = {uri => [LSP::RemoteEdit.new(
      LSP::Span.new(Scribe::Point.new(0, 0), Scribe::Point.new(0, 4)), "drop")]}

    outcome = synced_doc.spread(edits, write: false)
    outcome.ok?.should be_false
    outcome.failed[uri].should eq("not open")
    File.read(File.join(WORK, "c.cr")).should eq("keep me")
  end

  it "turns a file uri back into a path and refuses other schemes" do
    LSP::Session.path(LSP::Session.uri("/tmp/a b.cr")).should eq("/tmp/a b.cr")
    LSP::Session.path("untitled:Untitled-1").should be_nil
  end

  it "keeps a file's own line ending when it rewrites it" do
    File.write(File.join(WORK, "d.cr"), "one\r\ntwo\r\n")
    server  = started(FakeServer.new(%({"textDocumentSync": 2})))
    session = LSP::Session.new(server.client)
    synced_doc = session.open(text("x"), LSP::Session.uri("#{WORK}/a.cr"), "crystal")

    uri   = LSP::Session.uri("#{WORK}/d.cr")
    edits = {uri => [LSP::RemoteEdit.new(
      LSP::Span.new(Scribe::Point.new(1, 0), Scribe::Point.new(1, 3)), "TWO")]}

    synced_doc.spread(edits).ok?.should be_true
    File.read(File.join(WORK, "d.cr")).should eq("one\r\nTWO\r\n")
  end
end
