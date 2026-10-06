import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import UserNotifications

// audio-input-priority — keep macOS default input/output devices on the best available ones,
// with a menu-bar icon to pick devices by hand and to pause the automation.
//
// Config (one device name or glob per line, best first; * and ? are case-insensitive):
//   ~/.config/audio-input-priority/devices   default INPUT priority
//   ~/.config/audio-input-priority/outputs   default OUTPUT priority
// Built-in mic and speakers are skipped while the lid is closed (clamshell mode).
// A manual pick (menu bar, System Settings, Control Center, an app) of a LISTED device is kept until
// the set of devices or the lid state changes; a pick from the menu bar is kept whatever the device.
// Bluetooth output stuck in HFP (<=16 kHz) with nobody using the mic is bumped back to A2DP.
// Usage: audio-input-priority [--list | --once | --register | --unregister | --quiet]
// --register / --unregister: enable / disable start at login (also in the menu).

let defaultInputPriority  = ["fifine Microphone", "MX Brio", "*Pods*", "MacBook Pro Microphone"]
let defaultOutputPriority = ["*Pods*", "WH-1000XM3", "LG UltraFine Display Audio", "MacBook Pro Speakers"]
let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/audio-input-priority")
let logPath = home.appendingPathComponent("Library/Logs/audio-input-priority.log").path
let label = "com.apetrochenko.audio-input-priority"
let launchAgent = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
let quiet = CommandLine.arguments.contains("--quiet")
let defaults = UserDefaults.standard
var autoEnabled = defaults.object(forKey: "auto") as? Bool ?? true       // menu-bar toggle, persisted
var notifyEnabled = defaults.object(forKey: "notify") as? Bool ?? true   // menu-bar toggle, persisted

// MARK: - CoreAudio helpers
let sys = AudioObjectID(kAudioObjectSystemObject)
func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(sel); var v: UInt32 = 0; var sz = UInt32(4); AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func cfstr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == 0, let s = s else { return nil }
    return s.takeRetainedValue() as String
}
func name(_ id: AudioObjectID) -> String { cfstr(id, kAudioObjectPropertyName) ?? "?" }
func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, scope); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz); return sz > 0
}
func objects(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(sel); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids); return ids
}
func currentDefault(_ sel: AudioObjectPropertySelector) -> AudioObjectID { u32(sys, sel) }
func setDefault(_ sel: AudioObjectPropertySelector, _ id: AudioObjectID) -> OSStatus {
    var a = addr(sel); var v = id; return AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(4), &v)
}
func transport(_ id: AudioObjectID) -> UInt32 { u32(id, kAudioDevicePropertyTransportType) }
func isBuiltIn(_ id: AudioObjectID) -> Bool { transport(id) == kAudioDeviceTransportTypeBuiltIn }
func isBluetooth(_ id: AudioObjectID) -> Bool {
    let t = transport(id); return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}
func sampleRate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r: Double = 0; var sz = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &r); return r
}
func maxSampleRate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyAvailableNominalSampleRates); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz)
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(sz) / MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &ranges)
    return ranges.map { $0.mMaximum }.max() ?? 0
}
func isHFP(_ id: AudioObjectID) -> Bool { let r = sampleRate(id); return isBluetooth(id) && r > 0 && r <= 16000 }
// Apps currently recording from the default input (CoreAudio process objects, macOS 14+).
func recorders() -> [String] {
    objects(kAudioHardwarePropertyProcessObjectList).filter { u32($0, kAudioProcessPropertyIsRunningInput) == 1 }.map { p in
        let pid = pid_t(u32(p, kAudioProcessPropertyPID))
        if let app = NSRunningApplication(processIdentifier: pid)?.localizedName { return app }
        if let bundle = cfstr(p, kAudioProcessPropertyBundleID), !bundle.isEmpty { return bundle.components(separatedBy: ".").last ?? bundle }
        return "pid \(pid)"
    }
}
func lidClosed() -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return false }
    defer { IOObjectRelease(svc) }
    let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (v as? Bool) ?? false
}
func matches(_ pattern: String, _ text: String) -> Bool { NSPredicate(format: "SELF LIKE[c] %@", pattern).evaluate(with: text) }
func priority(_ file: String, _ fallback: [String]) -> [String] {
    guard let text = try? String(contentsOf: configDir.appendingPathComponent(file), encoding: .utf8) else { return fallback }
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    return lines.isEmpty ? fallback : lines
}
func isListed(_ deviceName: String, _ prio: [String]) -> Bool { prio.contains { matches($0, deviceName) } }

