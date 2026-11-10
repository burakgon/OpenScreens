# Security

OpenScreens handles sign-in details and gives control of other computers, so
problems with it are taken seriously.

## Reporting a vulnerability

Please report it privately, through
[GitHub's private vulnerability reporting](https://github.com/burakgon/OpenScreens/security/advisories/new),
and not in a public issue.

Say what the problem is, how to reproduce it, and what an attacker gains.
You will get an answer within a week. Once a fix is released the report is
credited to you in the release notes, unless you would rather it was not.

## What counts

- Anything that lets someone else read or change what OpenScreens stores:
  the library, saved passwords, SSH keys, trusted host keys.
- Anything a malicious or compromised server can do to the device running
  OpenScreens beyond showing a picture — crashes included.
- Anything that weakens a protection the app claims: accepting an SSH host
  key it should not, sending a secret where it should not go, leaving
  unencrypted what is said to be encrypted.

## What is by design

Standard and Full Quality sessions with a Mac do not encrypt the picture, the
clipboard or sound; only signing in and typing are protected. Sessions with a
VNC server that uses a VNC password encrypt nothing. The app says so in its
statistics overlay and the README says how to protect such sessions. Reports
that these sessions can be watched on the network describe the protocol, not
a flaw in OpenScreens.

## Supported versions

Fixes go into the latest release.
