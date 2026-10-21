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

## Files (installed by install.sh)
- ~/.local/bin/hid-guard (control CLI); /usr/local/bin/tech-alert (shared webhook sender; needs sudo, falls back to ~/.local/bin/tech-alert)
- ~/.local/libexec/hid-guard/hid-guard-helper (compiled, ad-hoc signed)
- ~/.local/share/hid-guard/com.dluxhu.hid-guard.plist (copied to ~/Library/LaunchAgents only by `enable`)
- ~/.config/hid-guard/{config,allowlist.txt,baseline.tsv}
- ~/.config/tech-alerts/config (600): TECH_ALERT_WEBHOOK_URL / TECH_ALERT_WEBHOOK_KEY
- Logs: ~/Library/Logs/hid-guard/hid-guard.log, ~/Library/Logs/tech-alerts/{tech-alert.log,undelivered.jsonl}

## tech-alert
`tech-alert --source X --summary "..." [--severity info|warning|critical] [--event E] [--field k=v]... [--json '{...}'] [--print]`
The payload always has source, severity, event, summary, host, time (ISO with offset), plus the fields.
The URL and key reach curl through a config on an fd, never argv. Exit codes: 0 sent, 3 not configured
(logged), 4 POST failed (logged to undelivered.jsonl), 2 usage.

## Commands
`hid-guard status | enable | disable | restart | dry-run | baseline | inventory | diff B C | simulate B C | allow ID | test | logs | uninstall [--purge]`
