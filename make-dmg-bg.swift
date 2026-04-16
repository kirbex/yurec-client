#!/usr/bin/swift
import AppKit

let W: CGFloat = 660
let H: CGFloat = 400

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()

// Gradient background
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.90, green: 0.91, blue: 0.95, alpha: 1)
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

let center = NSMutableParagraphStyle()
center.alignment = .center
let left = NSMutableParagraphStyle()
left.alignment = .left

// Title
NSAttributedString(string: "Перетащи YurecClient в папку Applications", attributes: [
    .font: NSFont.boldSystemFont(ofSize: 15),
    .foregroundColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.22, alpha: 1),
    .paragraphStyle: center
]).draw(in: NSRect(x: 20, y: 328, width: 620, height: 24))

NSAttributedString(string: "Drag YurecClient to the Applications folder", attributes: [
    .font: NSFont.systemFont(ofSize: 12),
    .foregroundColor: NSColor(srgbRed: 0.45, green: 0.45, blue: 0.55, alpha: 1),
    .paragraphStyle: center
]).draw(in: NSRect(x: 20, y: 305, width: 620, height: 20))

// Arrow
NSAttributedString(string: "→", attributes: [
    .font: NSFont.systemFont(ofSize: 56),
    .foregroundColor: NSColor(srgbRed: 0.38, green: 0.50, blue: 0.82, alpha: 0.75),
    .paragraphStyle: center
]).draw(in: NSRect(x: 0, y: 168, width: W, height: 70))

// Separator line above GK box
NSColor(srgbRed: 0.75, green: 0.76, blue: 0.80, alpha: 0.6).setStroke()
let line = NSBezierPath()
line.move(to: NSPoint(x: 30, y: 148))
line.line(to: NSPoint(x: W - 30, y: 148))
line.lineWidth = 0.8
line.stroke()

// Gatekeeper warning box
let boxRect = NSRect(x: 25, y: 16, width: 610, height: 126)
let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 10, yRadius: 10)
NSColor(srgbRed: 1.0, green: 0.96, blue: 0.86, alpha: 0.95).setFill()
boxPath.fill()
NSColor(srgbRed: 0.88, green: 0.72, blue: 0.30, alpha: 1.0).setStroke()
boxPath.lineWidth = 1.2
boxPath.stroke()

// Warning header
NSAttributedString(string: "⚠️  Первый запуск: macOS заблокирует приложение (нет Apple-сертификата)", attributes: [
    .font: NSFont.boldSystemFont(ofSize: 12),
    .foregroundColor: NSColor(srgbRed: 0.58, green: 0.32, blue: 0.0, alpha: 1),
    .paragraphStyle: left
]).draw(in: NSRect(x: 42, y: 116, width: 582, height: 18))

// Warning body
let body = """
Способ 1 — через Finder:
   Найди YurecClient в Applications → правая кнопка мыши → Open → в диалоге нажми Open

Способ 2 — через Терминал (однократно):
   xattr -d com.apple.quarantine /Applications/YurecClient.app
"""
NSAttributedString(string: body, attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.22, green: 0.18, blue: 0.08, alpha: 1),
    .paragraphStyle: left
]).draw(in: NSRect(x: 42, y: 22, width: 582, height: 92))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    print("ERROR: failed to render image"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: "/tmp/yurec-dmg-bg.png"))
print("Background image written to /tmp/yurec-dmg-bg.png")