// MARK: - Logging & notifications
let logFile: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    let h = FileHandle(forWritingAtPath: logPath); h?.seekToEndOfFile(); return h
}()
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if isatty(1) != 0 { print(line, terminator: "") }
    logFile?.write(line.data(using: .utf8)!)
}
var nativeNotifications = false
func banner(_ title: String, _ text: String) {
    guard notifyEnabled && !quiet else { return }
    if nativeNotifications {
        let c = UNMutableNotificationContent(); c.title = title; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    } else {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(text)\" with title \"\(title)\""]
        try? p.run()
    }
}

// MARK: - Login item
// A LaunchAgent in ~/Library/LaunchAgents written by the app. (System Login Items via ServiceManagement pin the
// binary's code hash at registration, so with an ad-hoc signature every rebuild made launchd refuse to spawn it.)
@discardableResult func launchctl(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
}
func loginItemEnabled() -> Bool { FileManager.default.fileExists(atPath: launchAgent.path) }
// Writes the plist and bootstraps the job. The caller decides whether to exit afterwards.
func enableLoginItem() throws {
    let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    let plist: [String: Any] = ["Label": label, "ProgramArguments": [exe], "RunAtLoad": true,
                                "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive"]
    try FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: launchAgent)
    launchctl(["bootstrap", "gui/\(getuid())", launchAgent.path])   // fails harmlessly if already loaded
}
// Only removes the plist: the running job stays until logout, nothing starts at the next login.
func disableLoginItem() { try? FileManager.default.removeItem(at: launchAgent) }
func runningUnderLaunchd() -> Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

// MARK: - Rules
struct Kind { let label: String; let scope: AudioObjectPropertyScope; let sel: AudioObjectPropertySelector; let file: String; let fallback: [String] }
let kinds = [
    Kind(label: "input",  scope: kAudioObjectPropertyScopeInput,  sel: kAudioHardwarePropertyDefaultInputDevice,  file: "devices", fallback: defaultInputPriority),
    Kind(label: "output", scope: kAudioObjectPropertyScopeOutput, sel: kAudioHardwarePropertyDefaultOutputDevice, file: "outputs", fallback: defaultOutputPriority),
]
func candidates(_ k: Kind, lidClosed closed: Bool) -> [(id: AudioObjectID, name: String)] {
    objects(kAudioHardwarePropertyDevices).filter { hasStreams($0, k.scope) && !(closed && isBuiltIn($0)) }.map { (id: $0, name: name($0)) }
}
var manual: [String: AudioObjectID] = [:]   // kind label -> device the user picked by hand
var noPriorityLogged = Set<String>()
func applyPriority(_ k: Kind, lidClosed closed: Bool, devicesChanged: Bool) {
    let present = candidates(k, lidClosed: closed)
    let prio = priority(k.file, k.fallback)
    guard let want = prio.lazy.compactMap({ p in present.first { matches(p, $0.name) } }).first else {
        if noPriorityLogged.insert(k.label).inserted { log("\(k.label): no priority device present") }
        return
    }
    noPriorityLogged.remove(k.label)
    let cur = currentDefault(k.sel)
    if cur == want.id { manual[k.label] = nil; return }
    if devicesChanged { manual[k.label] = nil }
    else if manual[k.label] == cur { return }   // picked from the menu bar: keep whatever it is
    // No plug/lid event, and the current default is a listed device: someone chose it on purpose. Keep it.
    else if let chosen = present.first(where: { $0.id == cur }), isListed(chosen.name, prio) {
        manual[k.label] = cur; log("\(k.label): manual choice \(chosen.name) kept (listed; resets when devices change)")
        return
    }
    let st = setDefault(k.sel, want.id)
    if k.label == "output" { _ = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, want.id) }
    log("\(k.label): \(name(cur)) -> \(want.name) (status \(st), lid \(closed ? "closed" : "open"))")
    banner(k.label == "input" ? "Microphone" : "Sound output", want.name)
}
// Bluetooth headset stuck in HFP: output at <=16 kHz while nobody records. Returns true if still stuck.
func fixHFP(force: Bool = false) -> Bool {
    var stuck = false
    for d in objects(kAudioHardwarePropertyDevices) where isHFP(d) && hasStreams(d, kAudioObjectPropertyScopeOutput) {
        let rate = sampleRate(d)
        if !force && !recorders().isEmpty { stuck = true; continue }   // a call is in progress, leave it
        let target = maxSampleRate(d)
        guard target > rate else { stuck = true; continue }
        var a = addr(kAudioDevicePropertyNominalSampleRate); var r = target
        let st = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(8), &r)
        log("hfp: \(name(d)) \(Int(rate)) Hz -> \(Int(target)) Hz (status \(st)\(force ? ", forced" : ""))")
        if sampleRate(d) <= 16000 { stuck = true } else { banner("Headphones", "\(name(d)): back to stereo") }
    }
    return stuck
}
var knownDevices = Set<AudioObjectID>()
var knownLid: Bool?
func apply() {
    let closed = lidClosed()
    let now = Set(objects(kAudioHardwarePropertyDevices))
    let changed = now != knownDevices || closed != knownLid   // plug/unplug or lid open/close
    knownDevices = now; knownLid = closed
    if autoEnabled { for k in kinds { applyPriority(k, lidClosed: closed, devicesChanged: changed) } }
    if fixHFP() { scheduleHFPRetry() }
    DispatchQueue.main.async { menuBar?.refresh() }
}
// Things worth a yellow icon.
func warnings() -> [String] {
    var w: [String] = []
    let out = currentDefault(kAudioHardwarePropertyDefaultOutputDevice)
    if isHFP(out) { w.append("\(name(out)) is in headset mode (\(Int(sampleRate(out)) / 1000) kHz, mono)") }
    let inp = currentDefault(kAudioHardwarePropertyDefaultInputDevice)
    if isBuiltIn(inp) && lidClosed() { w.append("Built-in microphone selected while the lid is closed") }
    return w
}

