.PHONY: core app run dist test lint fmt xcode clean

VERSION ?= $(shell git describe --tags --always 2>/dev/null)

core:            ## Rust static lib + UniFFI Swift bindings
	./scripts/build-core.sh

app:             ## build/Clipvault.app (release, ad-hoc signed unless SIGN_IDENTITY is set)
	VERSION=$(VERSION) ./scripts/bundle-app.sh

run: app
	open build/Clipvault.app

dist:            ## build/Clipvault-<version>.zip (universal binary)
	UNIVERSAL=1 VERSION=$(VERSION) ./scripts/bundle-app.sh
	cd build && rm -f Clipvault-*.zip && ditto -c -k --keepParent Clipvault.app Clipvault-$(VERSION:v%=%).zip
	cd build && shasum -a 256 Clipvault-$(VERSION:v%=%).zip

test:
	cargo test --manifest-path core/Cargo.toml

lint:
	cargo fmt --manifest-path core/Cargo.toml --check
	cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

fmt:
	cargo fmt --manifest-path core/Cargo.toml

xcode: core      ## generate app/Clipvault.xcodeproj (requires xcodegen + Xcode)
	cd app && xcodegen generate

clean:
	rm -rf build app/.build app/Clipvault.xcodeproj
	cargo clean --manifest-path core/Cargo.toml
