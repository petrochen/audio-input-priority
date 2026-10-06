import AppKit
// Draws the app icon: a rounded gradient square with a white microphone symbol.
let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for px in sizes {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let r = rect.insetBy(dx: rect.width * 0.05, dy: rect.width * 0.05)
        let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.62, alpha: 1))!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .medium)
        if let sym = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let tinted = sym.withSymbolConfiguration(.init(paletteColors: [.white]))!; tinted.isTemplate = false
            let h = rect.height * 0.52; let w = h * tinted.size.width / tinted.size.height
            let o = NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h)
            tinted.draw(in: o)
        }
        return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    let base = px <= 512 ? px : 512
    let name = px == 1024 ? "icon_512x512@2x.png" : "icon_\(base)x\(base).png"
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    if px >= 32 && px <= 512 { try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(px/2)x\(px/2)@2x.png")) }
}