// MARK: - CLI
let args = CommandLine.arguments.dropFirst()
if args.contains("--list") {
    let closed = lidClosed()
    for k in kinds {
        let cur = currentDefault(k.sel); let prio = priority(k.file, k.fallback)
        print("\(k.label):")
        for d in objects(kAudioHardwarePropertyDevices).filter({ hasStreams($0, k.scope) }) {
            let n = name(d)
            let skip = closed && isBuiltIn(d) ? "  (skipped: lid closed)" : ""
            let bt = isBluetooth(d) ? "  [\(Int(sampleRate(d))) Hz]" : ""
            let listed = isListed(n, prio) ? "" : "  (not in list)"
            print("  \(d == cur ? "* " : "  ")\(n)\(bt)\(skip)\(listed)")
        }
    }
    let r = recorders(); print("recording: \(r.isEmpty ? "nobody" : r.joined(separator: ", "))")
    for w in warnings() { print("warning: \(w)") }
    exit(0)
}
if args.contains("--once") { let closed = lidClosed(); for k in kinds { applyPriority(k, lidClosed: closed, devicesChanged: true) }; _ = fixHFP(); exit(0) }
if args.contains("--register") {   // install the LaunchAgent and start it
    do { try enableLoginItem(); print("login item: enabled") } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if args.contains("--unregister") {   // remove the LaunchAgent and stop the running job
    disableLoginItem(); launchctl(["bootout", "gui/\(getuid())/\(label)"]); print("login item: disabled"); exit(0)
}

// MARK: - Event loop
let queue = DispatchQueue(label: "audio-input-priority")
var pending: DispatchWorkItem?
var hfpRetry: DispatchWorkItem?
func schedule(after: Double = 1.5) {
    pending?.cancel()
    let w = DispatchWorkItem { apply() }; pending = w
    queue.asyncAfter(deadline: .now() + after, execute: w)   // debounce: devices settle after plug events
}
func scheduleHFPRetry() {   // poll only while a headset is stuck in HFP
    hfpRetry?.cancel()
    let w = DispatchWorkItem { if fixHFP() { scheduleHFPRetry() }; DispatchQueue.main.async { menuBar?.refresh() } }; hfpRetry = w
    queue.asyncAfter(deadline: .now() + 10, execute: w)
}
let listener: AudioObjectPropertyListenerBlock = { _, _ in schedule() }
var rateListeners = Set<AudioObjectID>()
func watchBluetoothRates() {   // sample-rate change on a BT device = profile switch (A2DP <-> HFP)
    for d in objects(kAudioHardwarePropertyDevices) where isBluetooth(d) && !rateListeners.contains(d) {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(d, &a, queue) { _, _ in schedule(after: 5) }
        rateListeners.insert(d)
    }
}

// MARK: - Menu bar
func symbolName(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    let n = name(id).lowercased(); let t = transport(id); let input = scope == kAudioObjectPropertyScopeInput
    if n.contains("pods") { return "airpodspro" }
    if isBluetooth(id) { return "headphones" }
    if isBuiltIn(id) { return "laptopcomputer" }
    if n.contains("iphone") || n.contains("ipad") { return "iphone" }
    if n.contains("brio") || n.contains("cam") { return "web.camera" }
    if t == kAudioDeviceTransportTypeVirtual || n.contains("teams") || n.contains("zoom") { return "waveform" }
    if t == kAudioDeviceTransportTypeDisplayPort || t == kAudioDeviceTransportTypeHDMI || n.contains("display") { return "display" }
    return input ? "mic.fill" : "speaker.wave.2.fill"
}
func symbol(_ nameOrFallback: String, _ fallback: String = "mic.fill") -> NSImage {
    NSImage(systemSymbolName: nameOrFallback, accessibilityDescription: nil) ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)!
}
final class MenuBar: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    override init() {
        super.init()
        menu.delegate = self; item.menu = menu
        refresh()
    }
    var holding: [String] {   // manual choices currently in force
        kinds.compactMap { k in (manual[k.label].map { $0 == currentDefault(k.sel) } ?? false) ? name(manual[k.label]!) : nil }
    }
    // Icon = type of the current microphone; yellow when something is wrong; a dot when not fully automatic.
    func refresh() {
        let inId = currentDefault(kAudioHardwarePropertyDefaultInputDevice)
        let warn = warnings()
        let base = symbol(symbolName(inId, kAudioObjectPropertyScopeInput)).withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let dot = !autoEnabled || !holding.isEmpty
        let w = base.size.width + (dot ? 4 : 0), h = base.size.height
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let color: NSColor = warn.isEmpty ? .black : .systemYellow
            let tinted = base.withSymbolConfiguration(.init(paletteColors: [color]))!
            tinted.isTemplate = false
            tinted.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: h))
            if dot { color.setFill(); NSBezierPath(ovalIn: NSRect(x: w - 4, y: 0, width: 4, height: 4)).fill() }
            return true
        }
        img.isTemplate = warn.isEmpty   // template adapts to light/dark menu bar; yellow stays yellow
        item.button?.image = img
        var tip = "Mic: \(name(inId))\nOut: \(name(currentDefault(kAudioHardwarePropertyDefaultOutputDevice)))"
        tip += "\n" + (autoEnabled ? (holding.isEmpty ? "Automatic" : "Holding \(holding.joined(separator: ", "))") : "Automation off")
        for x in warn { tip += "\n⚠︎ \(x)" }
        item.button?.toolTip = tip
    }
    func add(_ title: String, _ action: Selector? = nil, indent: Int = 0, state: NSControl.StateValue = .off, image: NSImage? = nil, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self; mi.indentationLevel = indent; mi.state = state; mi.image = image; mi.isEnabled = enabled
        menu.addItem(mi); return mi
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let closed = lidClosed()
        // Status block
        let r = recorders()
        _ = add(r.isEmpty ? "Nobody is recording" : "In use by: \(r.joined(separator: ", "))",
                image: symbol(r.isEmpty ? "mic.slash" : "record.circle"), enabled: false)
        for w in warnings() { _ = add(w, image: symbol("exclamationmark.triangle.fill"), enabled: false) }
        menu.addItem(.separator())
        // Devices
        for (i, k) in kinds.enumerated() {
            _ = add(k.label == "input" ? "Microphone" : "Sound output", enabled: false)
            let cur = currentDefault(k.sel); let prio = priority(k.file, k.fallback)
            for d in objects(kAudioHardwarePropertyDevices).filter({ hasStreams($0, k.scope) }) {
                let n = name(d); var title = n
                if isBluetooth(d) { title += "  \(Int(sampleRate(d)) / 1000) kHz" }
                if closed && isBuiltIn(d) { title += "  · lid closed" }
                if !isListed(n, prio) { title += "  · not in list" }
                let mi = add(title, #selector(pick(_:)), indent: 1, state: d == cur ? .on : .off, image: symbol(symbolName(d, k.scope)))
                mi.representedObject = [i, Int(d)]
            }
            menu.addItem(.separator())
        }
        // Mode
        let held = holding
        let status = !autoEnabled ? "Automation is off, you choose devices yourself"
            : held.isEmpty ? "Automatic: best listed device is selected"
            : "Holding your choice (\(held.joined(separator: ", "))) until devices change"
        _ = add(status, enabled: false)
        if autoEnabled && !held.isEmpty { _ = add("Back to automatic now", #selector(applyNow), indent: 1) }
        if objects(kAudioHardwarePropertyDevices).contains(where: { isHFP($0) && hasStreams($0, kAudioObjectPropertyScopeOutput) }) {
            _ = add("Fix headphones stereo now", #selector(fixStereo), indent: 1)
        }
        menu.addItem(.separator())
        _ = add("Automatic priority", #selector(toggleAuto), state: autoEnabled ? .on : .off)
        _ = add("Notify on switch", #selector(toggleNotify), state: notifyEnabled ? .on : .off)
        _ = add("Start at login", #selector(toggleLogin), state: loginItemEnabled() ? .on : .off)
        menu.addItem(.separator())
        _ = add("Edit priority lists…", #selector(openConfig))
        _ = add("Show log", #selector(openLog))
        _ = add("Sound settings…", #selector(openSoundSettings))
        menu.addItem(.separator())
        _ = add("Quit", #selector(quit), key: "q")
    }
    @objc func pick(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? [Int] else { return }
        let k = kinds[o[0]]; let id = AudioObjectID(o[1])
        queue.async {
            manual[k.label] = id
            let st = setDefault(k.sel, id)
            if k.label == "output" { _ = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, id) }
            log("\(k.label): menu pick \(name(id)) (status \(st))")
            DispatchQueue.main.async { self.refresh() }
        }
    }
    @objc func toggleAuto() {
        autoEnabled.toggle(); defaults.set(autoEnabled, forKey: "auto")
        log("auto priority \(autoEnabled ? "on" : "off")")
        refresh()
        if autoEnabled { queue.async { manual = [:]; apply() } }
    }
    @objc func toggleNotify() { notifyEnabled.toggle(); defaults.set(notifyEnabled, forKey: "notify") }
    @objc func toggleLogin() {
        if loginItemEnabled() { disableLoginItem(); log("login item: disabled"); return }
        do {
            try enableLoginItem(); log("login item: enabled")
            if !runningUnderLaunchd() { log("handing over to launchd"); exit(0) }   // launchd's instance takes over in a second
        } catch { log("login item error: \(error)") }
    }
    @objc func applyNow() { queue.async { manual = [:]; knownDevices = []; apply() } }
    @objc func fixStereo() { queue.async { _ = fixHFP(force: true); DispatchQueue.main.async { self.refresh() } } }
    @objc func openConfig() {
        for (f, example) in [("devices", defaultInputPriority), ("outputs", defaultOutputPriority)] {
            let url = configDir.appendingPathComponent(f)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                try? (example.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func openSoundSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) }
    @objc func quit() { NSApp.terminate(nil) }
    // Show banners even if the app happens to be frontmost
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner]) }
}
var menuBar: MenuBar?

// Single instance: launchd (or a double-click) must not start a second icon.
if let bid = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
    log("another instance is running, exiting"); exit(0)
}

var a1 = addr(kAudioHardwarePropertyDevices)
var a2 = addr(kAudioHardwarePropertyDefaultInputDevice)
var a3 = addr(kAudioHardwarePropertyDefaultOutputDevice)
AudioObjectAddPropertyListenerBlock(sys, &a1, queue) { _, _ in watchBluetoothRates(); schedule() }
AudioObjectAddPropertyListenerBlock(sys, &a2, queue, listener)
AudioObjectAddPropertyListenerBlock(sys, &a3, queue, listener)
CGDisplayRegisterReconfigurationCallback({ _, _, _ in queue.async { schedule() } }, nil)   // lid open/close
watchBluetoothRates()
log("started; auto \(autoEnabled ? "on" : "off"); input: \(priority("devices", defaultInputPriority).joined(separator: " > ")); output: \(priority("outputs", defaultOutputPriority).joined(separator: " > "))")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
menuBar = MenuBar()
if Bundle.main.bundleIdentifier != nil {
    let center = UNUserNotificationCenter.current(); center.delegate = menuBar
    center.requestAuthorization(options: [.alert]) { ok, err in
        nativeNotifications = ok
        if let err = err { log("notifications: \(err.localizedDescription)") }
    }
}
queue.async { apply() }
app.run()
