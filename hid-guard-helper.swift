// hid-guard-helper: detect newly connected HID devices (USB + Bluetooth/BLE), lock the screen, alert.
// Runs as a per-user LaunchAgent in the Aqua (GUI) session so the lock call reaches loginwindow.
// Build: swiftc -O -o hid-guard-helper hid-guard-helper.swift
import Foundation
import IOKit
import CoreGraphics
import AppKit   // NSWorkspace wake / session-active notifications (no NSApplication needed)

let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ProcessInfo.processInfo.environment
let cfgDir = env["HID_GUARD_CONFIG_DIR"] ?? home + "/.config/hid-guard"
let logDir = env["HID_GUARD_LOG_DIR"] ?? home + "/Library/Logs/hid-guard"
let baselinePath = cfgDir + "/baseline.tsv"
let allowPath = cfgDir + "/allowlist.txt"
let configPath = cfgDir + "/config"
let techAlertBin = env["TECH_ALERT_BIN"] ?? (FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tech-alert") ? "/usr/local/bin/tech-alert" : home + "/.local/bin/tech-alert")
let loginFramework = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
let host: String = { let h = ProcessInfo.processInfo.hostName; return h.hasSuffix(".local") ? String(h.dropLast(6)) : h }()

// MARK: - utilities
func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f.string(from: Date())
}
func clean(_ s: String) -> String {
    String(s.map { ($0 == "\t" || $0 == "\n" || $0 == "\r") ? " " : $0 })
}
func hex(_ v: Int, _ w: Int = 4) -> String { String(format: "0x%0\(w)x", v) }
func appendLine(_ path: String, _ line: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); h.closeFile() }
}
func log(_ msg: String) {
    let line = "\(isoNow()) \(msg)"
    appendLine(logDir + "/hid-guard.log", line)
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

// MARK: - config
struct Config {
    var ignoreTransports: Set<String> = []      // lowercased; e.g. "virtual"
    var ignoreBuiltinInternal = true            // ignore Built-In=Yes devices whose transport is not USB/Bluetooth
    var pollSeconds = 30.0                     // safety rescan only; IOKit notifications are primary
    var lockEnabled = true
    var dedupSeconds = 60.0
}
func loadConfig() -> Config {
    var c = Config()
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return c }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || !line.contains("=") { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        let k = parts[0], v = parts.count > 1 ? parts[1] : ""
        switch k {
        case "HID_GUARD_IGNORE_TRANSPORTS":
            c.ignoreTransports = Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        case "HID_GUARD_IGNORE_BUILTIN_INTERNAL": c.ignoreBuiltinInternal = (v != "0")
        case "HID_GUARD_POLL_SECONDS": c.pollSeconds = max(5, Double(v) ?? 30)
        case "HID_GUARD_LOCK": c.lockEnabled = (v != "0")
        case "HID_GUARD_ALERT_DEDUP_SECONDS": c.dedupSeconds = Double(v) ?? 60
        default: break
        }
    }
    return c
}

