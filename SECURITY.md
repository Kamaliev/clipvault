# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/Kamaliev/clipvault/security/advisories/new).
Do not open a public issue.

Include the affected version, reproduction steps and the impact you have assessed.
You will receive an acknowledgement within 7 days.

## Scope

Clipvault protects clipboard history **at rest**: against disk or backup theft, other local users and
processes that merely read files. It does not and cannot protect against code running under the same
user account with access to the Keychain or the system pasteboard. Reports that assume such an
attacker are out of scope.
