# src/lsp/protocol.cr
module LSP
  CAPABILITIES = {
    general:      {positionEncodings: ["utf-8", "utf-16"]},
    textDocument: {
      synchronization:    {didSave: true, dynamicRegistration: false},
      publishDiagnostics: {relatedInformation: false},
      completion:         {
        completionItem: {snippetSupport: true, documentationFormat: ["markdown", "plaintext"]},
        contextSupport: true,
      },
      hover:         {contentFormat: ["markdown", "plaintext"]},
      signatureHelp: {
        signatureInformation: {
          documentationFormat:  ["markdown", "plaintext"],
          parameterInformation: {labelOffsetSupport: true},
        },
      },
      formatting: {dynamicRegistration: false},
      rename:     {prepareSupport: false},
      definition: {linkSupport: false},
    },
    workspace: {configuration: true, workspaceFolders: true, applyEdit: true},
  }

  enum Severity
    Error       = 1
    Warning     = 2
    Information = 3
    Hint        = 4

    def kind : String
      case self
      in Error       then "error"
      in Warning     then "warning"
      in Information then "info"
      in Hint        then "hint"
      end
    end
  end

  enum Sync
    None        = 0
    Full        = 1
    Incremental = 2
  end

  record Span, start : Scribe::Point, stop : Scribe::Point do
    def self.parse(json : JSON::Any) : Span
      new(LSP.point(json["start"]), LSP.point(json["end"]))
    end
  end

  record RemoteEdit, span : Span, text : String

  record Location, uri : String, span : Span, units : Scribe::Units

  record Diagnostic, range : Range(Int32, Int32), severity : Severity, message : String, source : String?, code : String?

  record Completion, label : String, kind : Int32?, detail : String?, documentation : String?, text : String,
    span : Span?, filter : String, sort : String, additional : Array(RemoteEdit), data : JSON::Any,
    snippet : String? = nil do
    def snippet? : Bool
      !@snippet.nil?
    end
  end

  record Signature, label : String, documentation : String?, parameters : Array(Range(Int32, Int32)), active : Int32?

  record SignatureHelp, signatures : Array(Signature), active_signature : Int32, active_parameter : Int32 do
    def current : Signature?
      @signatures[@active_signature]?
    end
  end

  record Rename, applied : Bool, remote : Hash(String, Array(RemoteEdit))

  def self.point(json : JSON::Any) : Scribe::Point
    Scribe::Point.new(json["line"].as_i, json["character"].as_i)
  end

  def self.markup(json : JSON::Any?) : String?
    case found = json.try(&.raw)
    when String
      found
    when Array
      parts = [] of String
      found.each { |part| markup(part).try { |text| parts << text } }
      parts.empty? ? nil : parts.join("\n\n")
    when Hash
      value    = json.try(&.["value"]?).try(&.as_s?) || return nil
      language = json.try(&.["language"]?).try(&.as_s?)
      language ? "```#{language}\n#{value}\n```" : value
    end
  end

  def self.text_edits(json : JSON::Any?) : Array(RemoteEdit)
    (json.try(&.as_a?) || [] of JSON::Any).map do |edit|
      RemoteEdit.new(Span.parse(edit["range"]), edit["newText"].as_s)
    end
  end

  def self.completions(json : JSON::Any) : Array(Completion)
    items = json.as_a? || json["items"]?.try(&.as_a?) || [] of JSON::Any
    items.map { |item| completion(item) }.sort_by! { |item| {item.sort, item.label} }
  end

  def self.completion(item : JSON::Any) : Completion
    label   = item["label"].as_s
    snippet = item["insertTextFormat"]?.try(&.as_i?) == 2
    edit    = item["textEdit"]?
    raw     = edit.try(&.["newText"]?).try(&.as_s?) || item["insertText"]?.try(&.as_s?) || label
    span    = edit.try { |found| (found["range"]? || found["replace"]?).try { |range| Span.parse(range) } }

    Completion.new(
      label: label,
      kind: item["kind"]?.try(&.as_i?),
      detail: item["detail"]?.try(&.as_s?),
      documentation: markup(item["documentation"]?),
      text: snippet ? Snippet.plain(raw) : raw,
      span: span,
      filter: item["filterText"]?.try(&.as_s?) || label,
      sort: item["sortText"]?.try(&.as_s?) || label,
      additional: text_edits(item["additionalTextEdits"]?),
      data: item,
      snippet: snippet ? raw : nil)
  end

  def self.signature_help(json : JSON::Any) : SignatureHelp?
    list = json["signatures"]?.try(&.as_a?) || return nil
    return nil if list.empty?

    active = json["activeParameter"]?.try(&.as_i?) || 0
    signatures = list.map do |entry|
      label = entry["label"].as_s
      parameters = (entry["parameters"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |parameter|
        case found = parameter["label"]?.try(&.raw)
        when String
          start = label.index(found)
          start ? (start...(start + found.size)) : nil
        when Array
          (found[0].as_i...found[1].as_i)
        end
      end
      Signature.new(label, markup(entry["documentation"]?), parameters, entry["activeParameter"]?.try(&.as_i?))
    end

    SignatureHelp.new(signatures, json["activeSignature"]?.try(&.as_i?) || 0, active)
  end

  def self.locations(json : JSON::Any, units : Scribe::Units) : Array(Location)
    list = json.as_a? || (json.as_h? ? [json] : [] of JSON::Any)
    list.compact_map do |entry|
      uri   = (entry["uri"]? || entry["targetUri"]?).try(&.as_s?) || next
      range = entry["range"]? || entry["targetSelectionRange"]? || next
      Location.new(uri, Span.parse(range), units)
    end
  end

  def self.workspace_edit(json : JSON::Any) : Hash(String, Array(RemoteEdit))
    found = {} of String => Array(RemoteEdit)
    json["changes"]?.try(&.as_h?).try(&.each { |uri, edits| found[uri] = text_edits(edits) })
    json["documentChanges"]?.try(&.as_a?).try(&.each do |change|
      uri = change["textDocument"]?.try(&.["uri"]?).try(&.as_s?) || next
      (found[uri] ||= [] of RemoteEdit).concat(text_edits(change["edits"]?))
    end)
    found
  end
end
