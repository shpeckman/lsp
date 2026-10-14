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

describe "LSP::Document inlay hints" do
  it "turns hints into annotations that move with the text" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "inlayHintProvider": true})))
    server.on("textDocument/inlayHint") do |_params|
      json(%([
        {"position": {"line": 0, "character": 5}, "label": ": Int32", "kind": 1, "paddingLeft": true},
        {"position": {"line": 1, "character": 3}, "label": [{"value": "name"}, {"value": ":"}], "kind": 2,
         "tooltip": {"kind": "markdown", "value": "**param**"}}
      ]))
    end
    synced_doc, doc = synced(server, "let x = 1\nf(2)")

    hints = [] of LSP::InlayHint
    synced_doc.inlay_hints { |found| hints = found; nil }
    eventually { hints.size == 2 }

    hints.first.label.should eq(" : Int32")
    hints.first.kind.should eq("type")
    hints.last.label.should eq("name:")
    hints.last.kind.should eq("parameter")
    hints.last.tooltip.should eq("**param**")

    doc.annotations.map(&.kind).should eq(["type", "parameter"])
    doc.annotations.map(&.offset).should eq([5, 13])

    doc.run(Scribe::Command::DocumentStart)
    doc.insert("xx")
    doc.annotations.map(&.offset).should eq([7, 15])

    synced_doc.close
    doc.annotations.should be_empty
  end

  it "asks about the range it is given" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "inlayHintProvider": true})))
    server.on("textDocument/inlayHint") { |_params| json("[]") }
    synced_doc, doc = synced(server, "one\ntwo\nthree")

    done = false
    synced_doc.inlay_hints(4, 7) { |_found| done = true; nil }
    eventually { done }

    asked = server.messages("textDocument/inlayHint").first["params"]["range"]
    asked["start"]["line"].as_i.should eq(1)
    asked["end"]["line"].as_i.should eq(1)
    asked["end"]["character"].as_i.should eq(3)
  end
end

describe "LSP::Document folding ranges" do
  it "reads fold ranges and applies them to a view" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "foldingRangeProvider": true})))
    server.on("textDocument/foldingRange") do |_params|
      json(%([
        {"startLine": 0, "endLine": 3, "kind": "region"},
        {"startLine": 1, "endLine": 2},
        {"startLine": 5, "endLine": 5}
      ]))
    end
    synced_doc, doc = synced(server, "a\nb\nc\nd\ne\nf")

    found = [] of LSP::FoldRange
    synced_doc.folding_ranges { |ranges| found = ranges; nil }
    eventually { found.size == 2 }
    found.first.kind.should eq("region")
    found.last.first.should eq(1)

    applied = false
    synced_doc.fold { |_ranges| applied = true; nil }
    eventually { applied }

    doc.view.folds.size.should eq(2)
    doc.view.folds.collapsed?(0).should be_true
    doc.view.folds.hidden?(2).should be_true
    doc.view.folds.hidden?(3).should be_true
    doc.view.folds.rows.should eq([0, 4, 5])
    doc.view.layout.row_count.should eq(3)
  end
end

describe "LSP::Document semantic tokens" do
  it "decodes relative tokens into a scribe token source" do
    legend = %({"textDocumentSync": 2, "semanticTokensProvider": {"legend":
      {"tokenTypes": ["keyword", "function", "variable"], "tokenModifiers": ["declaration", "readonly"]},
      "full": true}})
    server = started(FakeServer.new(legend))
    server.on("textDocument/semanticTokens/full") do |_params|
      json(%({"data": [0, 0, 3, 0, 0, 0, 4, 3, 1, 1, 1, 2, 5, 2, 2]}))
    end
    synced_doc, doc = synced(server, "def run\n  value = 1")

    tokens = nil.as(LSP::Semantic?)
    synced_doc.semantic_tokens { |found| tokens = found; nil }
    eventually { !tokens.nil? }

    semantic = tokens.not_nil!
    semantic.types.should eq(["keyword", "function", "variable"])
    semantic.size.should eq(3)

    source = semantic.as(Scribe::TokenSource)
    source.tokens(doc.buffer, 0).map { |token| {token.start, token.count, token.kind} }
      .should eq([{0, 3, "keyword"}, {4, 3, "function.declaration"}])
    source.tokens(doc.buffer, 1).map(&.kind).should eq(["variable.readonly"])
    source.tokens(doc.buffer, 9).should be_empty

    semantic.stale?(doc.buffer).should be_false
    doc.insert("x")
    semantic.stale?(doc.buffer).should be_true

    synced_doc.close
    semantic.empty?.should be_true
  end

  it "falls back to the standard legend when the server gives none" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "semanticTokensProvider": {"full": true}})))
    server.on("textDocument/semanticTokens/full") { |_params| json(%({"data": []})) }
    synced_doc, _doc = synced(server, "x")

    tokens = nil.as(LSP::Semantic?)
    synced_doc.semantic_tokens { |found| tokens = found; nil }
    eventually { !tokens.nil? }
    tokens.not_nil!.types.should eq(LSP::SEMANTIC_TYPES)
    tokens.not_nil!.empty?.should be_true
  end
end

