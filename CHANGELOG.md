# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-10-30

### Added

- Launch at login toggle (Settings and menu bar), backed by `SMAppService`.

## [0.1.0] - 2026-10-30

### Added

- Encrypted 24-hour clipboard history for macOS (Rust core, SwiftUI front end).
- Text, RTF, HTML, image and file-list capture with full representation restore on paste.
- Global hotkey (default ⇧⌘V), search, keyboard navigation, optional auto-paste.
- Per-record XChaCha20-Poly1305 encryption with a master key stored in the macOS Keychain.
- Password-manager concealed/transient content is ignored.
- Homebrew cask distribution via `Kamaliev/tap`.

[Unreleased]: https://github.com/Kamaliev/clipvault/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Kamaliev/clipvault/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Kamaliev/clipvault/releases/tag/v0.1.0
