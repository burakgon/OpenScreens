# How OpenScreens is put together

One codebase builds the Mac app and the iPhone and iPad app. Almost all of it
lives in a Swift package; the app targets only create the model and show the
package's scenes.

```
Apps/
  macOS/, iOS/           @main, Info.plist, entitlements
  Shared/                Assets, App Intents
  iOSUITests/            Interface tests that drive the app with touches
Packages/OpenScreensKit/
  Sources/
    OpenScreensCore/     Everything that is not interface
    OpenScreensUI/       SwiftUI, the session controller, the two canvases
    RFBTestServer/       A small screen-sharing server for tests and demos
    DemoServer/          `openscreens-demo-server`, which runs it
  Tests/
Vendor/rootshell-vnc/    The protocol engine
```

## The layers

**The engine** (`Vendor/rootshell-vnc`) speaks RFB and Apple's Screen Sharing
extensions: authentication, the adaptive codecs of Standard mode, the HEVC
stream of High Performance mode, sound, the clipboard. It is
[rootshellVNC](https://github.com/kitknox/rootshell-vnc), vendored because
OpenScreens draws the picture in its own views and needs a few things the
package keeps to itself. The first commit under that directory is an
upstream release untouched, and a later release is taken in as one commit
named for it. Every local change is its own commit, prefixed `engine:`, so
`git log -- Vendor/rootshell-vnc` is the list of differences.

**OpenScreensCore** has no interface and no engine session in it, which is
what makes it testable:

| Folder | What is in it |
|---|---|
| `Models` | `Computer`, `ConnectionSettings` and friends. Every enum decodes leniently, so a library written by a newer version still loads. |
| `Store` | `LibraryDocument` (the file format and the merge), `LibraryStore`, preferences, and the keychain. |
| `Sync` | `CloudSyncEngine`, which mirrors the library to iCloud key-value storage. |
| `Discovery`, `Tailscale` | Finding computers: Bonjour through dns_sd, and the tailnet through Tailscale's API or local app. |
| `SSH` | Client, tunnel, SFTP, private keys, known hosts. Built on SwiftNIO SSH. |
| `Input` | Keysyms, key codes, and `HardwareKeyboard`, which decides what a key press means to the remote computer. |
| `Geometry` | `Viewport`: fit, fill, zoom, pan, and mapping a point in the view to a point of the picture. `DisplayArrangement`: where two displays go in the picture, and which remote pixel a point of it stands for. `SessionChromeLayout`: where the picture and the controls go on a touch screen, from what the screen keeps content clear of. |
| `Network` | Address parsing, links, Wake-on-LAN. |

**OpenScreensUI** is the app:

- `AppModel` owns the library, preferences, credentials, discovery, sync and
  the open sessions. There is one, shared by every window and by App
  Intents.
- `RemoteSession` sits between the interface and the engine for one
  connection. It decides when to ask for a password or show a host key,
  turns settings into an engine configuration, and is the only way input
  reaches the remote computer — which is what makes "observe only" absolute.
- `RemoteCanvas` is two views with one job, an `NSView` and a `UIView`. Each
  hosts the engine's video layers directly and turns its platform's events
  into calls on the session. Nothing about gestures or key events leaks
  above them.
- `FileBrowser` is one SSH connection to a computer for its files: it signs
  in the way a tunnel would, lists folders over SFTP and runs transfers one
  at a time. It is independent of any screen-sharing session.
- `FileTransferOverlay` is the other way files move, with a Mac: a drag onto
  the canvas is passed on as a drag on the Mac's own screen, and the engine
  copies what is dropped. The overlay shows where to drag files for copying
  them back, and each copy as it goes.

## A session, end to end

1. The library opens a `RemoteSession` for a `Computer` through
   `SessionManager`, which reuses one that is already open.
2. `start()` looks for credentials and either asks or connects. With an SSH
   tunnel it builds a transport provider from `SSHTunnelFactory`; the engine
   then makes its connection through that instead of dialling itself.
3. The canvas reports its size, and for a desktop that follows the window the
   engine asks the Mac for a virtual display of that size — or two, each half
   of it. A view smaller than a Mac's screen gets a desktop of its shape,
   scaled up to a minimum the computer's settings choose: 720 points across
   by default, 1024 for more space. A Mac does not say when it will not make
   a display that small, so once the resize has settled the session checks
   what it was given.
4. Pointer events are mapped through `Viewport` to the picture and through
   `DisplayArrangement` to remote pixels. Key events go through
   `HardwareKeyboard`.
5. Ending the session releases every key and button that is down first, so
   nothing is left stuck on the other side.

## Typing

A key press becomes a `KeyStroke`: what the key types on the local layout
with the modifiers held, what it types without Option, and which key a
Command shortcut would call it. The Mac canvas gets those from the keyboard
layout itself and combines dead keys; the iOS canvas gets them from `UIKey`.

`HardwareKeyboard` turns strokes into key events, differently for the two
kinds of remote computer:

- **A Mac** types exactly the character it is asked for, adding or cancelling
  Shift and Option to do it. So it is sent the finished character — `Ω`, not
  Option and `z` — which arrives as the same key press when the layouts
  match and as the same character when they do not. With Command held it
  leaves the modifiers alone and is sent the key the shortcut names.
- **Anything else** holds modifiers the usual RFB way. Option is Alt, but is
  only sent once something needs Alt, and never when it merely typed a
  symbol that the local layout keeps behind Option.

"Key Positions" sends virtual key codes to a Mac instead and lets its layout
decide. [apple-screen-sharing-notes.md](apple-screen-sharing-notes.md) has
the measurements behind these rules.

## The library and sync

The library is one JSON document: computers, groups, and a record of what was
deleted and when. Two copies are merged item by item — the later edit wins,
and a deletion wins over an edit made before it. The merge does not depend
on which copy is which or on the order copies arrive in, which is what lets
devices converge through a store as simple as iCloud key-value storage. A few
rules keep that honest:

- Dates are stored exactly. Rounding them could change what a merge decides
  after a relaunch.
- A change is always stamped later than what it was made from, even if that
  came from a clock running ahead.
- Connecting is not an edit. The time of the last connection is settled on
  its own, so connecting from a device that is behind cannot undo a change
  made elsewhere.
- A tie is settled by comparing the items' bytes, the same way on both
  sides.

Passwords, SSH keys and access tokens are never part of the document. They
live in the keychain, behind `SecretStorage`.

## Testing

- **Unit tests** cover Core: the merge is checked against a written-out
  specification over generated libraries, and the keyboard rules are pinned
  one by one.
- **End-to-end tests** run a real `RemoteSession` against `RFBTestServer` on
  loopback and check what arrived.
- **SSH tests** start a private, unprivileged `sshd`.
- **Interface tests** launch the iPhone app pointed at a server the test
  runs, and drive it with touches and key presses.
- **Engine tests** are upstream's, plus those for the local changes.

Debug builds read a few environment variables at launch — open this address,
type this, press these keys, write a report — so a session with a real
computer can be scripted. `DebugAutomation.swift` documents them.
