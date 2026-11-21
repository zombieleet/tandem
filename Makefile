EMACS ?= emacs
GO ?= go
LISP := $(wildcard lisp/*.el)
TESTS := $(wildcard test/*-tests.el)

VERSION ?= $(shell sed -n 's/^var Version = "\(.*\)"/\1/p' daemon/internal/version/version.go)
DIST_TARGETS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64
LDFLAGS := -s -w -X github.com/victory/claude-pair/daemon/internal/version.Version=$(VERSION)

.PHONY: all deps daemon fakeclaude compile test test-lisp test-daemon vet versions checkdoc check dist print-version clean help

all: daemon compile

## deps: download the daemon's Go modules
deps:
	cd daemon && $(GO) mod download

## daemon: build daemon/bin/claude-paird
daemon:
	cd daemon && $(GO) build -trimpath -o bin/claude-paird ./cmd/claude-paird

## dist: static daemons for Linux and macOS (amd64, arm64) and SHA256SUMS in dist/
dist:
	rm -rf dist && mkdir -p dist
	cd daemon && for target in $(DIST_TARGETS); do \
	  os=$${target%/*}; arch=$${target#*/}; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch $(GO) build -trimpath -ldflags '$(LDFLAGS)' \
	    -o ../dist/claude-paird-$(VERSION)-$$os-$$arch ./cmd/claude-paird || exit 1; \
	done
	cd dist && if command -v sha256sum >/dev/null; then sha256sum claude-paird-* > SHA256SUMS; \
	  else shasum -a 256 claude-paird-* > SHA256SUMS; fi

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

## test-daemon: run the daemon's Go tests with the race detector
test-daemon:
	cd daemon && $(GO) test -race -count=1 ./...

## vet: go vet, plus a gofmt check
vet:
	cd daemon && $(GO) vet ./...
	@cd daemon && unformatted="$$(gofmt -l .)" && \
	  if [ -n "$$unformatted" ]; then echo "gofmt needed:"; echo "$$unformatted"; exit 1; fi

## versions: check the daemon and the Emacs package carry the same version
versions:
	@package="$$(sed -n 's/^;; Version: //p' lisp/claude-pair.el)"; \
	  client="$$(sed -n 's/^(defconst claude-pair-version "\(.*\)"/\1/p' lisp/claude-pair-rpc.el)"; \
	  if [ "$$package" != "$(VERSION)" ] || [ "$$client" != "$(VERSION)" ]; then \
	    echo "lisp/claude-pair.el says $$package, claude-pair-rpc.el $$client, the daemon $(VERSION)"; exit 1; fi

print-version:
	@echo $(VERSION)

## checkdoc: check docstrings and comments in the Emacs package
checkdoc:
	$(EMACS) -Q --batch -L lisp -l test/run-checkdoc.el $(LISP)

## test: run both test suites
test: test-daemon test-lisp

## check: vet, compile, checkdoc and test
check: vet versions compile checkdoc test

clean:
	rm -f lisp/*.elc test/*.elc
	rm -rf daemon/bin dist

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
