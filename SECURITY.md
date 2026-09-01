# Security Policy

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security vulnerability in CapsizedMoneroKit, please report it privately by emailing:

**security@capsized.io**

Include as much of the following as possible:

- Description of the vulnerability and its potential impact
- Steps to reproduce or proof-of-concept
- Affected version(s) or commit hash
- Any suggested mitigations, if known

You will receive an acknowledgement within **48 hours**. We aim to provide a status update within **7 days** and to release a fix within **90 days** depending on severity and complexity.

## Responsible Disclosure

We ask that you:

- Give us reasonable time to investigate and fix the issue before any public disclosure
- Avoid accessing, modifying, or deleting user data during research
- Do not perform denial-of-service attacks or spam

We will credit researchers who responsibly disclose vulnerabilities in the release notes, unless you prefer to remain anonymous.

## Scope

Areas of particular concern for this library:

- Wallet key material exposure (seed, spend key, view key)
- Incorrect transaction construction or signing
- Node communication vulnerabilities (MITM, data injection)
- Seed validation bypasses that could lead to fund loss
- Storage encryption weaknesses

## Supported Versions

Only the latest tagged release is actively maintained. We recommend always using the most recent version.
