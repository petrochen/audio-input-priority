import CoreAudio
import Foundation

// audio-input-priority — keep macOS default input device on the best available microphone.
//
// Priority list: ~/.config/audio-input-priority/devices (one device name or glob per line, top = best).
// Globs: * and ? (case-insensitive), e.g. "*Pods*" matches any AirPods. Falls back to the list below.
// Usage: audio-input-priority [--list | --once]

let defaultPriority = ["*Pods*", "fifine Microphone", "MX Brio", "MacBook Pro Microphone"]
let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/audio-input-priority/devices").path

let sys = AudioObjectID(kAudioObjectSystemObject)
func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func name(_ id: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == 0 ? (s as String) : "?"
}
func hasInput(_ id: AudioObjectID) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz); return sz > 0
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids); return ids
}
func currentDefault() -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice); var id: AudioObjectID = 0; var sz = UInt32(4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &id); return id
}
func priority() -> [String] {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return defaultPriority }
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    return lines.isEmpty ? defaultPriority : lines
}
func log(_ s: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(s)"); fflush(stdout)
}
func matches(_ pattern: String, _ text: String) -> Bool {
    NSPredicate(format: "SELF LIKE[c] %@", pattern).evaluate(with: text)
}
func apply() {
    let inputs = devices().filter(hasInput).map { (id: $0, name: name($0)) }
    guard let want = priority().lazy.compactMap({ p in inputs.first { matches(p, $0.name) }?.id }).first
    else { log("no priority device present"); return }
    let cur = currentDefault()
    if cur == want { return }
    var a = addr(kAudioHardwarePropertyDefaultInputDevice); var id = want
    let st = AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(4), &id)
    log("default input: \(name(cur)) -> \(name(want)) (status \(st))")
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--list") {
    let cur = currentDefault()
    for d in devices().filter(hasInput) { print("\(d == cur ? "* " : "  ")\(name(d))") }
    exit(0)
}
if args.contains("--once") { apply(); exit(0) }

let queue = DispatchQueue(label: "audio-input-priority")
var pending: DispatchWorkItem?
let listener: AudioObjectPropertyListenerBlock = { _, _ in
    pending?.cancel()
    let w = DispatchWorkItem { apply() }; pending = w
    queue.asyncAfter(deadline: .now() + 1.5, execute: w)   // debounce: devices settle after plug events
}
var a1 = addr(kAudioHardwarePropertyDevices)
var a2 = addr(kAudioHardwarePropertyDefaultInputDevice)
AudioObjectAddPropertyListenerBlock(sys, &a1, queue, listener)
AudioObjectAddPropertyListenerBlock(sys, &a2, queue, listener)
log("started, priority: \(priority().joined(separator: " > ")) (config: \(configPath))")
queue.async { apply() }
RunLoop.main.run()
