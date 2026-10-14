# lsp

A Language Server Protocol client for Crystal, built for [scribe](https://github.com/shpeckman/scribe) documents.

lsp starts a language server, keeps documents in sync with it as they are edited, turns its diagnostics into scribe decorations, and asks it for completions, hover text, signature help, formatting, renames and definitions. It draws nothing: results come back as plain values for the host — a terminal UI such as [tui](https://github.com/shpeckman/tui), or anything else — to show.

It depends only on scribe and the standard library.

## Requirements

- Crystal 1.21 or newer
- A language server for each language you want to support, started as a process that speaks JSON-RPC on its standard streams

## Installation

```yaml
dependencies:
  lsp:
    github: shpeckman/lsp.cr
```

Then run `shards install` and `require "lsp"`.

## Quick start

`graphemes` is your `Scribe::Graphemes` (see scribe's README).

```crystal
require "lsp"

client  = LSP::Client.spawn("crystalline")
session = LSP::Session.new(client)

client.start(LSP::Session.uri(Dir.current)) do
  puts "server ready, positions in #{client.encoding}"
end

document = Scribe::Document.new(graphemes, File.read("src/app.cr"), filter: Scribe::MultiLine.new)
synced   = session.open(document, LSP::Session.uri("src/app.cr"), "crystal")

document.insert("x")                       # sent to the server as an incremental change
document.decorations                       # the server's diagnostics, moving with your edits
synced.hover { |text| puts text }          # markdown or plain text, or nil
synced.complete { |items| synced.accept(items.first) unless items.empty? }
```

## The client

`LSP::Client.spawn(command, args, chdir:, env:, dispatch:)` starts the server with its standard input and output piped, and its standard error discarded. `LSP::Client.new(transport, dispatch:)` works over any pair of IOs, for a server reached some other way.

| Method | Effect |
| --- | --- |
| `start(root_uri) { }` | Sends `initialize`, negotiates capabilities and position encoding, sends `initialized`, then runs the block |
| `request(method, params, on_error) { \|result\| }` | Sends a request and returns its id; the block gets the result as `JSON::Any` |
| `notify(method, params)` | Sends a notification |
| `cancel(id)` | Drops a pending request and tells the server |
| `on(method) { \|params\| }` | Listens for a server notification; returns a proc that stops listening |
| `on_request(method) { \|params\| reply }` | Answers a server request; `workspace/configuration`, capability registration and progress creation are answered by default |
| `capability(*path)` | Reads the server's capabilities, for example `capability("hoverProvider")` |
| `shutdown { }`, `close`, `on_close { }` | Ends the session politely, kills it, or learns when the server went away |
| `encoding` | The negotiated `Scribe::Units`: `Bytes` for UTF-8, `Utf16` (the protocol default) or `CodePoints` for UTF-32 |

Anything sent before the server has answered `initialize` is queued and sent, in order, once it has.

**Threads and fibers.** Messages are read on a fiber of their own. Every callback — results, notifications, closing — goes through the client's `dispatch` proc, which by default runs it at once. A host with its own event loop passes a proc that queues the work there, so callbacks never interleave with its own code:

```crystal
client = LSP::Client.spawn("crystalline", dispatch: ->(work : Proc(Nil)) { app.enqueue(work); nil })
```

## Documents

`session.open(document, uri, language_id)` returns an `LSP::Document` that listens to a `Scribe::Document`:

- It sends `didOpen` at once, then a `didChange` after every edit or transaction. Changes are incremental, with ranges in the negotiated encoding, when the server asks for that; otherwise it sends the whole text. Edits made before the handshake finishes go as one whole-text change.
- `saved` sends `didSave` (with the text when the server wants it), and `close` sends `didClose` and removes its decorations.
- Diagnostics the server publishes for the document replace its `"lsp"` decorations. Each `Scribe::Decoration` has the diagnostic's message and a kind of `error`, `warning`, `info` or `hint`, and its range moves with later edits. `diagnostics` keeps the full `LSP::Diagnostic` values, with source and code.

`LSP::Session.uri(path)` turns a path into a `file://` URI. A session routes each server notification to the document it names; one client and one session serve every document of one language server.

## Features

Every request returns its id, for `client.cancel`, and calls its block when the server answers.

| Method | Block receives | Notes |
| --- | --- | --- |
| `complete(trigger = nil)` | `Array(LSP::Completion)`, sorted | Each item has `label`, `kind`, `detail`, `documentation` and the `text` to insert, with snippets flattened to plain text |
| `accept(item)` | — | Applies an item: its own range or the word before the caret, plus any extra edits, as one undo step |
| `hover` | `String?` | Markdown or plain text |
| `signature_help` | `LSP::SignatureHelp?` | `current` is the active signature; `parameters` are character ranges in its `label` |
| `format` | `Bool` | Applies the server's edits as one undo step, using the document's indent for the tab size |
| `rename(name)` | `LSP::Rename` | Applies the edits for this document; `remote` holds the edits for other files, by URI |
| `definition` | `Array(LSP::Location)` | URIs with `span`s in the server's units, for the host to open |

`completion_triggers` and `signature_triggers` list the characters after which the server would like to be asked again. `apply(edits)` applies any `RemoteEdit`s for this document, and `offset(point)` and `offsets(span)` convert the server's positions to cluster offsets.

## Using it with tui

`tui`'s `Editor` exposes the pieces a language client needs: `document`, `suggest(labels) { |index| }` for a completion popup at the caret, `note(markdown)` for hover and signature text, `on_assist` for its language keys (completion, hover, signature, format, rename, definition), and `on_edit` for typed trigger characters. Diagnostics show as soon as they arrive, because they are decorations on the document.

```crystal
def connect(ctx : TUI::Context, editor : TUI::Editor, path : String, command : String) : LSP::Document
  client  = LSP::Client.spawn(command, dispatch: ->(work : Proc(Nil)) { ctx.app.enqueue(work); nil })
  session = LSP::Session.new(client)
  client.start(LSP::Session.uri(Dir.current)) { }
  synced = session.open(editor.document, LSP::Session.uri(path), "crystal")

  complete = ->(trigger : String?) do
    synced.complete(trigger) { |items| editor.suggest(items.map(&.label)) { |index| synced.accept(items[index]); nil } }
    nil
  end
  signature = -> do
    synced.signature_help { |help| help.try(&.current).try { |found| editor.note(found.label) } }
    nil
  end

  editor.on_assist do |assist|
    case assist
    in .complete?   then complete.call(nil)
    in .hover?      then synced.hover { |text| text.try { |found| editor.note(found) } }
    in .signature?  then signature.call
    in .format?     then synced.format { |_applied| nil }
    in .rename?     then synced.rename(ask_for_name) { |_result| nil }
    in .definition? then synced.definition { |locations| open_location(locations.first?) }
    end
  end

  editor.listen_on_edit do |changes|
    typed = changes.last?.try(&.inserted) || ""
    complete.call(typed) if synced.completion_triggers.includes?(typed)
    signature.call if synced.signature_triggers.includes?(typed)
  end

  synced
end
```

`ask_for_name` and `open_location` are the application's: a prompt for the new name, and opening another file.

## Development

```sh
crystal spec
```

The specs talk to a scripted server running in the same process over pipes, which checks every incremental change by applying it to its own copy of the text in the negotiated encoding. One spec builds `spec/fixtures/server.cr` and runs it as a real child process.

## License

MIT
