#!/bin/zsh
# Installs hid-guard + tech-alert for the current user. Does NOT load the agent (run 'hid-guard enable').
set -eu
cd "${0:A:h}"
BIN=$HOME/.local/bin LIBX=$HOME/.local/libexec/hid-guard SHARE=$HOME/.local/share/hid-guard
mkdir -p $BIN $LIBX $SHARE $HOME/.config/hid-guard $HOME/.config/tech-alerts $HOME/Library/Logs/hid-guard $HOME/Library/Logs/tech-alerts
xcrun swiftc -O -o $LIBX/hid-guard-helper hid-guard-helper.swift
codesign -s - -f -i com.dluxhu.hid-guard-helper $LIBX/hid-guard-helper
install -m 755 hid-guard $BIN/
# tech-alert goes to /usr/local/bin (shared by future scripts). /usr/local/bin is root-owned: needs sudo.
if [[ -w /usr/local/bin ]] || sudo -n true 2>/dev/null; then
  sudo install -m 755 -o root -g wheel tech-alert /usr/local/bin/tech-alert && rm -f $BIN/tech-alert
else
  install -m 755 tech-alert $BIN/
  echo "NOTE: /usr/local/bin needs sudo; installed tech-alert to $BIN instead. To move it: sudo install -m 755 -o root -g wheel tech-alert /usr/local/bin/tech-alert && rm ~/.local/bin/tech-alert"
fi
sed "s#__HOME__#$HOME#g" com.dluxhu.hid-guard.plist.in > $SHARE/com.dluxhu.hid-guard.plist
plutil -lint $SHARE/com.dluxhu.hid-guard.plist
[[ -f $HOME/.config/hid-guard/config ]] || cp hid-guard.config.default $HOME/.config/hid-guard/config
[[ -f $HOME/.config/hid-guard/allowlist.txt ]] || cp allowlist.txt.default $HOME/.config/hid-guard/allowlist.txt
[[ -f $HOME/.config/tech-alerts/config ]] || cp tech-alerts.config.default $HOME/.config/tech-alerts/config
chmod 700 $HOME/.config/tech-alerts; chmod 600 $HOME/.config/tech-alerts/config
echo "installed. agent NOT loaded. next: hid-guard dry-run; hid-guard baseline; hid-guard enable"
