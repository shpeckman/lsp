# Makefile
CRYSTAL         ?= crystal
SHARDS          ?= shards
NPM             ?= npm
GIT             ?= git
SERVERS         ?= vendor/servers
CRYSTALLINE_URL ?= https://github.com/elbywan/crystalline.git
CRYSTALLINE_REF ?= master
NODE_SERVERS    ?= pyright bash-language-server vscode-langservers-extracted
CRYSTAL_FLAGS   ?=

.PHONY: servers crystalline node-servers clangd pylsp status clean-servers spec

spec:
	$(CRYSTAL) spec

servers: crystalline node-servers clangd pylsp status

crystalline: $(SERVERS)/bin/crystalline

$(SERVERS)/bin/crystalline:
	mkdir -p $(SERVERS)/src $(SERVERS)/bin
	test -d $(SERVERS)/src/crystalline || $(GIT) clone $(CRYSTALLINE_URL) $(SERVERS)/src/crystalline
	cd $(SERVERS)/src/crystalline && $(GIT) fetch --tags && $(GIT) checkout $(CRYSTALLINE_REF)
	cd $(SERVERS)/src/crystalline && $(SHARDS) install
	cd $(SERVERS)/src/crystalline && $(CRYSTAL) build src/crystalline.cr -o $(abspath $@) --release --no-debug -Dpreview_mt $(CRYSTAL_FLAGS)

node-servers:
	mkdir -p $(SERVERS)
	$(NPM) install --prefix $(SERVERS) --no-fund --no-audit $(NODE_SERVERS)

clangd:
	@command -v clangd >/dev/null || echo "clangd is not installed: sudo dnf install clang-tools-extra"

pylsp:
	@command -v pylsp >/dev/null || echo "pylsp is not installed (optional, pyright comes first): sudo dnf install python3-lsp-server"

status:
	@for name in crystalline clangd pyright-langserver pylsp bash-language-server vscode-json-language-server; do \
		if [ -x $(SERVERS)/bin/$$name ] || [ -x $(SERVERS)/node_modules/.bin/$$name ]; then echo "$$name: vendored"; \
		elif command -v $$name >/dev/null; then echo "$$name: $$(command -v $$name)"; \
		else echo "$$name: missing"; fi; \
	done

clean-servers:
	rm -rf $(SERVERS)
