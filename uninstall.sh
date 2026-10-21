#!/bin/zsh -f
# uninstall.sh: sudo /usr/local/libexec/hid-guard/uninstall.sh [--purge]   (or: hid-guard uninstall [--purge])
# Removes the root-owned hid-guard files. tech-alert (shared) stays. --purge also deletes your hid-guard config and logs.
emulate -L zsh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LABEL=com.dluxhu.hid-guard
(( EUID == 0 )) || { echo "uninstall needs sudo: sudo /usr/local/libexec/hid-guard/uninstall.sh ${1:-}" >&2; exit 1; }
[[ -n ${SUDO_USER:-} && -n ${SUDO_UID:-} ]] || { echo "run via sudo from your user account" >&2; exit 1; }
launchctl bootout gui/$SUDO_UID/$LABEL 2>/dev/null || true
launchctl disable gui/$SUDO_UID/$LABEL
rm -f /Library/LaunchAgents/$LABEL.plist /usr/local/bin/hid-guard /usr/local/libexec/hid-guard/hid-guard-helper /usr/local/libexec/hid-guard/uninstall.sh
rmdir /usr/local/libexec/hid-guard 2>/dev/null || true
if [[ ${1:-} == --purge ]]; then
  USER_HOME=$(dscl . -read /Users/$SUDO_USER NFSHomeDirectory | awk '{print $2}')
  sudo -u "$SUDO_USER" /bin/rm -rf "$USER_HOME/.config/hid-guard" "$USER_HOME/Library/Logs/hid-guard"
fi
echo "hid-guard uninstalled (/usr/local/bin/tech-alert and ~/.config/tech-alerts left in place)"
