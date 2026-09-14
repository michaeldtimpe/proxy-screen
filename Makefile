# proxy-screen convenience Makefile.
#
# Thin wrapper around boot.sh / capture.sh / pipeline.sh / bin/detect-selftest.sh.
# Does not implement any capture/boot logic itself -- see README.md for the
# full flag/env-var reference of the scripts this wraps.
#
# Vars you can pass on the command line:
#   SESSION=<name>   session name for `make capture` / `make review` / `make record`
#                    (capture.sh defaults to a UTC timestamp if unset;
#                     pipeline.sh defaults to the most recently modified
#                     session under sessions/ if unset; record REQUIRES it)
#   INTERVAL=<secs>  seconds between frames for `make record` (default: script's 5)
#   DURATION=<secs>  total run time for `make record` (default: until Ctrl-C)
#   NOTE=<text>      provenance note recorded by `make record`
#   FROM=<disk>      source disk for `make golden` (default: vm/guest.qcow2)
#   FORCE=1          let `make golden` overwrite an existing golden
#   SERIAL=<sock>    serial unix socket for `make selftest`
#                    (default: ./serial.sock)
#   LABEL=<text>     label for `make selftest`

.PHONY: help setup boot boot-gui capture record golden review selftest clean

SESSION  ?=
INTERVAL ?=
DURATION ?=
NOTE     ?=
FROM     ?=
FORCE    ?=
SERIAL   ?= serial.sock
LABEL    ?= (unlabeled)

help:
	@echo "proxy-screen -- host-side VM screen-capture tool"
	@echo ""
	@echo "Targets:"
	@echo "  make setup               Create/refresh .venv and check for required tools"
	@echo "  make boot                Headless guest boot (./boot.sh)"
	@echo "  make boot-gui            Guest boot with a visible window (DISPLAY_BACKEND=cocoa)"
	@echo "  make capture             Grab one frame from a running guest (SESSION=name optional)"
	@echo "  make record              Interval capture loop (SESSION=name required; INTERVAL/DURATION/NOTE optional)"
	@echo "  make golden              Snapshot vm/guest.qcow2 -> read-only vm/golden.qcow2 for EPHEMERAL boots (FORCE=1 to overwrite)"
	@echo "  make review              Run the OCR/dedupe/contact-sheet pipeline (SESSION=name optional)"
	@echo "  make selftest            Run the VM-detection self-test (SERIAL=sock LABEL=text)"
	@echo "  make clean               Remove qmp.sock/serial.sock and stray root *.png (not vm/, not sessions/)"
	@echo ""
	@echo "Vars: SESSION, SERIAL, LABEL -- see comments at the top of the Makefile."

setup:
	@echo "== checking required command-line tools =="
	@for tool in qemu-system-aarch64 tesseract convert montage identify ffmpeg python3; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "  OK   $$tool -> $$(command -v $$tool)"; \
		else \
			echo "  MISSING $$tool -- install it, e.g.:"; \
			case $$tool in \
				qemu-system-aarch64) echo "         brew install qemu" ;; \
				tesseract|convert|montage|identify) echo "         brew install imagemagick tesseract" ;; \
				ffmpeg) echo "         brew install ffmpeg" ;; \
				python3) echo "         brew install python3" ;; \
			esac; \
		fi; \
	done
	@echo "== venv (.venv) =="
	@if [ -x .venv/bin/python3 ] && .venv/bin/python3 -c "import imagehash, PIL" >/dev/null 2>&1; then \
		echo "  OK   .venv already has imagehash + pillow"; \
	else \
		echo "  creating/refreshing .venv ..."; \
		python3 -m venv .venv; \
		.venv/bin/pip install --quiet imagehash pillow; \
		echo "  OK   .venv ready (imagehash + pillow installed)"; \
	fi

boot:
	./boot.sh

boot-gui:
	DISPLAY_BACKEND=cocoa ./boot.sh

capture:
	./capture.sh $(if $(SESSION),--session $(SESSION))

record:
	@if [ -z "$(SESSION)" ]; then echo "make record: SESSION=<name> is required" >&2; exit 2; fi
	./record.sh --session $(SESSION) \
		$(if $(INTERVAL),--interval $(INTERVAL)) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(NOTE),--note "$(NOTE)")

golden:
	./snapshot.sh golden $(if $(FROM),--from $(FROM)) $(if $(FORCE),--force)

review:
	./pipeline.sh $(if $(SESSION),--session $(SESSION))

selftest:
	./bin/detect-selftest.sh --serial $(SERIAL) --label "$(LABEL)"

clean:
	@echo "== make clean: removing sockets and stray root PNGs (vm/ and sessions/ are never touched) =="
	@for f in qmp.sock serial.sock; do \
		if [ -e "$$f" ]; then echo "  removing $$f"; rm -f "$$f"; fi; \
	done
	@shopt_glob=$$(ls *.png 2>/dev/null); \
	if [ -n "$$shopt_glob" ]; then \
		for f in *.png; do echo "  removing $$f"; rm -f "$$f"; done; \
	else \
		echo "  no stray *.png at root"; \
	fi