describe "LSP::Document navigation" do
  it "reads references with and without the declaration" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "referencesProvider": true})))
    server.on("textDocument/references") do |_params|
      json(%([
        {"uri": "file:///a.cr", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}},
        {"uri": "file:///b.cr", "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 7}}}
      ]))
    end
    synced_doc, _doc = synced(server, "foo\nfoo")

    found = [] of LSP::Location
    synced_doc.references { |list| found = list; nil }
    eventually { found.size == 2 }
    found.map(&.uri).should eq(["file:///a.cr", "file:///b.cr"])
    found.first.span.start.line.should eq(0)

    asked = server.messages("textDocument/references").first["params"]["context"]["includeDeclaration"]
    asked.as_bool.should be_true

    done = false
    synced_doc.references(false) { |_list| done = true; nil }
    eventually { done }
    server.messages("textDocument/references").last["params"]["context"]["includeDeclaration"].as_bool.should be_false
  end

  it "reads nested document symbols and flattens them with depth" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "documentSymbolProvider": true})))
    server.on("textDocument/documentSymbol") do |_params|
      json(%([{
        "name": "Thing", "kind": 5, "detail": "a class",
        "range": {"start": {"line": 0, "character": 0}, "end": {"line": 4, "character": 3}},
        "selectionRange": {"start": {"line": 0, "character": 6}, "end": {"line": 0, "character": 11}},
        "children": [{
          "name": "run", "kind": 6,
          "range": {"start": {"line": 1, "character": 2}, "end": {"line": 3, "character": 5}},
          "selectionRange": {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 9}}
        }]
      }]))
    end
    synced_doc, _doc = synced(server, "class Thing\n  def run\n    1\n  end\nend")

    found = [] of LSP::Symbol
    synced_doc.symbols { |list| found = list; nil }
    eventually { found.size == 1 }

    top = found.first
    top.name.should eq("Thing")
    top.kind.should eq("class")
    top.detail.should eq("a class")
    top.children.size.should eq(1)
    top.children.first.kind.should eq("method")
    top.children.first.container.should eq("Thing")

    flat = [] of {String, Int32}
    top.each { |entry, depth| flat << {entry.name, depth} }
    flat.should eq([{"Thing", 0}, {"run", 1}])
  end

  it "reads the flat SymbolInformation shape too" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "documentSymbolProvider": true})))
    server.on("textDocument/documentSymbol") do |_params|
      json(%([{"name": "top", "kind": 12, "containerName": "mod",
        "location": {"uri": "file:///z.cr", "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 3}}}}]))
    end
    synced_doc, _doc = synced(server, "def top\nend")

    found = [] of LSP::Symbol
    synced_doc.symbols { |list| found = list; nil }
    eventually { found.size == 1 }
    found.first.kind.should eq("function")
    found.first.uri.should eq("file:///z.cr")
    found.first.container.should eq("mod")
    found.first.children.should be_empty
  end
end

describe "LSP::Document code actions" do
  it "reads actions, resolves one and applies its edit" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "codeActionProvider": true})))
    server.on("textDocument/codeAction") do |_params|
      json(%([
        {"title": "Fix it", "kind": "quickfix", "isPreferred": true},
        {"title": "Nope", "kind": "refactor", "disabled": {"reason": "not here"}}
      ]))
    end
    server.on("codeAction/resolve") do |_params|
      json(%({"title": "Fix it", "kind": "quickfix", "edit": {"changes": {"file:///work/a.cr":
        [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}, "newText": "bar"}]}}}))
    end
    synced_doc, doc = synced(server, "foo")

    actions = [] of LSP::CodeAction
    synced_doc.code_actions { |found| actions = found; nil }
    eventually { actions.size == 2 }
    actions.first.title.should eq("Fix it")
    actions.first.preferred.should be_true
    actions.first.edits?.should be_false
    actions.last.disabled.should eq("not here")

    resolved = nil.as(LSP::CodeAction?)
    synced_doc.resolve(actions.first) { |found| resolved = found; nil }
    eventually { !resolved.nil? }
    resolved.not_nil!.edits?.should be_true

    outcome = nil.as(LSP::Applied?)
    synced_doc.run(resolved.not_nil!) { |found| outcome = found; nil }
    eventually { !outcome.nil? }
    outcome.not_nil!.ok?.should be_true
    outcome.not_nil!.open.should eq(["file:///work/a.cr"])
    doc.value.should eq("bar")
  end

  it "runs a command action through workspace/executeCommand" do
    server = started(FakeServer.new(%({"textDocumentSync": 2, "codeActionProvider": true})))
    server.on("textDocument/codeAction") do |_params|
      json(%([{"title": "Organise", "kind": "source.organizeImports",
        "command": {"command": "do.it", "arguments": ["x"]}}]))
    end
    server.on("workspace/executeCommand") { |_params| json("null") }
    synced_doc, _doc = synced(server, "foo")

    actions = [] of LSP::CodeAction
    synced_doc.code_actions { |found| actions = found; nil }
    eventually { actions.size == 1 }
    actions.first.command.should eq("do.it")

    outcome = nil.as(LSP::Applied?)
    synced_doc.run(actions.first) { |found| outcome = found; nil }
    eventually { !outcome.nil? }
    server.messages("workspace/executeCommand").first["params"]["command"].as_s.should eq("do.it")
  end
end
