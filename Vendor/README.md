# Vendored dependencies

## rootshell-vnc

- Upstream: https://github.com/kitknox/rootshell-vnc
- Version: `v0.1.15` (commit `8834c77e2675f630346c1deae9dbc302ecac2848`)
- License: MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox — see
  [`rootshell-vnc/LICENSE`](rootshell-vnc/LICENSE)

`rootshellVNC` is the remote-desktop engine OpenScreens is built on: the RFB
protocol implementation, Apple Screen Sharing support (Standard and High
Performance), remote audio, and clipboard transfer.

It is vendored rather than referenced by URL because OpenScreens draws the
remote screen with its own AppKit and UIKit canvases, which need a few
presentation details the package keeps internal. The first commit that adds
this directory is an unmodified import of the upstream tag; every change after
that is a separate commit, so `git log -- Vendor/rootshell-vnc` is the complete
list of local modifications.

When updating, import the new upstream tag over this directory in one commit
and re-apply the local changes on top.
