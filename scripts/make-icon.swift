// Renders Sources/AirtapApp/AppIcon.icns: `swift scripts/make-icon.swift`.
import AppKit

func render(_ pixels: Int) -> Data {
	let s = CGFloat(pixels)
	let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
		let ctx = NSGraphicsContext.current!.cgContext
		let inset = s * 0.098
		let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
		let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
		ctx.saveGState()
		ctx.addPath(path)
		ctx.clip()
		let colors = [NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1).cgColor, NSColor(red: 0.30, green: 0.25, blue: 0.85, alpha: 1).cgColor]
		let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
		ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
		ctx.restoreGState()

		ctx.setStrokeColor(NSColor.white.cgColor)
		ctx.setFillColor(NSColor.white.cgColor)
		ctx.setLineCap(.round)
		let center = CGPoint(x: s / 2, y: s * 0.46)
		ctx.setLineWidth(s * 0.05)
		for (radius, alpha) in [(0.17, 1.0), (0.30, 0.7)] {
			ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
			ctx.addArc(center: center, radius: s * radius, startAngle: -.pi * 0.2, endAngle: .pi * 1.2, clockwise: false)
			ctx.strokePath()
		}
		let triangle = CGMutablePath()
		triangle.move(to: CGPoint(x: s * 0.5, y: s * 0.40))
		triangle.addLine(to: CGPoint(x: s * 0.33, y: s * 0.20))
		triangle.addLine(to: CGPoint(x: s * 0.67, y: s * 0.20))
		triangle.closeSubpath()
		ctx.setFillColor(NSColor.white.cgColor)
		ctx.addPath(triangle)
		ctx.fillPath()
		return true
	}
	let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
	rep.size = NSSize(width: pixels, height: pixels)
	return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
	try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
	try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Sources/AirtapApp/AppIcon.icns"]
try task.run()
task.waitUntilExit()
