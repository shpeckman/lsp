# AGENTS.md

Orientation for AI agents working on this repository.

## What this is

`lsp` (repository `lsp.cr`) is a Language Server Protocol client for Crystal. It runs a server process, keeps `scribe` documents in sync with it, turns diagnostics into `Scribe::Decoration`s, and wraps completion, hover, signature help, formatting, rename and definition requests. It depends only on `scribe` and the standard library, and must never depend on a UI shard; hosts such as `tui` wire it up themselves (the README shows how).

## Layout

- `src/lsp.cr` — requires every file.
- `src/lsp/transport.cr` — `Content-Length` framing over an IO pair; writes are serialised with a mutex.
- `src/lsp/client.cr` — `Client`: request ids and pending replies, notifications, answers to server requests, the `initialize` handshake with position-encoding negotiation, a queue for traffic sent before the server is ready, and `dispatch`, through which every callback runs.
- `src/lsp/server.cr` — `Server` (command, arguments, language id, install hint; `path`, `available?`, `spawn`), the registry of known servers per language, `LSP.search_path` (vendored servers first, then `PATH`), `register`, `server`, `servers`, `missing`, `Client.spawn_for`.
- `src/lsp/protocol.cr` — client `CAPABILITIES`, the value types (`Span`, `RemoteEdit`, `Location`, `Diagnostic`, `Completion`, `SignatureHelp`, `Rename`, `Severity`, `Sync`) and the parsers for the protocol's polymorphic fields (`markup`, `completions`, `text_edits`, `workspace_edit`, `locations`, `signature_help`).
- `src/lsp/snippet.cr` — flattens snippet syntax to plain text.
- `src/lsp/session.cr` — `Session`: one client, its open documents by URI, routing of published diagnostics; `Session.uri(path)`.
- `src/lsp/document.cr` — `Document`: the `Scribe::Listener` that sends `didOpen`/`didChange`/`didSave`/`didClose`, plus every feature request.
- `spec/spec_helper.cr` — `FakeServer`, an in-process scripted server over pipes that keeps a mirror of each synced text by applying every change in the negotiated encoding; `eventually`, `started`, `text`.
- `spec/fixtures/server.cr` — a tiny real server, built by `fixture_server` in the helper and spawned by `spec/process_spec.cr` and `spec/server_spec.cr`.
- `spec/real_server_spec.cr` — an end-to-end check against crystalline when it is installed; pending otherwise.
- `Makefile` — `spec`, and the opt-in `servers` targets that install language servers into `vendor/servers/` (git-ignored). Nothing runs them on `shards install`.

## Commands

- `crystal spec` or `make spec` — run the suite (the fixture server is compiled once, which takes a few seconds).
- `make servers` — install language servers into `vendor/servers/` (crystalline takes several minutes to build); `make status` shows what is found where.
- `crystal spec spec/document_spec.cr` — run one file.
- `crystal build --no-codegen src/lsp.cr` — fast compile check.

## Rules

- Positions sent to or read from a server go through `Scribe::Buffer#point`/`offset_at` and `Scribe::Change#start_point`/`old_end_point`/`new_end_point` with `client.encoding`. Never count characters by hand.
- Incremental ranges are computed in `Document#applied`, as each change lands, and sent in `edited`; keep that split so transactions and undo stay one `didChange` each.
- Every callback reaches the host through `Client#dispatch`. Never call host code directly from the reader fiber.
- Server replies are untrusted JSON: read optional fields with `?` accessors and fall back rather than raise.
- Edits from the server are applied with `Scribe::Document#replace_ranges`, so each server action is one undo step.
- Language servers are never bundled with or installed by the shard. A new known server is one `Server` entry in the registry in `server.cr` (with the language name `treesitter` uses and an install hint), a row in the README's server table, and, when it can be installed locally, a Makefile target that puts it under `vendor/servers/bin` or `vendor/servers/node_modules/.bin`.
- New protocol features get a method on `Document`, a parser in `protocol.cr` when the reply has more than one shape, a scripted reply in a spec, and a row in the README's feature table.

## Code standards

- Compiler-friendly, performance-focused, idiomatic and data-driven.
- The usage-facing API must be ergonomic.
- Avoid shotgun surgery: one change should land in one place.
- No comments, except every file starts with a comment containing its own path (e.g. `# src/lsp.cr`).
- Never use `out` as an identifier.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.
