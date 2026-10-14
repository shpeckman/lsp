# src/lsp/server.cr
module LSP
  class Server
    getter name        : String
    getter command     : String
    getter args        : Array(String)
    getter language_id : String
    getter hint        : String

    def initialize(@name : String, @command : String, args : Enumerable(String) = [] of String, *,
                   @language_id : String, @hint : String = "")
      @args = args.to_a
    end

    def path : String?
      LSP.search_path.each do |directory|
        candidate = File.join(directory, @command)
        return candidate if File::Info.executable?(candidate) && File.file?(candidate)
      end
      Process.find_executable(@command)
    end

    def available? : Bool
      !path.nil?
    end

    def spawn(*, chdir : String? = nil, env : Process::Env = nil, dispatch : Client::Dispatch = Client.immediate) : Client
      found = path || raise Error.new("#{@name} is not installed: #{@hint}")
      Client.spawn(found, @args, chdir: chdir, env: env, dispatch: dispatch)
    end

    def inspect(io : IO) : Nil
      io << "#<LSP::Server " << @name << ' ' << @command << '>'
    end
  end

  VENDOR = File.expand_path("../../vendor/servers", __DIR__)

  class_property search_path : Array(String) = [File.join(VENDOR, "bin"), File.join(VENDOR, "node_modules", ".bin")]

  @@servers : Hash(String, Array(Server)) = {
    "bash" => [
      Server.new("bash-language-server", "bash-language-server", %w(start), language_id: "shellscript",
        hint: "make servers, or npm install -g bash-language-server"),
    ],
    "c" => [
      Server.new("clangd", "clangd", language_id: "c", hint: "sudo dnf install clang-tools-extra"),
    ],
    "crystal" => [
      Server.new("crystalline", "crystalline", language_id: "crystal",
        hint: "make servers, or a crystalline release built for your Crystal version"),
    ],
    "json" => [
      Server.new("vscode-json-language-server", "vscode-json-language-server", %w(--stdio), language_id: "json",
        hint: "make servers, or npm install -g vscode-langservers-extracted"),
    ],
    "python" => [
      Server.new("pyright", "pyright-langserver", %w(--stdio), language_id: "python",
        hint: "make servers, or npm install -g pyright"),
      Server.new("pylsp", "pylsp", language_id: "python", hint: "sudo dnf install python3-lsp-server"),
    ],
  }

  def self.languages : Array(String)
    @@servers.keys
  end

  def self.servers(language : String) : Array(Server)
    @@servers[language]? || [] of Server
  end

  def self.server(language : String) : Server?
    servers(language).find(&.available?)
  end

  def self.register(language : String, server : Server, *, first : Bool = true) : Server
    list = @@servers[language] ||= [] of Server
    list.reject!(&.name.==(server.name))
    first ? list.unshift(server) : list.push(server)
    server
  end

  def self.missing(language : String) : String
    found = servers(language)
    return "no language server is known for #{language}" if found.empty?

    "no #{language} language server found; install one of: " + found.map { |server| "#{server.name} (#{server.hint})" }.join("; ")
  end

  class Client
    def self.spawn_for(language : String, *, chdir : String? = nil, env : Process::Env = nil,
                       dispatch : Dispatch = Client.immediate) : Client?
      LSP.server(language).try(&.spawn(chdir: chdir, env: env, dispatch: dispatch))
    end
  end
end
