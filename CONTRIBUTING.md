# Contributing

## Prerequisites

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Rust stable (`rustup`), with `rustfmt` and `clippy`

## Workflow

```sh
make lint   # rustfmt check + clippy with -D warnings
make test   # Rust core tests
make app    # build/Clipvault.app
```

CI runs the same targets. Pull requests must pass CI.

## Guidelines

- Keep changes focused. Unrelated refactoring belongs in a separate pull request.
- Platform logic (pasteboard, hotkeys, Keychain, windows) lives in `app/`; storage, cryptography,
  retention and search live in `core/`. Do not duplicate logic across the boundary.
- Any change to the on-disk format or the cryptographic scheme must be described in the pull request
  and must include a migration or an explicit reset.
- Add or update tests in `core/tests` for behavior changes in the core.
- Do not add dependencies without a justification in the pull request description.

## Security

Do not open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
