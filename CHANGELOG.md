# Changelog

Notable changes to OpenScreens. Versions follow
[Semantic Versioning](https://semver.org).

## 1.1.0

A release for iPhone and iPad, after the first use on real devices.

- **A desktop sized for the screen it is shown on.** A phone held upright
  was given a desktop 1024 points wide: text at two fifths of its size and
  about eight megapixels to send, the most a Mac will send at 60 frames a
  second. It now gets one 720 points wide, with about half the pixels and
  text half as large again. "More Space on Small Screens" brings the wider
  desktop back.
- **The picture fills the screen.** It goes down to the bottom edge instead
  of stopping above the home indicator, and starts just below where a
  screen's rounded corners would cut into the Mac's menu bar.
- **Controls that keep out of the way.** They no longer float over the
  Dock. Where a screen has a strip the picture cannot use, down the side of
  an iPhone Duo's cover display or of any iPhone on its side, they stand
  there, always in view. Anywhere else they come out of the top and are put
  away to a small handle as soon as the remote screen is touched. They can
  be moved to the bottom, or kept in view.
- **Typing without losing sight of the screen.** A keyboard or the trackpad
  deck used to shrink the picture to what was left above it. The picture now
  keeps its size and slides up to show where the pointer is.
- The trackpad deck comes out by itself only on a foldable set down like a
  laptop, not whenever it is held with a slight bend, and can be put away
  then too.
- The status bar is shown beside a sensor housing, instead of that space
  being left black.
- iPhone presents frames at the display's full refresh rate.
- The statistics say whether video is decoded in hardware.
- A Mac that will not make a desktop as small as it is asked for is noticed,
  and asked for the size every Mac gives.

## 1.0.0

The first release, for macOS 26, iOS 26 and iPadOS 26.

- Apple Screen Sharing in High Performance, Standard and Full Quality modes,
  with remote sound, a desktop sized to the window or screen, and one, all
  or two virtual displays.
- VNC servers on Windows, Linux and Raspberry Pi.
- Typing that survives a difference in keyboard layouts, with key positions
  as an option for Macs; touch and trackpad modes, gestures, hardware
  keyboards, mice, trackpads and Apple Pencil on iPhone and iPad.
- A library with groups, tags, favourites, recents, previews and search,
  synced through iCloud, with backups.
- Nearby computers through Bonjour and tailnet devices through Tailscale.
- SSH tunnels with password or key sign-in and host key verification.
- Shared clipboard, curtain mode, observe only, lock on disconnect,
  Wake-on-LAN, one-tap shortcuts, Type Text and connection statistics.
- Files copied to and from a Mac by dragging them onto and off its screen,
  and a file browser that copies files and folders both ways over SFTP.
- An app lock, a menu bar item on the Mac, `vnc://` links and Shortcuts
  actions.
