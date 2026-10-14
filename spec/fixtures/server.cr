# spec/fixtures/server.cr
require "../../src/lsp"

transport = LSP::Transport.new(STDIN, STDOUT)

while body = transport.read
  message = JSON.parse(body)
  method  = message["method"]?.try(&.as_s?)
  id      = message["id"]?

  case method
  when "initialize"
    transport.write({jsonrpc: "2.0", id: id, result: {capabilities: {textDocumentSync: 2, positionEncoding: "utf-8"}}}.to_json)
  when "textDocument/didOpen"
    document = message["params"]["textDocument"]
    word     = document["text"].as_s.split(' ').first
    transport.write({jsonrpc: "2.0", method: "textDocument/publishDiagnostics", params: {
      uri:         document["uri"].as_s,
      diagnostics: [{range: {start: {line: 0, character: 0}, end: {line: 0, character: word.bytesize}}, severity: 2, message: "first word"}],
    }}.to_json)
  when "shutdown"
    transport.write({jsonrpc: "2.0", id: id, result: nil}.to_json)
  when "exit"
    exit 0
  end
end