// MARK: - device model
struct Dev {
    var cls = "", transport = "", product = "", manufacturer = "", serial = ""
    var vid = 0, pid = 0, loc = 0, page = 0, usage = 0
    var builtin = false
    var isBluetooth: Bool { transport.lowercased().contains("bluetooth") }
    var isExternalTransport: Bool { isBluetooth || transport.lowercased().hasPrefix("usb") }
    // Stable identity: no RegistryID (changes every boot). LocationID only for non-Bluetooth
    // (USB port path; distinguishes two identical serial-less keyboards). Bluetooth uses serial/address.
    var identity: String {
        [transport, hex(vid), hex(pid), product, serial, isBluetooth ? "" : hex(loc, 8), "\(page):\(usage)"].map(clean).joined(separator: "|")
    }
    var group: String { [transport, hex(vid), hex(pid), product].joined(separator: "|") }
    var kind: String {
        if page == 1 { switch usage { case 2: return "mouse"; case 6: return "keyboard"; case 7: return "keypad"; case 1: return "pointer"; case 4, 5: return "game controller"; default: break } }
        if page == 13 { return "touch/trackpad/digitizer" }
        if page == 12 { return "consumer control" }
        return "generic HID (page \(page))"
    }
    var tsv: String {
        [identity, cls, transport, hex(vid), hex(pid), "\(page)", "\(usage)", builtin ? "1" : "0", product, manufacturer, serial, hex(loc, 8)].map(clean).joined(separator: "\t")
    }
    init() {}
    init?(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 12, !line.hasPrefix("#") else { return nil }
        cls = f[1]; transport = f[2]
        vid = Int(f[3].dropFirst(2), radix: 16) ?? 0; pid = Int(f[4].dropFirst(2), radix: 16) ?? 0
        page = Int(f[5]) ?? 0; usage = Int(f[6]) ?? 0; builtin = f[7] == "1"
        product = f[8]; manufacturer = f[9]; serial = f[10]; loc = Int(f[11].dropFirst(2), radix: 16) ?? 0
    }
}
let tsvHeader = "#identity\tclass\ttransport\tvendor_id\tproduct_id\tusage_page\tusage\tbuilt_in\tproduct\tmanufacturer\tserial\tlocation_id"

func devFrom(_ s: io_service_t) -> Dev {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0)
    let d = (props?.takeRetainedValue() as? [String: Any]) ?? [:]
    var name = [CChar](repeating: 0, count: 128)
    IOObjectGetClass(s, &name)
    func str(_ k: String) -> String {
        if let v = d[k] as? String { return v }
        if let v = d[k] as? NSNumber { return v.stringValue }
        return ""
    }
    func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
    var x = Dev()
    x.cls = String(cString: name)
    x.transport = str("Transport").isEmpty ? "(none)" : str("Transport")
    x.product = str("Product"); x.manufacturer = str("Manufacturer")
    x.serial = str("SerialNumber").isEmpty ? str("PhysicalDeviceUniqueID") : str("SerialNumber")
    x.vid = int("VendorID"); x.pid = int("ProductID"); x.loc = int("LocationID")
    x.page = int("PrimaryUsagePage"); x.usage = int("PrimaryUsage")
    x.builtin = (d["Built-In"] as? NSNumber)?.boolValue ?? false
    return x
}
func enumerate() -> [Dev] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [Dev] = []
    while true {
        let s = IOIteratorNext(it)
        if s == 0 { break }
        out.append(devFrom(s)); IOObjectRelease(s)
    }
    return out
}
func readTSV(_ path: String) -> [Dev]? {
    guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return t.split(separator: "\n").compactMap { Dev(tsv: String($0)) }
}
func writeTSV(_ devs: [Dev], _ path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let body = ([tsvHeader] + devs.map { $0.tsv }).joined(separator: "\n") + "\n"
    try body.write(toFile: path, atomically: true, encoding: .utf8)
}
// allowlist lines: full identity, or "vid:pid" (e.g. 0x004c:0x029f), or "serial:<serial/address>"
func loadAllow() -> [String] {
    guard let t = try? String(contentsOfFile: allowPath, encoding: .utf8) else { return [] }
    return t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
}
func allowed(_ d: Dev, _ allow: [String]) -> Bool {
    for a in allow {
        if a == d.identity { return true }
        if a.lowercased() == "\(hex(d.vid)):\(hex(d.pid))" { return true }
        if a.hasPrefix("serial:"), !d.serial.isEmpty, a.dropFirst(7).lowercased() == d.serial.lowercased() { return true }
    }
    return false
}

enum Verdict: String { case trigger, baseline, allowlisted, ignoredTransport = "ignored_transport", ignoredBuiltin = "ignored_builtin_internal" }
func classify(_ d: Dev, baseline: Set<String>, allow: [String], cfg: Config) -> Verdict {
    if baseline.contains(d.identity) { return .baseline }
    if allowed(d, allow) { return .allowlisted }
    if cfg.ignoreTransports.contains(d.transport.lowercased()) { return .ignoredTransport }
    if cfg.ignoreBuiltinInternal && d.builtin && !d.isExternalTransport { return .ignoredBuiltin }
    return .trigger
}

