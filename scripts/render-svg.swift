import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else { fatalError("usage: render-svg.swift SOURCE OUTPUT_DIR [sizes...]") }
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let sizes = CommandLine.arguments.dropFirst(3).compactMap { Int($0) }
guard let image = NSImage(contentsOf: source) else { fatalError("cannot render SVG") }
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in sizes {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()
    let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
}
