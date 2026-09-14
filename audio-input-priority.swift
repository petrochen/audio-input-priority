import CoreAudio
import CoreGraphics
import Foundation
import IOKit

// audio-input-priority — keep macOS default input/output devices on the best available ones.
//
// Config (one device name or glob per line, best first; * and ? are case-insensitive):
//   ~/.config/audio-input-priority/devices   default INPUT priority
//   ~/.config/audio-input-priority/outputs   default OUTPUT priority
// Built-in mic and speakers are skipped while the lid is closed (clamshell mode).
// Bluetooth output stuck in HFP (<=16 kHz) with nobody using the mic is bumped back to A2DP.
// Usage: audio-input-priority [--list | --once]

let defaultInputPriority  = ["fifine Microphone", "MX Brio", "MacBook Pro Microphone", "*Pods*"]
let defaultOutputPriority = ["*Pods*", "WH-1000XM3", "LG UltraFine Display Audio", "MacBook Pro Speakers"]
let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/audio-input-priority")
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
    var a = addr(kAudioObjectPropertyName); var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == 0 ? (s as String) : "?"
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
func applyPriority(_ k: Kind, lidClosed closed: Bool) {
    let present = candidates(k, lidClosed: closed)
    guard let want = priority(k.file, k.fallback).lazy.compactMap({ p in present.first { matches(p, $0.name) } }).first
    else { log("\(k.label): no priority device present"); return }
    let cur = currentDefault(k.sel)
    if cur == want.id { return }
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
func apply() {
    let closed = lidClosed()
    for k in kinds { applyPriority(k, lidClosed: closed) }
    if fixHFP() { scheduleHFPRetry() }
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
if args.contains("--once") { let closed = lidClosed(); for k in kinds { applyPriority(k, lidClosed: closed) }; _ = fixHFP(); exit(0) }

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
var a1 = addr(kAudioHardwarePropertyDevices)
var a2 = addr(kAudioHardwarePropertyDefaultInputDevice)
var a3 = addr(kAudioHardwarePropertyDefaultOutputDevice)
AudioObjectAddPropertyListenerBlock(sys, &a1, queue) { _, _ in watchBluetoothRates(); schedule() }
AudioObjectAddPropertyListenerBlock(sys, &a2, queue, listener)
AudioObjectAddPropertyListenerBlock(sys, &a3, queue, listener)
CGDisplayRegisterReconfigurationCallback({ _, _, _ in queue.async { schedule() } }, nil)   // lid open/close
watchBluetoothRates()
log("started; input: \(priority("devices", defaultInputPriority).joined(separator: " > ")); output: \(priority("outputs", defaultOutputPriority).joined(separator: " > "))")
queue.async { apply() }
RunLoop.main.run()
