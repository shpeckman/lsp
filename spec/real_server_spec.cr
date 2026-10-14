# spec/real_server_spec.cr
require "./spec_helper"

describe "a real crystal language server" do
  server = LSP.server("crystal")

  if server
    it "reports diagnostics, hover text, definitions and completions" do
      root = File.tempname("lsp-real")
      Dir.mkdir_p(File.join(root, "src"))
      path = File.join(root, "src", "app.cr")
      File.write(File.join(root, "shard.yml"), "name: app\nversion: 0.1.0\n")
      File.write(path, %(def greet(name : String) : String\n  "hi \#{name}"\nend\n\nputs greet("x")\nputs missing_name\n))
      begin
        client = server.spawn(chdir: root)
        ready  = false
        client.start(LSP::Session.uri(root)) { ready = true }
        eventually(60.seconds) { ready }

        doc    = text(File.read(path))
        synced = LSP::Session.new(client).open(doc, LSP::Session.uri(path), server.language_id)
        synced.saved
        eventually(120.seconds) { !doc.decorations.empty? }
        doc.decorations.first.kind.should eq("error")
        doc.buffer.slice_text(doc.decorations.first.range).should eq("missing_name")

        at = doc.buffer.offset(4, 7)
        doc.select_range(at, at)
        hovered = nil
        synced.hover { |found| hovered = found || "" }
        eventually(60.seconds) { hovered }
        hovered.not_nil!.should contain("greet")

        targets = nil
        synced.definition { |found| targets = found }
        eventually(60.seconds) { targets }
        targets.not_nil!.first.span.start.should eq(Scribe::Point.new(0, 4))

        doc.select_range(doc.length, doc.length)
        doc.insert("\ngre")
        items = nil
        synced.complete { |found| items = found }
        eventually(60.seconds) { items }
        item = items.not_nil!.find(&.label.starts_with?("greet")).not_nil!
        synced.accept(item)
        doc.value.lines.last.should eq("greet")

        done = false
        client.shutdown { done = true; nil }
        eventually(20.seconds) { done }
      ensure
        FileUtils.rm_rf(root)
      end
    end
  else
    pending "needs crystalline (make servers): #{LSP.missing("crystal")}"
  end
end