// MARK: - locking
func screenLocked() -> Bool? {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
}
typealias SACFn = @convention(c) () -> Int32
func resolveSAC() -> (SACFn?, String) {
    guard let h = dlopen(loginFramework, RTLD_NOW) else { return (nil, "dlopen failed: " + String(cString: dlerror())) }
    guard let sym = dlsym(h, "SACLockScreenImmediate") else { return (nil, "dlsym SACLockScreenImmediate = NULL") }
    return (unsafeBitCast(sym, to: SACFn.self), "SACLockScreenImmediate resolved at \(sym)")
}
func waitLocked(_ secs: Double) -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if screenLocked() == true { return true }; usleep(100_000) }
    return screenLocked() == true
}
// Returns lock_result string.
func lockScreen() -> String {
    if screenLocked() == true { return "already_locked" }
    let (fn, msg) = resolveSAC()
    if let fn = fn {
        let r = fn()
        if waitLocked(3) { return "locked" }
        log("SACLockScreenImmediate returned \(r) but session not reported locked; trying keystroke fallback")
    } else { log("lock: \(msg); trying keystroke fallback") }
    // Fallback: Ctrl-Cmd-Q via System Events (needs Accessibility permission for this helper).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"]
    try? p.run(); p.waitUntilExit()
    if waitLocked(3) { return "locked_via_keystroke" }
    return screenLocked() == nil ? "failed_no_gui_session" : "failed"
}

