# lsp

A Language Server Protocol client for Crystal, built for [scribe](https://github.com/shpeckman/scribe) documents.

lsp starts a language server, keeps documents in sync with it as they are edited, turns its diagnostics into scribe decorations, and asks it for completions, hover text, signature help, formatting, renames and definitions. It draws nothing: results come back as plain values for the host — a terminal UI such as [tui](https://github.com/shpeckman/tui), or anything else — to show.

It depends only on scribe and the standard library.

## Requirements

- Crystal 1.21 or newer
- A language server for each language you want to support, started as a process that speaks JSON-RPC on its standard streams (see Servers)

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

server  = LSP.server("crystal") || abort LSP.missing("crystal")
client  = server.spawn
session = LSP::Session.new(client)

client.start(LSP::Session.uri(Dir.current)) do
  puts "server ready, positions in #{client.encoding}"
end

document = Scribe::Document.new(graphemes, File.read("src/app.cr"), filter: Scribe::MultiLine.new)
synced   = session.open(document, LSP::Session.uri("src/app.cr"), server.language_id)

document.insert("x")                       # sent to the server as an incremental change
document.decorations                       # the server's diagnostics, moving with your edits
synced.hover { |text| puts text }          # markdown or plain text, or nil
synced.complete { |items| synced.accept(items.first) unless items.empty? }
```

## Servers

lsp knows a server, or a list in order of preference, for each language `treesitter` bundles, under the same names:

| Language  | Servers, preferred first              | Language id   |
|-----------|---------------------------------------|---------------|
| `bash`    | `bash-language-server start`          | `shellscript` |
| `c`       | `clangd`                              | `c`           |
| `crystal` | `crystalline`                         | `crystal`     |
| `json`    | `vscode-json-language-server --stdio` | `json`        |
| `python`  | `pyright-langserver --stdio`, `pylsp` | `python`      |

```crystal
LSP.server("python")              # the first one installed, or nil
LSP.servers("python")             # every known one, installed or not
LSP.missing("python")             # what to install, for a message to the user
LSP::Client.spawn_for("python")   # spawn the first one installed, or nil
server.path                       # where it was found
```

A server is looked for in `LSP.search_path` first — by default this shard's `vendor/servers/bin` and `vendor/servers/node_modules/.bin`, filled by `make servers` — and then on `PATH`. `LSP.search_path=` replaces the list. `LSP.register(language, LSP::Server.new(name, command, args, language_id:, hint:))` adds a server, ahead of the known ones unless `first: false`, and replaces one with the same name.

### Installing servers

The shard installs nothing by itself. `make servers`, run in this repository (or `make -C lib/lsp servers` from an application), installs what it can into `vendor/servers/` and reports the rest:

| Target                      | Does                                                                                                                                                        |
|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `make crystalline`          | Clones crystalline, checks out `CRYSTALLINE_REF` (default `master`) and builds it with your `crystal` into `vendor/servers/bin`; this takes several minutes |
| `make node-servers`         | `npm install`s pyright, bash-language-server and vscode-langservers-extracted into `vendor/servers` (override with `NODE_SERVERS`)                          |
| `make clangd`, `make pylsp` | Only check for the system packages and print how to install them                                                                                            |
| `make status`               | Shows where each server would be found, or that it is missing                                                                                               |
| `make clean-servers`        | Removes `vendor/servers`                                                                                                                                    |

On Fedora, building crystalline needs the LLVM development files (`sudo dnf install llvm-devel`), and the node servers need `nodejs` and `npm`. clangd comes from `clang-tools-extra`, pylsp from `python3-lsp-server`. crystalline has to be built for the Crystal version you use, which is why it is built rather than downloaded; pin a commit with `make crystalline CRYSTALLINE_REF=<commit>`. Extra compiler flags go in `CRYSTAL_FLAGS`; for example, when linking fails with undefined `LLVM…` symbols because `llvm-config` cannot list the LLVM libraries, `CRYSTAL_FLAGS='--link-flags /path/to/libLLVM.so.<version>'` links the shared library directly.

## The client

`LSP::Client.spawn(command, args, chdir:, env:, dispatch:)` starts the server with its standard input and output piped, and its standard error discarded. `LSP::Client.new(transport, dispatch:)` works over any pair of IOs, for a server reached some other way.

| Method                                             | Effect                                                                                                                     |
|----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| `start(root_uri) { }`                              | Sends `initialize`, negotiates capabilities and position encoding, sends `initialized`, then runs the block                |
| `request(method, params, on_error) { \|result\| }` | Sends a request and returns its id; the block gets the result as `JSON::Any`                                               |
| `notify(method, params)`                           | Sends a notification                                                                                                       |
| `cancel(id)`                                       | Drops a pending request and tells the server                                                                               |
| `on(method) { \|params\| }`                        | Listens for a server notification; returns a proc that stops listening                                                     |
| `on_request(method) { \|params\| reply }`          | Answers a server request; `workspace/configuration`, capability registration and progress creation are answered by default |
| `capability(*path)`                                | Reads the server's capabilities, for example `capability("hoverProvider")`                                                 |
| `shutdown { }`, `close`, `on_close { }`            | Ends the session politely, kills it, or learns when the server went away                                                   |
| `encoding`                                         | The negotiated `Scribe::Units`: `Bytes` for UTF-8, `Utf16` (the protocol default) or `CodePoints` for UTF-32               |

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

| Method                    | Block receives                   | Notes                                                                                                                    |
|---------------------------|----------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `complete(trigger = nil)` | `Array(LSP::Completion)`, sorted | Each item has `label`, `kind`, `detail`, `documentation`, the `text` to insert, and `snippet` with the original source when the server sent one |
| `accept(item)`            | —                                | Applies an item: its own range or the word before the caret, plus any extra edits, as one undo step. A snippet item is inserted with its tabstops |
| `snippet(item)`           | `Scribe::Snippet?`               | Accepts a snippet item and returns the live session, for stepping through its stops                                     |
| `hover`                   | `String?`                        | Markdown or plain text                                                                                                   |
| `signature_help`          | `LSP::SignatureHelp?`            | `current` is the active signature; `parameters` are character ranges in its `label`                                      |
| `format`                  | `Bool`                           | Applies the server's edits as one undo step, using the document's indent for the tab size                                |
| `rename(name)`            | `LSP::Rename`                    | Applies the edits for this document; `remote` holds the edits for other files, by URI                                    |
| `definition`              | `Array(LSP::Location)`           | URIs with `span`s in the server's units, for the host to open                                                            |
| `inlay_hints(from, to)`   | `Array(LSP::InlayHint)`          | Also replaces the document's `"lsp"` annotations, so the hints move with later edits                                     |
| `folding_ranges`          | `Array(LSP::FoldRange)`          | Line ranges the server would fold                                                                                        |
| `fold(view)`              | `Array(LSP::FoldRange)`          | The same, applied to that view's folds                                                                                   |
| `semantic_tokens`         | `LSP::Semantic`                  | A `Scribe::TokenSource` over the server's tokens, decoded into cluster columns                                           |
| `references(declaration = true)` | `Array(LSP::Location)`    | Every use of the symbol at the caret                                                                                     |
| `symbols`                 | `Array(LSP::Symbol)`             | The document's symbols, nested; `each` walks them with a depth                                                           |
| `code_actions(from, to, kinds)` | `Array(LSP::CodeAction)`   | Quick fixes and refactors for a range, the selection by default                                                          |
| `resolve(action)`         | `LSP::CodeAction`                | Fills in an action the server sent without its edit                                                                      |
| `run(action)`             | `LSP::Applied`                   | Applies an action's edits, or runs its command                                                                           |
| `rename_everywhere(name)` | `LSP::Rename`, `LSP::Applied`    | A rename applied here and in every other file it touches                                                                 |

A snippet item carries both: `text` is the snippet flattened to plain text, for a completion list, and `snippet` is the source, which `accept` inserts through `Scribe::View#insert_snippet` so the first placeholder comes back selected. `snippet(item)` hands back the `Scribe::Snippet` so a host can drive `next_stop` and `previous_stop` from Tab and Shift+Tab. Both take an optional view, for a document shown in more than one pane.

```crystal
synced.complete { |items| items.first?.try { |item| @stops = synced.snippet(item) } }
@stops.try(&.next_stop(editor.view))
```

### Inlay hints

`inlay_hints` asks for the hints in a cluster range and turns them into `Scribe::Annotation`s under the `"lsp"` source, so they follow later edits and are dropped when the document closes. A hint's `label` already carries the server's padding, its `kind` is `"type"`, `"parameter"` or `"hint"`, and its `tooltip` is the markup. `annotate(hints)` applies a set you fetched some other way.

```crystal
synced.inlay_hints { |hints| ctx.toast("#{hints.size} hints") }
document.annotations_on(3)        # what to draw beside line 3
```

### Folding

```crystal
synced.fold(editor.view) { |ranges| ctx.toast("#{ranges.size} folds") }
```

`fold` replaces that view's folds with the server's ranges; `folding_ranges` hands them over without applying them. A range of one line is dropped, since there is nothing to collapse.

### Semantic tokens

`semantic_tokens` decodes the server's relative token array into a `Semantic`, which includes `Scribe::TokenSource` and so can be handed straight to a host's editor. The legend comes from the server's capability, or falls back to the standard one the client advertised.

```crystal
synced.semantic_tokens { |tokens| editor.token_source = tokens }
```

A token's `kind` is its type name with each modifier appended as a dotted segment — `function.declaration`, `variable.readonly` — which is exactly what a renderer that styles through every prefix of a dotted name wants. The tokens are a snapshot: `stale?(buffer)` compares the buffer's revision against the one they were decoded at, so a host re-requests after an edit settles. `semantic?` returns the current set without asking again.

### Symbols and references

A `Symbol` has a `name`, a `kind` (the protocol's numeric kind as a word — `class`, `method`, `variable`, …), a `detail`, its `uri`, its full `span` and the narrower `selection` the name itself occupies, a `container` and its `children`. Both response shapes are read: the nested `DocumentSymbol` and the flat `SymbolInformation`.

```crystal
synced.symbols do |found|
  found.each { |symbol| symbol.each { |entry, depth| puts "#{"  " * depth}#{entry.kind} #{entry.name}" } }
end
```

### Code actions

```crystal
synced.code_actions do |actions|
  action = actions.reject(&.disabled).find(&.preferred) || next
  if action.edits?
    synced.run(action) { |applied| report(applied) }
  else
    synced.resolve(action) { |filled| synced.run(filled) { |applied| report(applied) } }
  end
end
```

An action carries its `title`, `kind`, `preferred` flag and a `disabled` reason when the server sent one. Servers often omit the edit until asked, which is what `resolve` is for; `edits?` says whether one is already there. `run` applies the edits when the action has them and sends `workspace/executeCommand` when it only has a command.

### Edits in other files

`rename` applies the edits for this document and hands back the rest in `remote`. `rename_everywhere` goes further and applies those too, and `spread(changes)` does it for any set of edits:

```crystal
synced.rename_everywhere("fresh_name") do |renamed, applied|
  puts "#{renamed.applied}, #{applied.open.size} open, #{applied.written.size} written"
  applied.failed.each { |uri, why| warn "#{uri}: #{why}" }
end
```

An `Applied` lists the URIs that went to an open document (`open`), the files rewritten on disk (`written`) and anything that could not be done (`failed`), with `ok?` and `count` for the common checks. A file that is not open is read, edited through a scribe document and written back, so its own line ending survives; `write: false` leaves unopened files alone and reports them as failed instead. `Session.path(uri)` turns a `file://` URI into a path and returns `nil` for any other scheme.

`completion_triggers` and `signature_triggers` list the characters after which the server would like to be asked again. `apply(edits)` applies any `RemoteEdit`s for this document, and `offset(point)` and `offsets(span)` convert the server's positions to cluster offsets.

## Using it with tui

`tui`'s `Editor` exposes the pieces a language client needs: `document`, `view`, `suggest(labels) { |index| }` for a completion popup at the caret, `note(markdown)` for hover and signature text, `on_assist` for its language keys (completion, hover, signature, format, rename, definition), and `on_edit` for typed trigger characters. Diagnostics show as soon as they arrive, because they are decorations on the document, and so do annotations placed at `Scribe::Placement::RowEnd`.

`Editor` does not yet shift a row's columns for an inline annotation, so `Before` and `After` hints are available as data (`document.annotations_on(line)`) but are not drawn; row-end hints are.

```crystal
def connect(ctx : TUI::Context, editor : TUI::Editor, path : String, language : String) : LSP::Document?
  server  = LSP.server(language) || return nil
  client  = server.spawn(dispatch: ->(work : Proc(Nil)) { ctx.app.enqueue(work); nil })
  session = LSP::Session.new(client)
  client.start(LSP::Session.uri(Dir.current)) { }
  synced = session.open(editor.document, LSP::Session.uri(path), server.language_id)

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

`ask_for_name` and `open_location` are the application's: a prompt for the new name, and opening another file. With `treesitter`, `TreeSitter.language_for(path).try(&.name)` gives the `language` to pass.

## Development

```sh
crystal spec
```

The specs talk to a scripted server running in the same process over pipes, which checks every incremental change by applying it to its own copy of the text in the negotiated encoding. Two specs build `spec/fixtures/server.cr` and run it as a real child process. `spec/real_server_spec.cr` runs diagnostics, hover, definition and completion against crystalline when it is installed (after `make crystalline`), and is pending otherwise.

## License

MIT
