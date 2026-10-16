# Signing identity and notary profile for `make release`:
# {
#   "signingIdentity": "Developer ID Application: ...",
#   "notaryProfile": "..."
# }
IDENTITY := release-identity.json

.PHONY: all build test release

all: build test

build:
	swift build --package-path GandalfServer -c release

test:
	swift test --package-path GandalfServer
	node --check public/app.js
	node tests/test_buildrows.js
	node tests/test_highlight.js
	node tests/test_filetree.js

# Extra gandalf-release flags go in ARGS, e.g. `make release ARGS=--dry-run`.
release:
	@test -f $(IDENTITY) || { echo "missing $(IDENTITY)" >&2; exit 1; }
	identity=$$(jq -er .signingIdentity $(IDENTITY)) && \
	profile=$$(jq -er .notaryProfile $(IDENTITY)) && \
	swift run --package-path GandalfRelease gandalf-release \
		--signing-identity "$$identity" --notary-profile "$$profile" \
		$(ARGS)
