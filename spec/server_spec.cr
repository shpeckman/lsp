# spec/server_spec.cr
require "./spec_helper"

private def executable(directory : String, name : String, mode : Int32 = 0o755) : String
  path = File.join(directory, name)
  File.write(path, "#!/bin/sh\n")
  File.chmod(path, mode)
  path
end

describe LSP::Server do
  it "knows a server for each bundled language, preferred one first" do
    (%w(bash c crystal json python) - LSP.languages).should be_empty
    LSP.servers("python").map(&.name).should eq(%w(pyright pylsp))
    LSP.servers("python").first.args.should eq(%w(--stdio))
    LSP.servers("bash").first.language_id.should eq("shellscript")
    LSP.servers("cobol").should be_empty
  end

  it "looks in the search path before PATH and skips files it cannot run" do
    directory = File.tempname("lsp-servers")
    Dir.mkdir_p(directory)
    begin
      found = executable(directory, "fake-lsp")
      executable(directory, "plain-file", 0o644)
      with_search_path([File.join(directory, "missing"), directory]) do
        LSP::Server.new("fake", "fake-lsp", language_id: "toy").path.should eq(found)
        LSP::Server.new("plain", "plain-file", language_id: "toy").available?.should be_false
        LSP::Server.new("shell", "sh", language_id: "toy").path.should eq(Process.find_executable("sh"))
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "picks the first available server and explains what is missing" do
    absent  = LSP::Server.new("absent", "lsp-spec-absent", language_id: "toy", hint: "install absent")
    present = LSP::Server.new("present", "sh", language_id: "toy", hint: "install present")
    LSP.register("toy", present)
    LSP.register("toy", absent)
    LSP.servers("toy").map(&.name).should eq(%w(absent present))
    LSP.server("toy").should be(present)
    LSP.missing("toy").should eq("no toy language server found; install one of: absent (install absent); present (install present)")
    LSP.missing("cobol").should eq("no language server is known for cobol")
    LSP.register("toy", LSP::Server.new("absent", "lsp-spec-absent-2", language_id: "toy"), first: false)
    LSP.servers("toy").map(&.command).should eq(%w(sh lsp-spec-absent-2))
    expect_raises(LSP::Error, /absent is not installed/) { absent.spawn }
    LSP::Client.spawn_for("cobol").should be_nil
  end

  it "spawns the server it finds and talks to it" do
    server = LSP::Server.new("fixture", File.basename(fixture_server), language_id: "plaintext")
    with_search_path([File.dirname(fixture_server)]) do
      LSP.register("fixture-language", server)
      client = LSP::Client.spawn_for("fixture-language").not_nil!
      ready  = false
      client.start(LSP::Session.uri(Dir.current)) { ready = true }
      eventually(30.seconds) { ready }
      done = false
      client.shutdown { done = true; nil }
      eventually { done }
    end
  end
end
