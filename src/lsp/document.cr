# src/lsp/document.cr
module LSP
  class Document
    include Scribe::Listener

    SOURCE = "lsp"

    getter session     : Session
    getter document    : Scribe::Document
    getter uri         : String
    getter language    : String
    getter version     : Int32
    getter diagnostics : Array(Diagnostic)

    @changes  : Array({Scribe::Point, Scribe::Point, String})
    @full     : Bool
    @unlisten : Proc(Nil)

    @semantic : Semantic?

    def initialize(@session : Session, @document : Scribe::Document, @uri : String, @language : String)
      @version     = 0
      @diagnostics = [] of Diagnostic
      @changes     = [] of {Scribe::Point, Scribe::Point, String}
      @full        = false
      @unlisten    = -> { }
      @unlisten    = @document.listen(self)
      client.notify("textDocument/didOpen", {
        textDocument: {uri: @uri, languageId: @language, version: @version, text: @document.value},
      })
    end

    def client : Client
      @session.client
    end

    def units : Scribe::Units
      client.encoding
    end

    def sync : Sync
      found = client.capability("textDocumentSync")
      kind  = found.try(&.as_i?) || found.try(&.as_h?).try(&.["change"]?).try(&.as_i?) || 0
      Sync.from_value?(kind) || Sync::None
    end

    def completion_triggers : Array(String)
      triggers("completionProvider", "triggerCharacters")
    end

    def signature_triggers : Array(String)
      triggers("signatureHelpProvider", "triggerCharacters")
    end

    def applied(document : Scribe::Document, change : Scribe::Change) : Nil
      if client.ready? && sync.incremental? && !@full
        unit = units
        @changes << {change.start_point(document.buffer, unit), change.old_end_point(document.buffer, unit), change.inserted}
      else
        @full = true
      end
    end

    def edited(document : Scribe::Document, changes : Array(Scribe::Change)) : Nil
      flush
    end

    def flush : Nil
      return if @changes.empty? && !@full

      if client.ready? && sync.none?
        @changes.clear
        @full = false
        return
      end

      @version += 1
      body = JSON.build do |json|
        json.object do
          json.field "textDocument" do
            json.object do
              json.field "uri", @uri
              json.field "version", @version
            end
          end
          json.field "contentChanges" do
            json.array do
              if @full
                json.object { json.field "text", @document.value }
              else
                @changes.each do |(start, stop, text)|
                  json.object do
                    json.field "range" { range(json, start, stop) }
                    json.field "text", text
                  end
                end
              end
            end
          end
        end
      end

      @changes.clear
      @full = false
      client.notify("textDocument/didChange", JSON.parse(body))
    end

    def saved : Nil
      include_text = client.capability("textDocumentSync", "save", "includeText").try(&.as_bool?) == true
      params       = include_text ? {textDocument: {uri: @uri}, text: @document.value} : {textDocument: {uri: @uri}, text: nil}
      client.notify("textDocument/didSave", params)
    end

    def close : Nil
      @unlisten.call
      @document.decorate(SOURCE, [] of Scribe::Decoration)
      @document.annotate(SOURCE, [] of Scribe::Annotation)
      @semantic.try(&.clear)
      client.notify("textDocument/didClose", {textDocument: {uri: @uri}})
      @session.forget(@uri)
    end

    def complete(trigger : String? = nil, &block : Array(Completion) -> Nil) : Int64
      context = trigger ? {triggerKind: 2, triggerCharacter: trigger} : {triggerKind: 1, triggerCharacter: nil}
      client.request("textDocument/completion", {textDocument: {uri: @uri}, position: position(@document.cursor), context: context}) do |result|
        block.call(result.raw.nil? ? [] of Completion : LSP.completions(result))
      end
    end

    def accept(item : Completion, view : Scribe::View = @document.view) : Bool
      accept_snippet(item, view) || accept_text(item, view)
    end

    def snippet(item : Completion, view : Scribe::View = @document.view) : Scribe::Snippet?
      source = item.snippet || return nil
      extra  = item.additional.map { |edit| Scribe::Edit.new(offsets(edit.span), edit.text) }
      @document.transaction do
        view.place_carets([Scribe::Caret.new(*span_of(item, view))])
        found = view.insert_snippet(source)
        @document.replace_ranges(extra, view: view) unless extra.empty?
        found
      end
    end

    private def accept_snippet(item : Completion, view : Scribe::View) : Bool
      return false unless item.snippet?

      snippet(item, view)
      true
    end

    private def accept_text(item : Completion, view : Scribe::View) : Bool
      from, to = span_of(item, view)
      edits    = [Scribe::Edit.new(from...to, item.text)] +
                 item.additional.map { |edit| Scribe::Edit.new(offsets(edit.span), edit.text) }
      @document.replace_ranges(edits, view: view)
    end

    private def span_of(item : Completion, view : Scribe::View) : {Int32, Int32}
      cursor = view.cursor
      range  = item.span.try { |span| offsets(span) } || (word_start(cursor)...cursor)
      range  = range.begin...cursor if range.begin <= cursor && cursor > range.end
      {range.begin, range.end}
    end

    def hover(&block : String? -> Nil) : Int64
      client.request("textDocument/hover", {textDocument: {uri: @uri}, position: position(@document.cursor)}) do |result|
        block.call(result.raw.nil? ? nil : LSP.markup(result["contents"]?))
      end
    end

    def signature_help(&block : SignatureHelp? -> Nil) : Int64
      client.request("textDocument/signatureHelp", {textDocument: {uri: @uri}, position: position(@document.cursor)}) do |result|
        block.call(result.raw.nil? ? nil : LSP.signature_help(result))
      end
    end

    def format(&block : Bool -> Nil) : Int64
      indent  = @document.indent
      options = {tabSize: indent.includes?('\t') ? @document.tab_size : Math.max(indent.size, 1), insertSpaces: !indent.includes?('\t')}
      client.request("textDocument/formatting", {textDocument: {uri: @uri}, options: options}) do |result|
        block.call(apply(LSP.text_edits(result)))
      end
    end

    def rename(name : String, &block : Rename -> Nil) : Int64
      client.request("textDocument/rename", {textDocument: {uri: @uri}, position: position(@document.cursor), newName: name}) do |result|
        changes = result.raw.nil? ? {} of String => Array(RemoteEdit) : LSP.workspace_edit(result)
        local   = changes.delete(@uri)
        block.call(Rename.new(local ? apply(local) : false, changes))
      end
    end

    def rename_everywhere(name : String, *, write : Bool = true, &block : Rename, Applied -> Nil) : Int64
      rename(name) do |result|
        block.call(result, spread(result.remote, write: write))
      end
    end

    def definition(&block : Array(Location) -> Nil) : Int64
      unit = units
      client.request("textDocument/definition", {textDocument: {uri: @uri}, position: position(@document.cursor)}) do |result|
        block.call(result.raw.nil? ? [] of Location : LSP.locations(result, unit))
      end
    end

    def inlay_hints(from : Int32 = 0, to : Int32 = @document.length, &block : Array(InlayHint) -> Nil) : Int64
      span = JSON.build do |json|
        json.object do
          json.field("textDocument") { json.object { json.field("uri", @uri) } }
          json.field("range") { range(json, @document.buffer.point(from, units), @document.buffer.point(to, units)) }
        end
      end

      client.request("textDocument/inlayHint", JSON.parse(span)) do |result|
        hints = LSP.inlay_hints(result.raw.nil? ? nil : result)
        annotate(hints)
        block.call(hints)
      end
    end

    def annotate(hints : Array(InlayHint)) : Nil
      @document.annotate(SOURCE, hints.map do |hint|
        Scribe::Annotation.new(offset(hint.point), hint.label, Scribe::Placement::Before, hint.kind)
      end)
    end

    def folding_ranges(&block : Array(FoldRange) -> Nil) : Int64
      client.request("textDocument/foldingRange", {textDocument: {uri: @uri}}) do |result|
        block.call(LSP.fold_ranges(result.raw.nil? ? nil : result))
      end
    end

    def fold(view : Scribe::View = @document.view, &block : Array(FoldRange) -> Nil) : Int64
      folding_ranges do |found|
        view.folds.replace(found.map { |entry| {entry.first, entry.last} })
        block.call(found)
      end
    end

    def semantic_tokens(&block : Semantic -> Nil) : Int64
      found = @semantic ||= Semantic.legend(client.capability("semanticTokensProvider"))
      client.request("textDocument/semanticTokens/full", {textDocument: {uri: @uri}}) do |result|
        data = result["data"]?.try(&.as_a?).try(&.compact_map(&.as_i?)) || [] of Int32
        found.replace(data, @document.buffer, units)
        block.call(found)
      end
    end

    def semantic? : Semantic?
      @semantic
    end

    def references(include_declaration : Bool = true, &block : Array(Location) -> Nil) : Int64
      unit = units
      client.request("textDocument/references", {textDocument: {uri: @uri},
        position: position(@document.cursor), context: {includeDeclaration: include_declaration}}) do |result|
        block.call(result.raw.nil? ? [] of Location : LSP.locations(result, unit))
      end
    end

    def symbols(&block : Array(Symbol) -> Nil) : Int64
      unit = units
      client.request("textDocument/documentSymbol", {textDocument: {uri: @uri}}) do |result|
        block.call(LSP.symbols(result.raw.nil? ? nil : result, @uri, unit))
      end
    end

    def code_actions(from : Int32 = @document.view.selection.begin, to : Int32 = @document.view.selection.end,
                     kinds : Array(String)? = nil, &block : Array(CodeAction) -> Nil) : Int64
      found   = @document.decorations(from, to + 1)
      request = JSON.build do |json|
        json.object do
          json.field("textDocument") { json.object { json.field("uri", @uri) } }
          json.field("range") { range(json, @document.buffer.point(from, units), @document.buffer.point(to, units)) }
          json.field("context") do
            json.object do
              json.field("diagnostics") { json.array { } }
              kinds.try { |list| json.field("only") { json.array { list.each { |kind| json.scalar(kind) } } } }
              json.field("triggerKind", 2)
            end
          end
        end
      end

      client.request("textDocument/codeAction", JSON.parse(request)) do |result|
        block.call(LSP.code_actions(result.raw.nil? ? nil : result))
      end
    end

    def resolve(action : CodeAction, &block : CodeAction -> Nil) : Int64
      client.request("codeAction/resolve", action.data) do |result|
        block.call(LSP.code_actions(JSON.parse("[#{result.to_json}]")).first? || action)
      end
    end

    def run(action : CodeAction, *, write : Bool = true, &block : Applied -> Nil) : Nil
      if action.edits?
        block.call(spread(action.edits, write: write))
        return
      end

      name = action.command
      unless name
        block.call(Applied.new([] of String, [] of String, {} of String => String))
        return
      end

      client.request("workspace/executeCommand", {command: name, arguments: action.arguments}) do |_result|
        block.call(Applied.new([@uri], [] of String, {} of String => String))
      end
    end

    def spread(changes : Hash(String, Array(RemoteEdit)), *, write : Bool = true) : Applied
      @session.apply(changes, @document.graphemes, units, write: write)
    end

    def apply(edits : Array(RemoteEdit)) : Bool
      return false if edits.empty?

      @document.replace_ranges(edits.map { |edit| Scribe::Edit.new(offsets(edit.span), edit.text) })
    end

    def offset(point : Scribe::Point) : Int32
      @document.buffer.offset_at(point, units)
    end

    def offsets(span : Span) : Range(Int32, Int32)
      start = offset(span.start)
      stop  = offset(span.stop)
      Math.min(start, stop)...Math.max(start, stop)
    end

    protected def receive_diagnostics(json : JSON::Any?) : Nil
      @diagnostics = (json.try(&.as_a?) || [] of JSON::Any).map do |entry|
        Diagnostic.new(
          range: offsets(Span.parse(entry["range"])),
          severity: Severity.from_value?(entry["severity"]?.try(&.as_i?) || 1) || Severity::Error,
          message: entry["message"]?.try(&.as_s?) || "",
          source: entry["source"]?.try(&.as_s?),
          code: entry["code"]?.try { |code| code.as_s? || code.as_i?.try(&.to_s) })
      end

      @document.decorate(SOURCE, @diagnostics.map { |found| Scribe::Decoration.new(found.range, found.severity.kind, found.message) })
    end

    private def position(offset : Int32) : NamedTuple(line: Int32, character: Int32)
      found = @document.buffer.point(offset, units)
      {line: found.line, character: found.column}
    end

    private def range(json : JSON::Builder, start : Scribe::Point, stop : Scribe::Point) : Nil
      json.object do
        json.field "start" { point(json, start) }
        json.field "end" { point(json, stop) }
      end
    end

    private def point(json : JSON::Builder, found : Scribe::Point) : Nil
      json.object do
        json.field "line", found.line
        json.field "character", found.column
      end
    end

    private def word_start(offset : Int32) : Int32
      buffer = @document.buffer
      start  = offset
      while start > 0 && buffer.kind(start - 1).try(&.word?)
        start -= 1
      end
      start
    end

    private def triggers(*path : String) : Array(String)
      client.capability(*path).try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end
  end
end
