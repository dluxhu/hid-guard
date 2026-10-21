#!/bin/zsh -f
# install.sh: run with sudo AFTER ./build.sh. Copies the built files to root-owned locations.
# Root only copies files here: it never executes anything from the build or from your home
# (user-side cleanup runs as you via `sudo -u`). The agent is installed DISABLED and not started;
# turn it on with `hid-guard enable`.
emulate -L zsh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022
LABEL=com.dluxhu.hid-guard
(( EUID == 0 )) || { echo "install.sh: run with sudo: sudo ./install.sh" >&2; exit 1; }
[[ -n ${SUDO_USER:-} && ${SUDO_USER} != root && -n ${SUDO_UID:-} ]] || { echo "install.sh: run via sudo from your user account" >&2; exit 1; }
SRC="${0:A:h}/build"
for f in hid-guard-helper hid-guard tech-alert uninstall.sh $LABEL.plist SHA256SUMS; do
  [[ -f $SRC/$f && ! -L $SRC/$f ]] || { echo "install.sh: missing $SRC/$f; run ./build.sh first (as your user)" >&2; exit 1; }
done
USER_HOME=$(dscl . -read /Users/$SUDO_USER NFSHomeDirectory | awk '{print $2}')

# Stage into a root-owned temp dir, then verify the staged copies (no TOCTOU against the build dir).
STAGE=$(mktemp -d /private/tmp/hid-guard-install.XXXXXX); trap 'rm -rf "$STAGE"' EXIT
for f in hid-guard-helper hid-guard tech-alert uninstall.sh $LABEL.plist SHA256SUMS; do cp "$SRC/$f" "$STAGE/$f"; done
chown -R root:wheel "$STAGE"
( cd "$STAGE" && shasum -a 256 -c SHA256SUMS >/dev/null ) || { echo "install.sh: checksum mismatch in build/; rebuild" >&2; exit 1; }
file "$STAGE/hid-guard-helper" | grep -q 'Mach-O 64-bit executable arm64' || { echo "install.sh: helper is not an arm64 Mach-O" >&2; exit 1; }
codesign -v "$STAGE/hid-guard-helper" || { echo "install.sh: helper signature invalid" >&2; exit 1; }
plutil -lint "$STAGE/$LABEL.plist" >/dev/null
[[ $(plutil -extract ProgramArguments.0 raw "$STAGE/$LABEL.plist") == /usr/local/libexec/hid-guard/hid-guard-helper ]] || { echo "install.sh: unexpected plist ProgramArguments" >&2; exit 1; }
if plutil -extract UserName raw "$STAGE/$LABEL.plist" >/dev/null 2>&1; then echo "install.sh: plist must not set UserName" >&2; exit 1; fi

# 1) Mark disabled in the user's GUI domain BEFORE the plist appears, so login won't auto-load it.
launchctl disable gui/$SUDO_UID/$LABEL
launchctl print gui/$SUDO_UID/$LABEL >/dev/null 2>&1 && launchctl bootout gui/$SUDO_UID/$LABEL 2>/dev/null || true

# 2) Copy as root:wheel.
install -d -o root -g wheel -m 755 /usr/local/bin /usr/local/libexec /usr/local/libexec/hid-guard
install -o root -g wheel -m 755 "$STAGE/hid-guard-helper" /usr/local/libexec/hid-guard/hid-guard-helper
install -o root -g wheel -m 755 "$STAGE/uninstall.sh"     /usr/local/libexec/hid-guard/uninstall.sh
install -o root -g wheel -m 755 "$STAGE/hid-guard"        /usr/local/bin/hid-guard
install -o root -g wheel -m 755 "$STAGE/tech-alert"       /usr/local/bin/tech-alert
install -o root -g wheel -m 644 "$STAGE/$LABEL.plist"     /Library/LaunchAgents/$LABEL.plist

# 3) Migration: remove the old home-dir install, as the user (not as root).
sudo -u "$SUDO_USER" /bin/rm -rf "$USER_HOME/.local/libexec/hid-guard" "$USER_HOME/.local/share/hid-guard"
sudo -u "$SUDO_USER" /bin/rm -f  "$USER_HOME/.local/bin/hid-guard" "$USER_HOME/.local/bin/tech-alert" \
                                 "$USER_HOME/Library/LaunchAgents/$LABEL.plist" "$USER_HOME/Library/LaunchAgents/com.todo-dodo.hid-guard.plist"

echo "installed (root:wheel):"
ls -l /usr/local/libexec/hid-guard/hid-guard-helper /usr/local/libexec/hid-guard/uninstall.sh /usr/local/bin/hid-guard /usr/local/bin/tech-alert /Library/LaunchAgents/$LABEL.plist
echo "agent is DISABLED and not loaded. Turn it on with: hid-guard enable"
