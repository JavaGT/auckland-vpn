#!/usr/bin/env bash
#
# auckland-vpn installer — macOS + Homebrew
# One-liner:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JavaGT/auckland-vpn/main/install.sh)"
#
# Or from a clone:
#   ./install.sh [vpn-username]
#
set -euo pipefail

REPO="JavaGT/auckland-vpn"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"

# 1. Homebrew (if missing)
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Ensure brew is on PATH for this run (Apple Silicon vs Intel)
for BREW in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$BREW" ] && ! command -v brew >/dev/null 2>&1; then
    eval "$("$BREW" shellenv)"
    break
  fi
done
command -v brew >/dev/null 2>&1 || { echo "Error: brew still not on PATH" >&2; exit 1; }

# 2. openconnect + vpnc-script (fixes DNS)
if ! command -v openconnect >/dev/null 2>&1; then
  echo "Installing openconnect..."
  brew install openconnect
else
  echo "openconnect already installed ($(openconnect --version 2>/dev/null | head -1))."
fi

# 3. Install auckland-vpn binary
BIN_DIR="$(brew --prefix)/bin"
mkdir -p "$BIN_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "$SCRIPT_DIR/auckland-vpn" ]; then
  echo "Installing auckland-vpn from local checkout..."
  cp "$SCRIPT_DIR/auckland-vpn" "$BIN_DIR/auckland-vpn"
else
  echo "Downloading auckland-vpn from github.com/$REPO..."
  curl -fsSL "$RAW_BASE/auckland-vpn" -o "$BIN_DIR/auckland-vpn"
fi
chmod +x "$BIN_DIR/auckland-vpn"
echo "Installed to $BIN_DIR/auckland-vpn"

# 4. Optional: save VPN username (./install.sh myusername)
if [ "${1:-}" != "" ]; then
  mkdir -p "$HOME/.config/auckland-vpn"
  echo "VPN_USER=$1" > "$HOME/.config/auckland-vpn/config"
  echo "Saved VPN_USER=$1 to ~/.config/auckland-vpn/config"
fi

echo ""
echo "Next:"
echo "  export VPN_USER=your_uoa_username  # skip if you passed it as arg"
echo "  auckland-vpn setup   # one-time: TOTP secret + password -> Keychain"
echo "  auckland-vpn start   # connect"