// MARK: - alerting
func runTechAlert(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [techAlertBin] + args
    do { try p.run() } catch { log("tech-alert launch failed: \(error)"); return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}
func alertResultName(_ rc: Int32) -> String {
    switch rc { case 0: return "sent"; case 3: return "skipped_not_configured"; case 4: return "post_failed_logged"; default: return "error_rc_\(rc)" }
}

var lastAlert: [String: Date] = [:]
// lock first, then notify, then log
let detectedByText = ["event": "caught by IOKit event", "backup_scan": "caught by backup scan",
                      "startup_resync": "caught by startup resync", "wake_resync": "caught by wake resync"]
func handleTriggers(_ trig: [Dev], cfg: Config, simulate: Bool, detectedBy: String) {
    let lockResult: String = simulate ? "skipped_simulation" : (cfg.lockEnabled ? lockScreen() : "disabled_by_config")
    var groups: [String: [Dev]] = [:]
    var order: [String] = []
    for d in trig { if groups[d.group] == nil { order.append(d.group) }; groups[d.group, default: []].append(d) }
    for g in order {
        let ds = groups[g]!, d = ds[0]
        let kinds = Array(Set(ds.map { $0.kind })).sorted().joined(separator: "+")
        let name = d.product.isEmpty ? "(unnamed)" : d.product
        var alertRes = "deduplicated"
        if simulate || Date().timeIntervalSince(lastAlert[g] ?? .distantPast) > cfg.dedupSeconds {
            lastAlert[g] = Date()
            let summary = (simulate ? "SIMULATION: " : "") + "New \(d.transport) HID device on \(host): \(name) [\(kinds)] \(hex(d.vid)):\(hex(d.pid)), screen \(lockResult) (\(detectedByText[detectedBy] ?? detectedBy))"
            let rc = runTechAlert(["--source", "hid-guard",
                                   "--severity", simulate ? "info" : "critical",
                                   "--event", simulate ? "test" : "hid_connected",
                                   "--summary", summary,
                                   "--field", "device_name=\(name)",
                                   "--field", "vendor_id=\(hex(d.vid))",
                                   "--field", "product_id=\(hex(d.pid))",
                                   "--field", "transport=\(d.transport)",
                                   "--field", "device_kind=\(kinds)",
                                   "--field", "lock_result=\(lockResult)",
                                   "--field", "detected_by=\(detectedBy)"])
            alertRes = alertResultName(rc)
        }
        log("\(simulate ? "SIMULATED " : "")TRIGGER group=\(g) interfaces=\(ds.count) kind=\(kinds) detected_by=\(detectedBy) lock_result=\(lockResult) alert=\(alertRes)")
        for x in ds { log("  identity=\(x.identity) class=\(x.cls)") }
    }
}

// MARK: - commands
func printInventory(_ devs: [Dev], baseline: Set<String>?, allow: [String], cfg: Config) {
    print("HID inventory on \(host) at \(isoNow()): \(devs.count) IOHIDDevice entries")
    for d in devs.sorted(by: { $0.identity < $1.identity }) {
        let v = baseline.map { classify(d, baseline: $0, allow: allow, cfg: cfg).rawValue } ?? "(no baseline)"
        func pad(_ x: String, _ n: Int) -> String { x.count >= n ? x : x + String(repeating: " ", count: n - x.count) }
        print("  " + pad(v, 25) + pad(d.transport, 22) + pad("\(hex(d.vid)):\(hex(d.pid))", 14) + pad(d.product.isEmpty ? "(unnamed)" : d.product, 28) + pad(d.kind, 26) + "built-in=\(d.builtin ? "yes" : "no") class=\(d.cls)")
    }
    let bt = devs.filter { $0.isBluetooth }.count, usb = devs.filter { $0.transport.lowercased().hasPrefix("usb") }.count
    print("  -> USB HID entries: \(usb), Bluetooth/BLE HID entries: \(bt)")
}

func diffCmd(baseFile: String, curFile: String, simulate: Bool, detectedBy: String = "event") -> Int32 {
    guard let base = readTSV(baseFile), let cur = readTSV(curFile) else { print("cannot read \(baseFile) or \(curFile)"); return 2 }
    let cfg = loadConfig(), allow = loadAllow(), bset = Set(base.map { $0.identity })
    var trig: [Dev] = []
    print("Diff: baseline=\(base.count) entries, current=\(cur.count) entries")
    for d in cur {
        let v = classify(d, baseline: bset, allow: allow, cfg: cfg)
        if v != .baseline { print("  \(v.rawValue): \(d.transport) \(hex(d.vid)):\(hex(d.pid)) \(d.product) [\(d.kind)]") }
        if v == .trigger { trig.append(d) }
    }
    print(trig.isEmpty ? "Result: nothing would trigger." : "Result: WOULD TRIGGER on \(trig.count) entr\(trig.count == 1 ? "y" : "ies") (lock -> notify -> log).")
    if simulate && !trig.isEmpty { handleTriggers(trig, cfg: cfg, simulate: true, detectedBy: detectedBy) }
    return trig.isEmpty ? 0 : 1
}

var scanHandler: ((String) -> Void)?
var scanPending = false
let matchCB: IOServiceMatchingCallback = { _, it in
    while true { let s = IOIteratorNext(it); if s == 0 { break }; IOObjectRelease(s) }
    if !scanPending {
        scanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scanPending = false; scanHandler?("event") }
    }
}

