#!/bin/sh
# Installs the standalone `lumen` CLI from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/shashvat1965/lumen/main/install-cli.sh | sh
# Set LUMEN_DEST to choose the install directory.
set -e
URL="https://github.com/shashvat1965/lumen/releases/latest/download/lumen-cli.zip"
if [ -n "$LUMEN_DEST" ]; then DEST="$LUMEN_DEST"; mkdir -p "$DEST"
elif [ -w /opt/homebrew/bin ]; then DEST=/opt/homebrew/bin
elif [ -w /usr/local/bin ]; then DEST=/usr/local/bin
else DEST="$HOME/.local/bin"; mkdir -p "$DEST"; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading lumen…"
curl -fsSL "$URL" -o "$TMP/lumen-cli.zip"
unzip -q "$TMP/lumen-cli.zip" -d "$TMP"
xattr -d com.apple.quarantine "$TMP/lumen" 2>/dev/null || true
# Don't clobber a symlink into Lumen.app.
[ -L "$DEST/lumen" ] && rm "$DEST/lumen"
install -m 755 "$TMP/lumen" "$DEST/lumen"
echo "Installed $("$DEST/lumen" version) to $DEST/lumen"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "Add $DEST to your PATH to use it.";; esac
