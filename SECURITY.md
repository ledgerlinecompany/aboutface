# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in About Face, please report it privately to shane@shanedittmar.com instead of using the public issue tracker. Include a clear description of the issue, steps to reproduce it if possible, and the potential impact.

We ask that you allow time for the maintainer to assess and respond before public disclosure. We will acknowledge receipt of your report and provide updates on the status of remediation.

## Scope

The About Face app has no network entitlement. The primary security surface is local:

- **Camera access** — governed by the App Store sandbox and macOS privacy controls.
- **File parsing** — configuration and profile data are parsed from YAML files stored locally.

There are no remote services, analytics, or downloaded code to secure. The privacy claim is verifiable via `codesign -d --entitlements`.

## No Bug Bounty Program

About Face does not offer a bug bounty program. We are grateful for security reports and work to address issues promptly, but compensation is not available.
