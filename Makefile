.PHONY: core app run test lint xcode clean

core:            ## Rust static lib + UniFFI Swift bindings
	./scripts/build-core.sh

app:             ## build/Clipvault.app (release, ad-hoc signed)
	./scripts/bundle-app.sh

run: app
	open build/Clipvault.app

test:
	cargo test --manifest-path core/Cargo.toml

lint:
	cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

xcode: core      ## generate app/Clipvault.xcodeproj (requires xcodegen + Xcode)
	cd app && xcodegen generate

clean:
	rm -rf build app/.build app/Clipvault.xcodeproj
	cargo clean --manifest-path core/Cargo.toml
