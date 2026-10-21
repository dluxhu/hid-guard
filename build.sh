#!/bin/zsh -f
# build.sh: run as your normal user (NOT root). Compiles + ad-hoc signs into ./build/ and creates
# your per-user config files if missing. Then run: sudo ./install.sh
emulate -L zsh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
(( EUID != 0 )) || { echo "build.sh: run as your normal user, not root" >&2; exit 1; }
cd "${0:A:h}"
rm -rf build; mkdir -p build
xcrun swiftc -O -o build/hid-guard-helper hid-guard-helper.swift
codesign -s - -f -i com.dluxhu.hid-guard-helper build/hid-guard-helper
codesign -v build/hid-guard-helper
cp hid-guard tech-alert uninstall.sh build/
cp com.dluxhu.hid-guard.plist.in build/com.dluxhu.hid-guard.plist
plutil -lint build/com.dluxhu.hid-guard.plist
zsh -n build/hid-guard build/tech-alert build/uninstall.sh
( cd build && shasum -a 256 hid-guard-helper hid-guard tech-alert uninstall.sh com.dluxhu.hid-guard.plist > SHA256SUMS )
# Per-user config (never created by root). Existing files are left untouched.
mkdir -p ~/.config/hid-guard ~/.config/tech-alerts ~/Library/Logs/hid-guard ~/Library/Logs/tech-alerts
[[ -f ~/.config/hid-guard/config ]]        || cp hid-guard.config.default ~/.config/hid-guard/config
[[ -f ~/.config/hid-guard/allowlist.txt ]] || cp allowlist.txt.default ~/.config/hid-guard/allowlist.txt
[[ -f ~/.config/tech-alerts/config ]]      || cp tech-alerts.config.default ~/.config/tech-alerts/config
chmod 700 ~/.config/tech-alerts; chmod 600 ~/.config/tech-alerts/config
build/hid-guard-helper lock-check
echo "build OK in ${PWD}/build. Next: sudo ./install.sh"
