EMACS ?= emacs
GO ?= go
LISP := $(wildcard lisp/*.el)
TESTS := $(wildcard test/*-tests.el)

VERSION ?= $(shell sed -n 's/^var Version = "\(.*\)"/\1/p' daemon/internal/version/version.go)
DIST_TARGETS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64
LDFLAGS := -s -w -buildid= -X github.com/victory/tandem/daemon/internal/version.Version=$(VERSION)

.PHONY: all deps daemon fakeclaude compile info reference check-manual test test-lisp test-lisp-tcp test-daemon test-wine vet versions checkdoc check dist sums check-sums print-version print-go-release test-package clean help

all: daemon compile info

## reference: write doc/reference.texi, every command and option, from the code
reference:
	$(EMACS) -Q --batch -L lisp --eval '(setq load-prefer-newer t)' -l doc/gen-reference.el -f tandem-gen-reference doc/reference.texi

## info: build the manual, doc/tandem.info, and doc/dir for C-h i (needs makeinfo)
info:
	@if command -v makeinfo >/dev/null; then \
	  makeinfo --no-split -o doc/tandem.info doc/tandem.texi && \
	  rm -f doc/dir && install-info --dir-file=doc/dir doc/tandem.info >/dev/null; \
	else echo "makeinfo not found: skipping the manual (install texinfo to build it)"; fi

## check-manual: the reference matches the code, and makeinfo has nothing to say
check-manual:
	@tmp=$$(mktemp) && $(EMACS) -Q --batch -L lisp --eval '(setq load-prefer-newer t)' -l doc/gen-reference.el -f tandem-gen-reference $$tmp && \
	  if ! cmp -s $$tmp doc/reference.texi; then rm -f $$tmp; \
	    echo "doc/reference.texi is out of date: run make reference"; exit 1; fi; rm -f $$tmp
	@out=$$(makeinfo --no-split -o /dev/null doc/tandem.texi 2>&1); \
	  if [ -n "$$out" ]; then echo "$$out"; exit 1; fi; echo "manual: up to date, no warnings"

## deps: download the daemon's Go modules
deps:
	cd daemon && $(GO) mod download

## daemon: build daemon/bin/tandemd
daemon:
	cd daemon && $(GO) build -trimpath -o bin/tandemd ./cmd/tandemd

# Release binaries carry Go's standard library: build them with a Go that
# has the security fixes govulncheck asks for (see SECURITY.md). Exactly
# this one: the build is reproducible, so the release workflow, with the
# same Go, makes the very bytes whose SHA-256 the package holds.
GO_RELEASE := 1.27.4

## dist: reproducible static daemons for Linux, macOS and Windows (amd64, arm64) and SHA256SUMS in dist/
dist:
	@have="$$($(GO) env GOVERSION | sed 's/^go//')"; \
	  if [ "$$have" != "$(GO_RELEASE)" ]; then \
	    echo "make dist needs exactly Go $(GO_RELEASE), for its security fixes and so that the release"; \
	    echo "workflow builds the same bytes; this is Go $$have. With gvm: gvm install go$(GO_RELEASE)."; exit 1; fi
	rm -rf dist && mkdir -p dist
	cd daemon && for target in $(DIST_TARGETS); do \
	  os=$${target%/*}; arch=$${target#*/}; ext=; [ $$os = windows ] && ext=.exe; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch GOFLAGS= $(GO) build -trimpath -buildvcs=false -ldflags '$(LDFLAGS)' \
	    -o ../dist/tandemd-$(VERSION)-$$os-$$arch$$ext ./cmd/tandemd || exit 1; \
	done
	cd dist && if command -v sha256sum >/dev/null; then sha256sum tandemd-* > SHA256SUMS; \
	  else shasum -a 256 tandemd-* > SHA256SUMS; fi

## sums: write dist/SHA256SUMS into lisp/tandem-daemon-sums.el, which tandem-install-daemon checks downloads against
sums:
	$(EMACS) -Q --batch -l doc/gen-sums.el -f tandem-gen-sums $(VERSION) dist/SHA256SUMS lisp/tandem-daemon-sums.el

## check-sums: fail unless dist/ holds exactly the daemons whose sums lisp/tandem-daemon-sums.el holds
check-sums:
	@tmp=$$(mktemp) && $(EMACS) -Q --batch -l doc/gen-sums.el -f tandem-gen-sums $(VERSION) dist/SHA256SUMS $$tmp && \
	  if ! cmp -s $$tmp lisp/tandem-daemon-sums.el; then rm -f $$tmp; \
	    echo "dist/ does not hold the daemons lisp/tandem-daemon-sums.el is for: run make dist sums with Go $(GO_RELEASE), commit"; exit 1; fi; \
	  rm -f $$tmp; echo "dist/ matches lisp/tandem-daemon-sums.el"

