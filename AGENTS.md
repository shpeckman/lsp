# AGENTS.md

Orientation for AI agents working on this repository.

## What this is

`lsp` is a Language Server Protocol client for Crystal, built for `scribe` documents. It starts a language server, keeps documents in sync as they are edited, turns the server's diagnostics into scribe decorations and its inlay hints into scribe annotations, and asks it for completions, hover text, signature help, formatting, renames, definitions, folding ranges and semantic tokens. It draws nothing: results come back as plain values for a host such as the `tui` shard to show.

It depends only on `scribe` and the standard library.

## Layout

- `src/lsp.cr` — requires every file in load order.
- `src/lsp/transport.cr` — `Transport`: `Content-Length` framing over a pair of IOs.
- `src/lsp/client.cr` — `Client`: the JSON-RPC layer. Spawns the server, reads messages on its own fiber, routes every callback through the `dispatch` proc, queues anything sent before `initialize` is answered, negotiates the position encoding into a `Scribe::Units`, and answers the housekeeping requests servers send (`workspace/configuration`, capability registration, progress creation, `workspace/applyEdit`).
- `src/lsp/server.cr` — `Server` and the per-language table of known servers, the search path (`vendor/servers` first, then `PATH`), and `LSP.server`, `servers`, `missing`, `register`.
- `src/lsp/protocol.cr` — `CAPABILITIES` (what this client advertises), the semantic token legend constants, the wire records (`Span`, `RemoteEdit`, `Location`, `Diagnostic`, `Completion`, `Signature`, `SignatureHelp`, `Rename`, `InlayHint`, `FoldRange`, `Symbol`, `CodeAction`), the symbol-kind and code-action-kind tables and the `self.`-level parsers that build them from `JSON::Any`.
- `src/lsp/snippet.cr` — flattens LSP snippet syntax to plain text, for a completion list. The tabstop-aware path lives in scribe (`Scribe::Snippet`), and `Completion#snippet` carries the original source for it.
- `src/lsp/semantic.cr` — `Semantic`: decodes the relative five-integer token array against the server's legend and serves it as a `Scribe::TokenSource`, with columns converted from the negotiated encoding to clusters. Caches each kind string and records the buffer revision it decoded at (`stale?`).
- `src/lsp/session.cr` — `Session`: one client, many documents, routing each server notification to the document its URI names; `Session.uri`, `Session.path`, and `apply`, which spreads a workspace edit over the open documents and rewrites the files that are not open (through a throw-away `Scribe::Document`, so each file keeps its own line ending). Its result is an `Applied`.
- `src/lsp/document.cr` — `Document`: a `Scribe::Listener` on one `Scribe::Document`. Sends `didOpen`, incremental `didChange`, `didSave` and `didClose`; converts positions both ways (`offset`, `offsets`, `position`); and holds every feature request.
- `spec/` — the suite talks to `FakeServer`, a scripted server in the same process over pipes, which applies every incremental change to its own copy of the text in the negotiated encoding and fails if they disagree. `spec/fixtures/server.cr` is built and run as a real child process by two examples. `spec/real_server_spec.cr` runs against crystalline when it is installed and is pending otherwise.

## Commands

- `crystal spec` — run the suite.
- `crystal spec spec/document_spec.cr` — run one file.
- `make servers` — install what it can into `vendor/servers`; `make status` shows what would be found.
- `crystal build --no-codegen src/lsp.cr` — fast compile check.

## Rules

- Positions on the wire are in the negotiated encoding, never clusters. Convert with `offset`/`offsets` on the way in and `position`/`range` on the way out, and go through `Scribe::Units` rather than counting units by hand.
- Everything the server owns for a document is replaced per source under `SOURCE`: diagnostics through `decorate`, inlay hints through `annotate`. `close` must clear both and drop the semantic tokens.
- Every request returns its id so a host can `client.cancel` it, and takes its result in a block. Keep that shape for new features; never block the loop waiting for an answer.
- A new feature means a capability in `CAPABILITIES`, a record and a parser in `protocol.cr`, a request method in `document.cr`, a `FakeServer` script in the specs, and rows in the README's feature table.
- Callbacks reach the host through the client's `dispatch`. Do not call back into the host from the reader fiber.
- Writing to a file that is not open goes through `Session.rewrite` only, and reports failures in `Applied#failed` rather than raising: a workspace edit must not abort halfway through.
- The client never resolves scribe state itself: it holds a `Scribe::Document` and asks it, and takes an optional `Scribe::View` where carets matter (`accept`, `snippet`, `fold`) so a document shown in several panes works.

## Code standards

- Compiler-friendly, performance-focused, idiomatic and data-driven.
- The usage-facing API must be ergonomic.
- Avoid shotgun surgery: one change should land in one place.
- No comments, except every file starts with a comment containing its own path (e.g. `# src/lsp/document.cr`).
- Never use `out` as an identifier.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.
