# Signing identity and notary profile for `make release`:
# {
#   "signingIdentity": "Developer ID Application: ...",
#   "notaryProfile": "..."
# }
IDENTITY := release-identity.json

.PHONY: all build test release

all: test build

build:
	swift build --package-path GandalfServer -c release

# Set SCRATCH to build the Swift tests somewhere other than .build.
SCRATCH :=

test:
	swift test --package-path GandalfServer \
		$(if $(SCRATCH),--scratch-path "$(SCRATCH)")
	node --check public/app.js
	node tests/test_buildrows.js
	node tests/test_syntax.js
	node tests/test_worddiff.js
	node tests/test_filetree.js

# Set VERBOSE (e.g., `make release VERBOSE=1`) to show each step's output.
VERBOSE :=

# Extra gandalf-release flags go in ARGS, e.g. `make release ARGS=--dry-run`.
release:
	@test -f $(IDENTITY) || { echo "missing $(IDENTITY)" >&2; exit 1; }
	@identity=$$(jq -er .signingIdentity $(IDENTITY)) && \
	profile=$$(jq -er .notaryProfile $(IDENTITY)) && \
	swift run $(if $(VERBOSE),,--quiet) --package-path GandalfRelease \
		gandalf-release $(if $(VERBOSE),--verbose) \
		--signing-identity "$$identity" --notary-profile "$$profile" \
		$(ARGS)
