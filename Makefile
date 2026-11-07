EMACS   ?= emacs
PACKAGE := makeel.el

.PHONY: all check lint compile clean help

all: lint compile

check: all test

help:
	@echo "Targets:"
	@echo "  lint     Run package-lint (auto-installs from MELPA if missing)"
	@echo "  compile  Byte-compile with warnings as errors"
	@echo "  clean    Remove .elc files"
	@echo "  all      lint + compile (mirrors CI; alias: check)"
	@echo "  help     This message"
	@echo ""
	@echo "Override Emacs with EMACS=...; e.g. make compile EMACS=/usr/bin/emacs29"

lint:
	$(EMACS) --batch \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  -l package-lint \
	  -f package-lint-batch-and-exit \
	  $(PACKAGE)

compile: clean
	$(EMACS) --batch \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -L . \
	  -f batch-byte-compile $(PACKAGE)

clean:
	rm -f *.elc

ELPA_TOOLS ?= $(abspath ../elpa)
-include $(ELPA_TOOLS)/package.mk

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -l test/test-makeel.el -f ert-run-tests-batch-and-exit
