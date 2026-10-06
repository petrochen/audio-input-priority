import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit

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
// Usage: audio-input-priority [--list | --once | --quiet]

let defaultInputPriority  = ["fifine Microphone", "MX Brio", "*Pods*", "MacBook Pro Microphone"]
let defaultOutputPriority = ["*Pods*", "WH-1000XM3", "LG UltraFine Display Audio", "MacBook Pro Speakers"]
let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/audio-input-priority")
let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/audio-input-priority.log").path
let notify = !CommandLine.arguments.contains("--quiet")

// MARK: - CoreAudio helpers
let sys = AudioObjectID(kAudioObjectSystemObject)
func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(sel); var v: UInt32 = 0; var sz = UInt32(4); AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func name(_ id: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == 0, let s = s else { return "?" }
    return s.takeRetainedValue() as String
}
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
func isBuiltIn(_ id: AudioObjectID) -> Bool { u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
func isBluetooth(_ id: AudioObjectID) -> Bool {
    let t = u32(id, kAudioDevicePropertyTransportType)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
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
func anyProcessRunningInput() -> Bool {
    objects(kAudioHardwarePropertyProcessObjectList).contains { u32($0, kAudioProcessPropertyIsRunningInput) == 1 }
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
func log(_ s: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(s)"); fflush(stdout) }
func banner(_ title: String, _ text: String) {
    guard notify else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(text)\" with title \"\(title)\""]
    try? p.run()
}

// MARK: - Rules
struct Kind { let label: String; let scope: AudioObjectPropertyScope; let sel: AudioObjectPropertySelector; let file: String; let fallback: [String] }
let kinds = [
    Kind(label: "input",  scope: kAudioObjectPropertyScopeInput,  sel: kAudioHardwarePropertyDefaultInputDevice,  file: "devices", fallback: defaultInputPriority),
    Kind(label: "output", scope: kAudioObjectPropertyScopeOutput, sel: kAudioHardwarePropertyDefaultOutputDevice, file: "outputs", fallback: defaultOutputPriority),
]
func candidates(_ k: Kind, lidClosed closed: Bool) -> [(id: AudioObjectID, name: String)] {
    objects(kAudioHardwarePropertyDevices).filter { hasStreams($0, k.scope) && !(closed && isBuiltIn($0)) }.map { (id: $0, name: name($0)) }
}
let defaults = UserDefaults.standard
var autoEnabled = defaults.object(forKey: "auto") as? Bool ?? true   // menu-bar toggle, persisted
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
    else if let chosen = present.first(where: { $0.id == cur }), prio.contains(where: { matches($0, chosen.name) }) {
        manual[k.label] = cur; log("\(k.label): manual choice \(chosen.name) kept (listed; resets when devices change)")
        return
    }
    let st = setDefault(k.sel, want.id)
    if k.label == "output" { _ = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, want.id) }
    log("\(k.label): \(name(cur)) -> \(want.name) (status \(st), lid \(closed ? "closed" : "open"))")
    banner(k.label == "input" ? "Microphone" : "Sound output", want.name)
}
// Bluetooth headset stuck in HFP: output at <=16 kHz while nobody records. Returns true if still stuck.
func fixHFP() -> Bool {
    var stuck = false
    for d in objects(kAudioHardwarePropertyDevices) where isBluetooth(d) && hasStreams(d, kAudioObjectPropertyScopeOutput) {
        let rate = sampleRate(d)
        guard rate > 0 && rate <= 16000 else { continue }
        if anyProcessRunningInput() { stuck = true; continue }   // a call is in progress, leave it
        let target = maxSampleRate(d)
        guard target > rate else { stuck = true; continue }
        var a = addr(kAudioDevicePropertyNominalSampleRate); var r = target
        let st = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(8), &r)
        log("hfp: \(name(d)) \(Int(rate)) Hz -> \(Int(target)) Hz (status \(st))")
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

// MARK: - CLI
let args = CommandLine.arguments.dropFirst()
if args.contains("--list") {
    let closed = lidClosed()
    for k in kinds {
        let cur = currentDefault(k.sel)
        print("\(k.label):")
        for d in objects(kAudioHardwarePropertyDevices).filter({ hasStreams($0, k.scope) }) {
            let skip = closed && isBuiltIn(d) ? "  (skipped: lid closed)" : ""
            let bt = isBluetooth(d) ? "  [\(Int(sampleRate(d))) Hz]" : ""
            print("  \(d == cur ? "* " : "  ")\(name(d))\(bt)\(skip)")
        }
    }
    exit(0)
}
if args.contains("--once") { let closed = lidClosed(); for k in kinds { applyPriority(k, lidClosed: closed, devicesChanged: true) }; _ = fixHFP(); exit(0) }

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
    let w = DispatchWorkItem { if fixHFP() { scheduleHFPRetry() } }; hfpRetry = w
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
final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    override init() {
        super.init()
        menu.delegate = self; item.menu = menu
        refresh()
    }
    func refresh() {
        let symbol = autoEnabled ? "mic.fill" : "mic"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Audio priority")
        item.button?.toolTip = "Mic: \(name(currentDefault(kAudioHardwarePropertyDefaultInputDevice)))\nOut: \(name(currentDefault(kAudioHardwarePropertyDefaultOutputDevice)))\n\(autoEnabled ? "Auto priority on" : "Manual (auto off)")"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let closed = lidClosed()
        for (i, k) in kinds.enumerated() {
            let header = NSMenuItem(title: k.label == "input" ? "Microphone" : "Sound output", action: nil, keyEquivalent: "")
            header.isEnabled = false; menu.addItem(header)
            let cur = currentDefault(k.sel)
            for d in objects(kAudioHardwarePropertyDevices).filter({ hasStreams($0, k.scope) }) {
                var title = name(d)
                if isBluetooth(d) { title += "  (\(Int(sampleRate(d)) / 1000) kHz)" }
                if closed && isBuiltIn(d) { title += "  (lid closed)" }
                let mi = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = [i, Int(d)]; mi.indentationLevel = 1
                mi.state = d == cur ? .on : .off
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        let auto = NSMenuItem(title: "Automatic priority", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self; auto.state = autoEnabled ? .on : .off; menu.addItem(auto)
        let apply = NSMenuItem(title: "Apply priority now", action: #selector(applyNow), keyEquivalent: "")
        apply.target = self; menu.addItem(apply)
        menu.addItem(.separator())
        for (t, s) in [("Edit priority lists…", #selector(openConfig)), ("Show log", #selector(openLog)), ("Sound settings…", #selector(openSoundSettings))] {
            let mi = NSMenuItem(title: t, action: s, keyEquivalent: ""); mi.target = self; menu.addItem(mi)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
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
    @objc func applyNow() { queue.async { manual = [:]; knownDevices = []; apply() } }
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
}
var menuBar: MenuBar?

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
queue.async { apply() }
app.run()