## test-package: build tandem as MELPA does, install it in a fresh Emacs, install the daemon, chat (needs PACKAGE_BUILD, makeinfo)
test-package: daemon fakeclaude
	@[ -n "$(PACKAGE_BUILD)" ] || { echo "Set PACKAGE_BUILD to a checkout of github.com/melpa/package-build"; \
	  echo "(and COMPAT to the compat package's directory, on Emacs before 31)"; exit 1; }
	$(EMACS) -Q --batch -L $(PACKAGE_BUILD) $(if $(COMPAT),-L $(COMPAT)) -l test/package-e2e.el -f tandem-package-e2e

print-go-release:
	@echo $(GO_RELEASE)

## fakeclaude: build the stand-in for Claude Code that the ERT tests use
fakeclaude:
	cd daemon && $(GO) build -o bin/fakeclaude ./internal/testutil/fakeclaude

## compile: byte-compile the Emacs package, treating warnings as failures
compile:
	$(EMACS) -Q --batch -L lisp \
	  --eval '(setq byte-compile-error-on-warn t load-prefer-newer t)' \
	  -f batch-byte-compile $(LISP)

## test-lisp: run the ERT suite in batch mode against the built daemon
test-lisp: daemon fakeclaude
	$(EMACS) -Q --batch -L lisp -L test \
	  --eval '(setq load-prefer-newer t)' \
	  $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit </dev/null
	@# No stdin: a test that asks a question fails at once instead of hanging.

## test-lisp-tcp: the ERT suite with the daemon on a local TCP port, as on Windows
test-lisp-tcp: daemon fakeclaude
	TANDEM_TEST_TRANSPORT=tcp $(EMACS) -Q --batch -L lisp -L test \
	  --eval '(setq load-prefer-newer t)' \
	  $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit </dev/null

## test-daemon: run the daemon's Go tests with the race detector, the server's over TCP too
test-daemon:
	cd daemon && $(GO) test -race -count=1 ./...
	cd daemon && CPD_TEST_TCP=1 $(GO) test -race -count=1 ./internal/server

## test-wine: run the daemon's Go tests built for Windows under Wine (not a real Windows)
WINE ?= wine
WINE_DIR := $(CURDIR)/daemon/bin/wine
test-wine:
	rm -rf $(WINE_DIR)/*.exe $(WINE_DIR)/bin && mkdir -p $(WINE_DIR)/bin
	cd daemon && GOOS=windows $(GO) build -o $(WINE_DIR)/bin/fakeclaude.exe ./internal/testutil/fakeclaude
	cd daemon && GOOS=windows $(GO) build -o $(WINE_DIR)/bin/tandemd.exe ./cmd/tandemd
	cd daemon && for pkg in $$($(GO) list -f '{{if .TestGoFiles}}{{.Dir}}{{end}}' ./...); do \
	  name=$$(basename $$pkg); GOOS=windows $(GO) test -c -o $(WINE_DIR)/$$name.test.exe $$pkg || exit 1; \
	  echo "== $$name"; \
	  (cd $$pkg && WINEDEBUG=-all WINEPREFIX=$(WINE_DIR)/prefix CPD_TEST_TCP=1 \
	    CPD_TEST_BINARIES="Z:$$(echo $(WINE_DIR)/bin | tr / '\\')" \
	    timeout 600 $(WINE) $(WINE_DIR)/$$name.test.exe -test.count=1 -test.timeout=500s) || failed=1; \
	done; WINEPREFIX=$(WINE_DIR)/prefix wineserver -k 2>/dev/null; exit $${failed:-0}

## vet: go vet for Linux, macOS and Windows, plus a gofmt check
vet:
	cd daemon && $(GO) vet ./...
	cd daemon && GOOS=darwin $(GO) vet ./...
	cd daemon && GOOS=windows $(GO) vet ./...
	@cd daemon && unformatted="$$(gofmt -l .)" && \
	  if [ -n "$$unformatted" ]; then echo "gofmt needed:"; echo "$$unformatted"; exit 1; fi

## versions: check the daemon and the Emacs package carry the same version
versions:
	@package="$$(sed -n 's/^;; Version: //p' lisp/tandem.el)"; \
	  client="$$(sed -n 's/^(defconst tandem-version "\(.*\)"/\1/p' lisp/tandem-rpc.el)"; \
	  if [ "$$package" != "$(VERSION)" ] || [ "$$client" != "$(VERSION)" ]; then \
	    echo "lisp/tandem.el says $$package, tandem-rpc.el $$client, the daemon $(VERSION)"; exit 1; fi

print-version:
	@echo $(VERSION)

## checkdoc: check docstrings and comments in the Emacs package
checkdoc:
	$(EMACS) -Q --batch -L lisp -l test/run-checkdoc.el $(LISP)

## test: run both test suites, the Emacs one over a socket and over TCP
test: test-daemon test-lisp test-lisp-tcp

## check: vet, compile, checkdoc and test
check: vet versions compile checkdoc check-manual test

clean:
	rm -f lisp/*.elc test/*.elc doc/tandem.info doc/dir
	rm -rf daemon/bin dist

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
