EMACS ?= emacs
GO ?= go
LISP := $(wildcard lisp/*.el)
TESTS := $(wildcard test/*-tests.el)

.PHONY: all deps daemon fakeclaude compile test test-lisp test-daemon vet checkdoc check clean help

all: daemon compile

## deps: download the daemon's Go modules
deps:
	cd daemon && $(GO) mod download

## daemon: build daemon/bin/claude-paird
daemon:
	cd daemon && $(GO) build -trimpath -o bin/claude-paird ./cmd/claude-paird

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
	  $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit

## test-daemon: run the daemon's Go tests with the race detector
test-daemon:
	cd daemon && $(GO) test -race -count=1 ./...

## vet: go vet, plus a gofmt check
vet:
	cd daemon && $(GO) vet ./...
	@cd daemon && unformatted="$$(gofmt -l .)" && \
	  if [ -n "$$unformatted" ]; then echo "gofmt needed:"; echo "$$unformatted"; exit 1; fi

## checkdoc: check docstrings and comments in the Emacs package
checkdoc:
	$(EMACS) -Q --batch -L lisp -l test/run-checkdoc.el $(LISP)

## test: run both test suites
test: test-daemon test-lisp

## check: vet, compile, checkdoc and test
check: vet compile checkdoc test

clean:
	rm -f lisp/*.elc test/*.elc
	rm -rf daemon/bin

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
