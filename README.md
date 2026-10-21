# hid-guard + tech-alert

Locks the Mac and sends an alert when any new HID device (keyboard, mouse, trackpad, keypad, generic HID)
appears over USB or Bluetooth/BLE.

## Design
- One compiled Swift binary (`hid-guard-helper`) runs as a per-user LaunchAgent
  (`com.dluxhu.hid-guard`, LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive), so it lives in the
  GUI session where the lock call reaches loginwindow. No root daemon and no `launchctl asuser`.
- Detection: IOKit registry class `IOHIDDevice` (covers USB `IOUSBHostHIDDevice`, classic Bluetooth
  HID drivers and BLE `IOHIDUserDevice`). Primary path: IOKit first-match/terminated notifications (event-driven).
  Resync at startup and on wake/session-active (NSWorkspace). One 30 s safety rescan timer with 20% tolerance. Reading the registry needs no TCC permission (no Input
  Monitoring, no Bluetooth).
- Identity: transport|VID|PID|product|serial|LocationID(not for Bluetooth)|usagePage:usage. RegistryID
  is not used because it changes on every boot. A trigger fires when an identity APPEARS that is not in
  the baseline or allowlist. Baseline devices that flap never trigger. Unknown devices re-trigger each
  time they reconnect. Repeat webhooks for the same device are suppressed for 60 s, but the lock
  always happens.
- Lock: `SACLockScreenImmediate` from login.framework (the same call as Ctrl-Cmd-Q / Apple menu >
  Lock Screen), resolved with dlopen/dlsym. This always requires the password, even with
  `sysadminctl -screenLock off`. The lock is verified through `CGSSessionScreenIsLocked`. If it fails,
  the fallback is an osascript Ctrl-Cmd-Q keystroke (needs Accessibility).
  `pmset displaysleepnow` is not used because it doesn't lock when the password delay is off.
  CGSession -suspend no longer exists.
- Every alert carries `detected_by`: event | backup_scan | startup_resync | wake_resync (also in summary and log).
- Order: lock, then the webhook (`tech-alert`, 8 s timeout, one try), then the log.

## Install
```sh
cd ~/Src/hid-guard-src/hid-guard && ./build.sh && sudo ./install.sh
hid-guard dry-run          # check the inventory
hid-guard baseline         # trust what is connected right now
hid-guard enable           # start it (no sudo)
```
- `./build.sh` runs as you. It compiles and ad-hoc signs into `./build/`, writes `build/SHA256SUMS`, and
  creates your config files if they are missing (root never creates config).
- `sudo ./install.sh` refuses to run without a complete `build/`. It copies the build into a root-owned temp
  dir, checks the checksums, Mach-O type, code signature and plist, then installs the files root:wheel. It never runs
  the helper or anything else from the build or your home as root. Cleanup in your home (the old
  `~/.local/{bin,libexec,share}` install) runs as you via `sudo -u`.
- The agent is installed **disabled**. install.sh runs `launchctl disable gui/<uid>/com.dluxhu.hid-guard`
  before the plist appears, and it doesn't bootstrap. `/Library/LaunchAgents` would otherwise auto-load at login.
- `hid-guard enable` = `launchctl enable` + `launchctl bootstrap gui/$UID /Library/LaunchAgents/com.dluxhu.hid-guard.plist`.
  `hid-guard disable` = `bootout` + `launchctl disable`. Both work without sudo, because a user may change their own gui domain.
- Uninstall needs sudo: `hid-guard uninstall [--purge]` (runs `sudo /usr/local/libexec/hid-guard/uninstall.sh`).

## Files
| Path | Owner / mode | What |
|---|---|---|
| /usr/local/libexec/hid-guard/hid-guard-helper | root:wheel 755 | compiled agent (ad-hoc signed `com.dluxhu.hid-guard-helper`) |
| /usr/local/libexec/hid-guard/uninstall.sh | root:wheel 755 | uninstaller (sudo) |
| /usr/local/bin/hid-guard | root:wheel 755 | control CLI |
| /usr/local/bin/tech-alert | root:wheel 755 | shared webhook sender |
| /Library/LaunchAgents/com.dluxhu.hid-guard.plist | root:wheel 644 | LaunchAgent, Aqua only, no UserName |
| ~/.config/hid-guard/{config,allowlist.txt,baseline.tsv} | you | options, trusted devices |
| ~/.config/tech-alerts/config | you, 600 | TECH_ALERT_WEBHOOK_URL / TECH_ALERT_WEBHOOK_KEY |
| ~/Library/Logs/hid-guard/, ~/Library/Logs/tech-alerts/ | you | logs, undelivered alerts |

## Security model
- **It runs as you, never as root.** It's a LaunchAgent in your GUI (Aqua) session, which it needs so it can lock the
  screen. There is no root daemon and no `UserName` key.
- **Its executables are root-owned.** That covers the helper, the CLI, tech-alert and the plist, so a process running as you can't
  replace them. The helper only runs `/usr/local/bin/tech-alert`. In `watch` mode it ignores `TECH_ALERT_BIN`, and it
  runs tech-alert through `zsh -f` with a fixed PATH, so your shell startup files aren't used.
- **Accepted limits.** A process running as you can still:
  - `launchctl disable` / `bootout` the agent, or kill it (KeepAlive restarts it after a kill, not after a bootout);
  - edit your baseline/allowlist/config, or the tech-alert config, since those live in your home on purpose.

  Protecting against that would need a root daemon. A root daemon can't lock the GUI session directly, so it
  isn't worth it here.
- **`sudo ./install.sh` itself runs as root from your checkout.** Review it, and only run it from a clone you trust.
  It uses `zsh -f` and a fixed PATH, so root never sources your shell startup files.
- **Don't commit real device data.** Real serial numbers and Bluetooth addresses must never be committed. `baseline.tsv`
  and `config` are git-ignored, and the simulation data uses fake IDs.

## tech-alert
`tech-alert --source X --summary "..." [--severity info|warning|critical] [--event E] [--field k=v]... [--json '{...}'] [--print]`
The payload always has source, severity, event, summary, host, time (ISO with offset), plus the fields.
The URL and key reach curl through a config on an fd, never argv. Exit codes: 0 sent, 3 not configured
(logged), 4 POST failed (logged to undelivered.jsonl), 2 usage.

## Commands
`hid-guard status | enable | disable | restart | dry-run | baseline | inventory | diff B C | simulate B C [--detected-by X] | allow ID | test | logs | uninstall [--purge]`
