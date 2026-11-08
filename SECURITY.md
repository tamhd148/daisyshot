# Security policy

## Supported versions

Security fixes go into the latest release. Daisyshot updates itself (**Check for Updates…**), so please make sure
you're on the newest version before reporting.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/tamhd148/daisyshot/security/advisories/new) instead.

Include what you found, the steps to reproduce it, the Daisyshot and macOS versions, and what an attacker could do with
it. You'll get a reply as soon as possible — Daisyshot is maintained in spare time, so it may take a few days. Once a
fix is released, the report is credited to you unless you'd rather stay anonymous.

## What Daisyshot does on the network

The only connections Daisyshot makes are for updates, to GitHub:

- once a day (if **Settings › General › Check for updates automatically** is on) and whenever you choose
  **Check for Updates…**: `https://api.github.com/repos/tamhd148/daisyshot/releases/latest`;
- when you install an update: the release's `Daisyshot-<version>.zip` and `.zip.sig` from `github.com`.

An update is installed only if its archive carries a valid Ed25519 signature from the release key built into the app,
and the app inside has Daisyshot's bundle identifier and the expected version. Nothing about you, your Mac or your
files is sent.

## Scope

Of particular interest: anything that lets another app or a web page capture the screen, read files or run commands
through Daisyshot (for example through `daisyshot://` URLs or the share extensions), or that gets an unsigned update
installed.
