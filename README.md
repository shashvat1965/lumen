# Lumen

A native macOS menu-bar display utility — a BetterDisplay alternative with the "Pro" features built in — plus a `lumen` CLI.

- **Brightness** for every display: built-in panel, DDC/CI for external monitors, software dimming below the panel minimum, and **XDR boost** above 100% on Liquid Retina XDR panels.
- **Brightness keys** drive the display under the pointer (external via DDC, XDR at the top of the range).
- **Resolution & refresh**, including all HiDPI modes.
- **Color modes** — link bit depth, RGB/YCbCr, full/limited range, SDR/HDR10/HLG (Apple Silicon DCP), with a 15 s auto-revert.
- **HDR** toggle and **forced HDR** for displays that don't advertise it.
- **Virtual screens** with custom sizes/HiDPI, and showing them on a physical display for flexible scaling.
- **Viewer window**: live view of any display with invert, grayscale, flip, rotate, opacity and pin.
- Enable/disable displays (session-only, auto-restored), mirroring, main display, per-display invert, grayscale, Night Shift, Dark Mode.
- Monitor controls over DDC: contrast, volume, mute, input source.

## Build

Requires macOS 26 on Apple Silicon and the Xcode command-line tools.

```sh
./build.sh                       # produces build/Lumen.app
cp -R build/Lumen.app /Applications/
ln -sf /Applications/Lumen.app/Contents/MacOS/Lumen /opt/homebrew/bin/lumen   # or Settings › Install
```

`Lumen --diagnose` prints what the app can see and control.

## CLI

```sh
lumen list
lumen info external
lumen brightness builtin 140        # >100 = XDR boost
lumen resolution external 2560x1080@100
lumen colormodes external
lumen colormode external 86         # confirm or it reverts
lumen hdr external force
lumen ddc external input hdmi1
lumen virtual add 5120x2160
lumen virtual show 1 external
lumen nightshift 60
```

Displays can be named `builtin`, `main`, `external`, an index from `lumen list`, a display ID, or part of the name. When Lumen.app is running, commands are forwarded to it so session state (XDR, dimming, invert, virtual screens) stays in one place.

## Notes

Lumen uses private macOS frameworks (DisplayServices, SkyLight, IOMobileFramebuffer, CGVirtualDisplay, CoreBrightness) loaded at runtime; a missing symbol disables a feature instead of crashing. It is not sandboxed and not intended for the App Store.

Geist and Geist Mono are bundled under the SIL Open Font License (`Resources/Fonts/OFL.txt`).
