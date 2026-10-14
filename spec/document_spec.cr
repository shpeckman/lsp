# spec/document_spec.cr
require "./spec_helper"

private def synced(server : FakeServer, value : String, **options) : {LSP::Document, Scribe::Document}
  session = LSP::Session.new(server.client)
  doc     = text(value, **options)
  {session.open(doc, "file:///work/a.cr", "crystal"), doc}
end

private def json(source : String) : JSON::Any
  JSON.parse(source)
end

describe LSP::Document do
  it "opens the document and keeps the server's copy in step through incremental edits" do
    {"utf-16", "utf-8", "utf-32"}.each do |encoding|
      server = started(FakeServer.new(encoding: encoding))
      synced_doc, doc = synced(server, "aé👍🏽\nx y\nz")
      eventually { server.mirror == doc.value }
      doc.move(3)
      doc.insert("Q")
      doc.place_carets([Scribe::Caret.at(1), Scribe::Caret.at(7)])
      doc.insert("👍🏽\n")
      doc.run(Scribe::Command::DeleteWordBackward)
      doc.transaction do
        doc.run(Scribe::Command::DocumentEnd)
        doc.insert("!")
        doc.run(Scribe::Command::DocumentStart)
        doc.insert("^")
      end
      doc.undo
      doc.value = "replaced\ntext"
      eventually { server.mirror == doc.value }
      synced_doc.version.should eq(server.messages("textDocument/didChange").size)
      server.messages("textDocument/didChange").last["params"]["textDocument"]["version"].as_i.should eq(synced_doc.version)
    end
  end

  it "sends whole text when the server syncs fully, and after edits made before the handshake" do
    server = started(FakeServer.new(%({"textDocumentSync": 1})))
    _synced, doc = synced(server, "abc")
    doc.insert("d")
    eventually { server.messages("textDocument/didChange").size == 1 }
    server.messages("textDocument/didChange").first["params"]["contentChanges"][0]["text"].as_s.should eq("abcd")

    early = FakeServer.new
    _early_synced, early_doc = synced(early, "abc")
    early_doc.insert("d")
    started(early)
    eventually { early.mirror == "abcd" }
    early.messages("textDocument/didChange").first["params"]["contentChanges"][0]["range"]?.should be_nil
  end

  it "sends nothing when the server does not want changes" do
    server = started(FakeServer.new(%({"textDocumentSync": 0})))
    _synced, doc = synced(server, "abc")
    doc.insert("d")
    server.client.notify("marker", nil)
    eventually { server.messages("marker").size == 1 }
    server.messages("textDocument/didChange").should be_empty
  end

  it "reports saving with or without text and closes cleanly" do
    server = started(FakeServer.new(%({"textDocumentSync": {"change": 2, "save": {"includeText": true}}})))
    synced_doc, doc = synced(server, "abc")
    synced_doc.saved
    eventually { server.messages("textDocument/didSave").size == 1 }
    server.messages("textDocument/didSave").first["params"]["text"].as_s.should eq("abc")
    synced_doc.close
    eventually { server.messages("textDocument/didClose").size == 1 }
    doc.insert("x")
    server.client.notify("marker", nil)
    eventually { server.messages("marker").size == 1 }
    server.messages("textDocument/didChange").should be_empty
    synced_doc.session.documents.should be_empty
  end

  it "turns published diagnostics into decorations that follow edits" do
    server = started(FakeServer.new)
    synced_doc, doc = synced(server, "👍🏽 bad\nok")
    server.notify("textDocument/publishDiagnostics", {
      uri:         "file:///work/a.cr",
      diagnostics: [
        {range: {start: {line: 0, character: 5}, end: {line: 0, character: 8}}, severity: 1, message: "bad word", source: "lint", code: 7},
        {range: {start: {line: 1, character: 0}, end: {line: 1, character: 2}}, severity: 4, message: "hint"},
      ],
    })
    eventually { doc.decorations.size == 2 }
    doc.decorations.map(&.range).should eq([2...5, 6...8])
    doc.decorations.map(&.kind).should eq(["error", "hint"])
    synced_doc.diagnostics.first.code.should eq("7")
    doc.move(0)
    doc.insert("XX")
    doc.decorations.first.range.should eq(4...7)
    server.notify("textDocument/publishDiagnostics", {uri: "file:///work/a.cr", diagnostics: [] of String})
    eventually { doc.decorations.empty? }
  end

  it "completes, sorts, and accepts items with text edits, snippets and extra edits" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "completionProvider": {"triggerCharacters": ["."]}})))
    server.on("textDocument/completion") do |_params|
      json(%({"isIncomplete": false, "items": [
        {"label": "zeta", "sortText": "b"},
        {"label": "puts", "sortText": "a", "insertTextFormat": 2, "insertText": "puts(${1:value})$0",
         "documentation": {"kind": "markdown", "value": "**prints**"},
         "additionalTextEdits": [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "# x\\n"}]},
        {"label": "length", "textEdit": {"range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 4}}, "newText": "length"}}
      ]}))
    end
    synced_doc, doc = synced(server, "a\nx.le")
    synced_doc.completion_triggers.should eq(["."])
    items = [] of LSP::Completion
    synced_doc.complete(".") { |found| items = found; nil }
    eventually { items.size == 3 }
    items.map(&.label).should eq(["puts", "zeta", "length"])
    items.first.text.should eq("puts(value)")
    items.first.documentation.should eq("**prints**")
    server.messages("textDocument/completion").first["params"]["context"]["triggerCharacter"].as_s.should eq(".")

    synced_doc.accept(items.last).should be_true
    doc.value.should eq("a\nx.length")
    doc.cursor.should eq(doc.length)

    doc.value = "a\npu"
    synced_doc.accept(items.first).should be_true
    doc.value.should eq("# x\na\nputs(value)")
    doc.undo
    doc.value.should eq("a\npu")
  end

  it "accepts a snippet item as tabstops and selects the first placeholder" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "completionProvider": {}})))
    server.on("textDocument/completion") do |_params|
      json(%({"isIncomplete": false, "items": [
        {"label": "each", "insertTextFormat": 2, "insertText": "each do |${1:item}|\\n  $0\\nend"}
      ]}))
    end
    synced_doc, doc = synced(server, "ea")
    items = [] of LSP::Completion
    synced_doc.complete { |found| items = found; nil }
    eventually { items.size == 1 }

    items.first.snippet?.should be_true
    items.first.text.should eq("each do |item|\n  \nend")

    snippet = synced_doc.snippet(items.first).not_nil!
    doc.value.should eq("each do |item|\n  \nend")
    doc.selected_text.should eq("item")
    snippet.size.should eq(2)

    doc.insert("line")
    doc.value.should eq("each do |line|\n  \nend")
    snippet.next_stop(doc.view).should be_true
    doc.cursor.should eq(17)

    doc.undo
    doc.value.should eq("each do |item|\n  \nend")
  end

  it "reads hover in every shape the protocol allows" do
    server = started(FakeServer.new)
    replies = [
      json(%({"contents": {"kind": "markdown", "value": "# Title"}})),
      json(%({"contents": ["plain", {"language": "crystal", "value": "def x"}]})),
      JSON::Any.new(nil),
    ]
    server.on("textDocument/hover") { |_params| replies.shift }
    synced_doc, _doc = synced(server, "abc")
    seen = [] of String?
    3.times { synced_doc.hover { |found| seen << found; nil } }
    eventually { seen.size == 3 }
    seen.should eq(["# Title", "plain\n\n```crystal\ndef x\n```", nil])
  end

  it "reads signature help with string and offset parameter labels" do
    server = started(FakeServer.new(%|{"textDocumentSync": 2, "signatureHelpProvider": {"triggerCharacters": ["(", ","]}}|))
    server.on("textDocument/signatureHelp") do |_params|
      json(%({"activeSignature": 0, "activeParameter": 1, "signatures": [
        {"label": "f(a : Int32, b : String)", "documentation": "does f",
         "parameters": [{"label": "a : Int32"}, {"label": [13, 23]}]}]}))
    end
    synced_doc, _doc = synced(server, "f(1, ")
    synced_doc.signature_triggers.should eq(["(", ","])
    help = nil.as(LSP::SignatureHelp?)
    synced_doc.signature_help { |found| help = found; nil }
    eventually { !help.nil? }
    signature = help.not_nil!.current.not_nil!
    signature.parameters.should eq([2...11, 13...23])
    signature.documentation.should eq("does f")
    help.not_nil!.active_parameter.should eq(1)
  end

  it "applies formatting as one undo step with the document's indentation" do
    server = started(FakeServer.new)
    server.on("textDocument/formatting") do |_params|
      json(%([{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "newText": "  "},
              {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}, "newText": "  "}]))
    end
    synced_doc, doc = synced(server, " a\nb", indent: "  ")
    done = nil.as(Bool?)
    synced_doc.format { |applied| done = applied; nil }
    eventually { !done.nil? }
    done.should be_true
    doc.value.should eq("  a\n  b")
    options = server.messages("textDocument/formatting").first["params"]["options"]
    {options["tabSize"].as_i, options["insertSpaces"].as_bool}.should eq({2, true})
    doc.undo
    doc.value.should eq(" a\nb")
  end

  it "renames locally and hands back the edits for other files" do
    server = started(FakeServer.new)
    server.on("textDocument/rename") do |_params|
      json(%({"documentChanges": [
        {"textDocument": {"uri": "file:///work/a.cr", "version": 1},
         "edits": [{"range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 7}}, "newText": "bar"}]},
        {"textDocument": {"uri": "file:///work/b.cr", "version": null},
         "edits": [{"range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 3}}, "newText": "bar"}]}]}))
    end
    synced_doc, doc = synced(server, "def foo")
    result = nil.as(LSP::Rename?)
    synced_doc.rename("bar") { |found| result = found; nil }
    eventually { !result.nil? }
    result.not_nil!.applied.should be_true
    doc.value.should eq("def bar")
    result.not_nil!.remote.keys.should eq(["file:///work/b.cr"])
    result.not_nil!.remote["file:///work/b.cr"].first.span.start.should eq(Scribe::Point.new(2, 0))
    server.messages("textDocument/rename").first["params"]["newName"].as_s.should eq("bar")
  end

  it "finds definitions from locations and location links" do
    server = started(FakeServer.new(encoding: "utf-8"))
    replies = [
      json(%({"uri": "file:///work/b.cr", "range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 5}}})),
      json(%([{"targetUri": "file:///work/c.cr", "targetRange": {"start": {"line": 0, "character": 0}, "end": {"line": 9, "character": 0}},
               "targetSelectionRange": {"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 7}}}])),
      JSON::Any.new(nil),
    ]
    server.on("textDocument/definition") { |_params| replies.shift }
    synced_doc, _doc = synced(server, "x")
    seen = [] of Array(LSP::Location)
    3.times { synced_doc.definition { |found| seen << found; nil } }
    eventually { seen.size == 3 }
    seen[0].first.uri.should eq("file:///work/b.cr")
    seen[0].first.units.should eq(Scribe::Units::Bytes)
    seen[1].first.span.start.should eq(Scribe::Point.new(3, 4))
    seen[2].should be_empty
  end

  it "makes file URIs from paths" do
    LSP::Session.uri("/tmp/a b/c.cr").should eq("file:///tmp/a%20b/c.cr")
  end
end
