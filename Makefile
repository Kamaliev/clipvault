.PHONY: core app run test lint xcode clean

core:            ## Rust static lib + UniFFI Swift bindings
	./scripts/build-core.sh

app:             ## build/pb-window.app (release, ad-hoc signed)
	./scripts/bundle-app.sh

run: app
	open build/pb-window.app

test:
	cargo test --manifest-path core/Cargo.toml

lint:
	cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

xcode: core      ## generate app/PbWindow.xcodeproj (requires xcodegen + Xcode)
	cd app && xcodegen generate

clean:
	rm -rf build app/.build app/PbWindow.xcodeproj
	cargo clean --manifest-path core/Cargo.toml
