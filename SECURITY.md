# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it by emailing the maintainer directly rather than opening a public issue.

**Do NOT open a public issue for security vulnerabilities.**

When reporting, please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

You can expect a response within 48 hours. We will work with you to understand and address the issue promptly.

## Scope Notes

ask-away renders a dialog from its CLI arguments and prints the answer to stdout. Areas of concern worth reporting:

- Text passed via `--title` or `--text` escaping the panel (injection into attributed-string rendering)
- The cascade registry under `~/Library/Application Support/ask-away/`: symlink or permission attacks against the pid-named entries
- The release artifact chain: tarball integrity and the ad-hoc signature