func watch() -> Never {
    var cfg = loadConfig()
    if readTSV(baselinePath) == nil {
        try? writeTSV(enumerate(), baselinePath)
        log("no baseline found; created \(baselinePath) from currently connected devices")
    }
    log("watch started pid=\(getpid()) events=IOKit first-match/terminated + wake/session resync, safety_rescan=\(cfg.pollSeconds)s lock=\(cfg.lockEnabled) gui_session=\(screenLocked() != nil) \(resolveSAC().1)")
    var previous = Set<String>()   // empty: anything non-baseline already present at start triggers
    scanHandler = { detectedBy in
        cfg = loadConfig()
        let base = Set((readTSV(baselinePath) ?? []).map { $0.identity })
        let allow = loadAllow()
        let cur = enumerate()
        let curIds = Set(cur.map { $0.identity })
        var seen = Set<String>(), trig: [Dev] = []
        for d in cur where !previous.contains(d.identity) && !seen.contains(d.identity) {
            seen.insert(d.identity)
            let v = classify(d, baseline: base, allow: allow, cfg: cfg)
            switch v {
            case .trigger: trig.append(d)
            case .baseline: break
            default: log("appeared but \(v.rawValue): \(d.identity) class=\(d.cls)")
            }
        }
        for gone in previous.subtracting(curIds) { log("disappeared: \(gone)") }
        previous = curIds
        if !trig.isEmpty { handleTriggers(trig, cfg: cfg, simulate: false, detectedBy: detectedBy) }
    }
    let port = IONotificationPortCreate(kIOMainPortDefault)
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
        var it: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOHIDDevice"), matchCB, nil, &it) == KERN_SUCCESS {
            while true { let s = IOIteratorNext(it); if s == 0 { break }; IOObjectRelease(s) }
        } else { log("WARNING: IOKit notification \(type) registration failed; relying on polling") }
    }
    scanHandler?("startup_resync")
    // Resync on wake / session becoming active (e.g. after fast user switching or unlock).
    let wnc = NSWorkspace.shared.notificationCenter
    for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        wnc.addObserver(forName: n, object: nil, queue: .main) { note in log("resync on \(note.name.rawValue)"); scanHandler?("wake_resync") }
    }
    // Single safety rescan with generous tolerance so the OS can coalesce wakeups.
    let t = Timer(timeInterval: cfg.pollSeconds, repeats: true) { _ in scanHandler?("backup_scan") }
    t.tolerance = max(1, cfg.pollSeconds * 0.2)
    RunLoop.main.add(t, forMode: .common)
    signal(SIGTERM) { _ in exit(0) }
    RunLoop.main.run()
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "inventory":   // TSV to stdout
    print(tsvHeader); enumerate().forEach { print($0.tsv) }
case "dry-run":
    let base = readTSV(baselinePath).map { Set($0.map { $0.identity }) }
    let cfg = loadConfig()
    printInventory(enumerate(), baseline: base ?? Set(), allow: loadAllow(), cfg: cfg)
    if base == nil { print("  (no baseline yet at \(baselinePath); all non-ignored entries above would be baselined by 'hid-guard baseline')") }
    print("Config: ignore_transports=\(cfg.ignoreTransports.sorted()) ignore_builtin_internal=\(cfg.ignoreBuiltinInternal) lock=\(cfg.lockEnabled) poll=\(cfg.pollSeconds)s")
    print("Any entry marked 'trigger' that APPEARS while the agent runs causes: lock -> webhook -> log.")
case "baseline":
    let out = args.count > 1 ? args[1] : baselinePath
    do { let d = enumerate(); try writeTSV(d, out); print("wrote \(d.count) entries to \(out)") } catch { print("error: \(error)"); exit(1) }
case "diff":        // diff BASELINE.tsv CURRENT.tsv
    guard args.count >= 3 else { print("usage: diff BASELINE.tsv CURRENT.tsv"); exit(2) }
    exit(diffCmd(baseFile: args[1], curFile: args[2], simulate: false))
case "simulate":    // like diff, but runs notify+log path (no lock), event=test
    guard args.count >= 3 else { print("usage: simulate BASELINE.tsv CURRENT.tsv [--detected-by event|backup_scan|startup_resync|wake_resync]"); exit(2) }
    var by = "event"
    if let i = args.firstIndex(of: "--detected-by"), i + 1 < args.count { by = args[i + 1] }
    guard detectedByText[by] != nil else { print("bad --detected-by \(by)"); exit(2) }
    exit(diffCmd(baseFile: args[1], curFile: args[2], simulate: true, detectedBy: by))
case "lock-check":
    let (fn, msg) = resolveSAC()
    print(msg)
    print("gui_session=\(screenLocked() != nil) screen_locked=\(screenLocked().map { String($0) } ?? "unknown")")
    exit(fn == nil ? 1 : 0)
case "lock-status":
    print(screenLocked().map { $0 ? "locked" : "unlocked" } ?? "unknown (no GUI session)")
case "lock":
    guard args.contains("--yes-really") else { print("refusing: pass --yes-really to lock the screen now"); exit(2) }
    print(lockScreen())
case "watch":
    watch()
default:
    print("usage: hid-guard-helper inventory|dry-run|baseline [FILE]|diff BASE CUR|simulate BASE CUR|lock-check|lock-status|lock --yes-really|watch")
    exit(2)
}
