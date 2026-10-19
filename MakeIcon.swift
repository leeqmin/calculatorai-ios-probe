import AppKit
let side = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
NSColor(calibratedWhite: 0.14, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
NSColor(calibratedWhite: 0.29, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 205, y: 90, width: 614, height: 844), xRadius: 86, yRadius: 86).fill()
NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 253, y: 684, width: 518, height: 186), xRadius: 27, yRadius: 27).fill()
let text = "0" as NSString
text.draw(at: NSPoint(x: 667, y: 718), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 97, weight: .medium), .foregroundColor: NSColor.white])
for row in 0..<4 { for column in 0..<4 {
    let rect = NSRect(x: 254 + column * 133, y: 143 + row * 129, width: 111, height: 105)
    (column == 3 ? NSColor(calibratedRed: 118/255, green: 185/255, blue: 237/255, alpha: 1) : NSColor(calibratedWhite: 0.67, alpha: 1)).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 25, yRadius: 25).fill()
    if column == 3 {
        let symbol = ["=", "+", "−", "×"][row] as NSString
        symbol.draw(at: NSPoint(x: rect.minX + 30, y: rect.minY + 14), withAttributes: [.font: NSFont.systemFont(ofSize: 59, weight: .medium), .foregroundColor: NSColor.black])
    }
} }
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
