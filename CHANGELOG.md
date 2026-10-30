# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-30

### Added

- Pinned records: listed first and exempt from the 24-hour expiry (⌘P or context menu).
- Paste as plain text (⇧⏎), copy without pasting (⌘⏎).
- Paste sequentially (⌥⏎, then ⌥⇧⌘V for each next record).
- Quick Look–style preview window beside the popup (Space or ⌘Y): zoom images with pinch, ⌘+/⌘−, ⌘0 or double-click (fit ↔ actual size); larger, zoomable text.
- Text in copied images is recognized on device (Vision) and searchable; stored encrypted.
- Links and colors are recognized in the list (link icon with host, color swatch).
- Context menu on records; Settings › Clear All also removes pinned records.

### Changed

- The history popup is now truly translucent: Liquid Glass on macOS 26, behind-window vibrancy on macOS 14–15.
- Neutral row highlight and a light scrim over the glass for readability.
- Sharper text: popup frames are aligned to whole points.
- Borderless popup with cleanly clipped rounded corners and no dark outline (no dark edge pixels, no system shadow hairline).
- Clear History keeps pinned records.
- Database schema version 2 (adds the pinned flag); migrated automatically.
- CI and release builds run on `macos-26` (macOS 26 SDK).

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

[Unreleased]: https://github.com/Kamaliev/clipvault/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Kamaliev/clipvault/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Kamaliev/clipvault/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Kamaliev/clipvault/releases/tag/v0.1.0
