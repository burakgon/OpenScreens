# Notes on Apple's Screen Sharing protocol

Apple's Screen Sharing is RFB with extensions, version `003.889` on the wire.
It is not documented. What follows was reverse-engineered for
interoperability while building OpenScreens, and every statement was checked
against the Screen Sharing server of macOS 27.2 by sending the messages and
logging what the remote Mac did with them. Other versions may differ.

These notes add to two fuller accounts, which are the place to start:
the engine OpenScreens uses, [rootshellVNC](https://github.com/kitknox/rootshell-vnc),
and the protocol write-up in
[zdesk](https://github.com/andrewtheguy/zdesk/blob/main/docs/apple-vnc-889.md).

All multi-byte fields are big-endian.

## What the server says it understands

`ServerInit` carries a 16-byte bitmap of the client message types the server
accepts, one bit per type, most significant bit first. OpenScreens sends an
Apple message only to a server that lists it.

## The viewer mode message

Apple's viewer sends `SetMode` once it has described itself:

```
0a 00 <mode: u16>         0 observe, 1 control, 2 control with local input inhibited
```

What it is for was not established. On macOS 27.2 a viewer that never sends
it has its key and pointer events accepted all the same, and one that sends
mode 0 — at the start or later — still has them accepted. So "observe only"
cannot be left to the server: a viewer that means to observe must not send
input in the first place. OpenScreens does not send this message.

## Version-2 key events

A plain RFB `KeyEvent` works. Apple's viewer sends something else, input
event type `0x17`:

```
17                        type
00                        flags; bit 0 set means an 8-byte timestamp follows the body
00 16                     size of what follows: 22
00 01                     version
00 0c                     subtype: key and mouse
00                        
<flags: u8>               bit 0: use the key code as given
<16 bytes>                AES-128, one block, ECB
```

The block, before encryption:

| Bytes | |
|---|---|
| 0 | `ff`: a key event |
| 1 | 1 for down, 0 for up |
| 2–5 | X11 keysym |
| 6–9 | unused |
| 10 | `00`; `ff` here makes the block a pointer event instead |
| 11 | button mask (pointer events) |
| 12–13 | keyboard type; 198 is what the server itself uses for a standard ANSI layout |
| 14–15 | macOS virtual key code |

The server checks bytes 0 and 10 after decrypting and logs "decryption
error" if either is anything but `00` or `ff`.

**The key.** The block is encrypted under the 16-byte key the authentication
exchange produced. That holds for a session whose control channel is
otherwise in the clear, which is why typing is protected even in Standard
mode. When the server announces ComCryption keys — at the start of a High
Performance session, and again whenever it renews them — it re-keys this
cipher with the new key at the same moment as the record layer. A viewer
that keeps using the authentication key gets "decryption error" for every
key press from then on.

### What the server does with a keysym

With the key-code flag clear, the server treats the keysym as the character
to produce, not the key to press:

- It finds the key that types the character on the Mac's **current keyboard
  layout** and presses it with whatever Shift and Option that takes, adding
  them for the length of the event. `A` arrives as Shift and the A key; `@`
  on a US layout as Shift and 2.
- If Shift or Option is **held** but would change the character, it cancels
  it. Option held and the keysym `z` types `z`, not `Ω`. Shift held and `a`
  types `a`. So a viewer has to send the finished character — `Ω`, `A` — and
  then the event the Mac posts is the very key press it was locally.
- With **Command** held it leaves the held modifiers alone and only looks up
  the key. Command, Option and `i` is Command-Option-I. With Control but
  not Command, Option is still cancelled, so Control-Option-F has to be sent
  as Control, Option and `ƒ`.
- A character the layout cannot type is **inserted as text**: the event is
  for virtual key 0 with the character as its Unicode string. That works in
  text fields and not for shortcuts, so Command with a Cyrillic letter does
  nothing useful on a US layout.
- Keysyms above `0x0100FFFF` — characters outside the Basic Multilingual
  Plane — are **ignored**, and sending the two halves of a surrogate pair
  produces two replacement characters. Emoji cannot be typed this way.
- X11 dead keysyms (`dead_acute` and so on) are ignored. Combining has to
  happen in the viewer.
- Caps Lock as a keysym does not change the Mac's Caps Lock.

### What the server does with a key code

With the flag set, the server posts the virtual key code as given and ignores
the keysym entirely: the keysym `a` with the key code for B types `b`. The
Mac's layout then decides what the key means, dead keys included, exactly as
for a keyboard plugged into it. Left and right modifiers keep their own key
codes.

Caps Lock is a held key here: the Mac's Caps Lock is on for as long as key
code 57 is reported down.

## Keyboard input source

```
1a 00
<size: u16>               size of what follows
00 01                     version
<length: u16>
<identifier>              UTF-8, such as com.apple.keylayout.Turkish-QWERTY-PC
```

The server switches the Mac to that input source for the session, including
one that is not among the account's enabled input sources, and switches back
when the viewer disconnects. Apple's viewer uses it to make both ends read
key codes the same way. The server also reports its own input source to the
viewer.

## Virtual displays

High Performance mode can replace the Mac's displays with virtual ones the
viewer describes, which is how a desktop follows a window:

```
1d 00
<size: u16>               size of what follows
00 01                     version
<display count: u16>      1 or 2
00 00 00 00               flags
```

then one record per display, each a fixed 156 bytes followed by its modes:

```
<record size: u16>        156 + 28 for each mode
<name>                    120 bytes, UTF-8, zero padded
<flags: u32>              bit 0: resolution may change later; bit 1: keep the refresh rate as given
<attributes: u32>
<width: f32> <height: f32>            physical size in millimetres
<maximum width: u32> <maximum height: u32>   in pixels
<current mode: u16>       index into the modes that follow
<preferred mode: u16>     index into the modes that follow
<identifier: u32>
<mode count: u16>
```

and each mode:

```
<pixel width: u32> <pixel height: u32>
<point width: u32> <point height: u32>
<refresh rate: f64>
<flags: u32>              bit 0: HDR
```

A display is HiDPI when its pixel size is exactly twice its point size.

The two mode indexes are easy to take for a position, and with one display
it makes no difference, since both are zero either way. With two it does:
the server checks each index against the mode count, and when one is out
of range it logs `N is not a valid current display mode index`, creates no
display at all, stops the video it was sending and says nothing to the
viewer. Nothing in the message places a display. The server puts the second
to the right of the first and reports where both are in the display
information that follows, then offers a second video stream for it.

The name is what the Mac shows for the display in its Displays settings.

## What this means for a viewer

Sending characters makes typing independent of the two layouts and costs
nothing when they match, because the server maps a character straight back
to its key. Sending key codes is faithful to the keyboard and puts the
remote layout in charge. OpenScreens does the first by default and offers
the second.
