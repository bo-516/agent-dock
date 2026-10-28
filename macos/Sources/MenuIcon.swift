// The menu bar icon: a board of three session rows, drawn as a template image.

import AppKit
import Combine

// The board is an 18 pt square. Its top-right corner carries the state: a
// rotating arc while something runs (`spin`), a dot when something is unread,
// the dot inside the arc for both. `count` is drawn beside it in the same
// image, so the status item needs no title.
enum MenuIcon {
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    private static var cache: [String: NSImage] = [:]

    // The same image for the same state, so the running animation draws each frame once.
    static func cached(spin: Double?, hasUnread: Bool, count: Int) -> NSImage {
        let frame = spin.map { Int(($0 / (.pi / 4)).rounded()) % 8 }
        let key = "\(frame.map(String.init) ?? "-")/\(hasUnread)/\(count)"
        if let image = cache[key] { return image }
        if cache.count > 200 { cache.removeAll() }
        let image = make(spin: frame.map { Double($0) * .pi / 4 }, hasUnread: hasUnread, count: count)
        cache[key] = image
        return image
    }

    static func make(spin: Double?, hasUnread: Bool, count: Int = 0) -> NSImage {
        let text = count > 0 ? "\(count)" as NSString : nil
        let attributes: [NSAttributedString.Key: Any] = [.font: countFont, .foregroundColor: NSColor.black]
        let textSize = text?.size(withAttributes: attributes) ?? .zero
        let width = 18 + (text == nil ? 0 : 3 + ceil(textSize.width))

        let image = NSImage(size: NSSize(width: width, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            text?.draw(at: NSPoint(x: 21, y: (18 - textSize.height) / 2), withAttributes: attributes)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            let board = CGRect(x: 1.7, y: 2.7, width: 14.6, height: 12.6)
            ctx.setLineWidth(1.4)
            ctx.addPath(CGPath(roundedRect: board, cornerWidth: 3.4, cornerHeight: 3.4, transform: nil))
            ctx.strokePath()

            let dotX: CGFloat = 5.3
            let rows: [(y: CGFloat, end: CGFloat)] = [(6.2, 13.2), (9.0, 12.0), (11.8, 10.4)]
            for row in rows {
                ctx.fillEllipse(in: CGRect(x: dotX - 0.95, y: row.y - 0.95, width: 1.9, height: 1.9))
                ctx.setLineWidth(1.3)
                ctx.move(to: CGPoint(x: 8.0, y: row.y))
                ctx.addLine(to: CGPoint(x: row.end, y: row.y))
                ctx.strokePath()
            }

            guard spin != nil || hasUnread else { return true }
            let center = CGPoint(x: 15.2, y: 3.6)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: center.x - 3.7, y: center.y - 3.7, width: 7.4, height: 7.4))
            ctx.setBlendMode(.normal)
            if let spin {
                ctx.setLineWidth(1.3)
                ctx.addArc(center: center, radius: 2.45, startAngle: spin, endAngle: spin + .pi * 1.4, clockwise: false)
                ctx.strokePath()
            }
            if hasUnread {
                let radius: CGFloat = spin == nil ? 2.3 : 1.0
                ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // Writes the icon's states as PNGs (`AgentDock --render-icon <folder>`),
    // for looking at it outside the menu bar.
    static func render(to folder: String) {
        let states: [(String, Double?, Bool)] = [("idle", nil, false), ("running", 0.6, false),
                                                 ("unread", nil, true), ("both", 0.6, true)]
        for (name, spin, hasUnread) in states {
            let icon = make(spin: spin, hasUnread: hasUnread, count: spin == nil ? 0 : 2)
            let width = Int(icon.size.width * 8)
            let height = 18 * 8
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            frame.fill()
            icon.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("icon-\(name).png"))
        }
    }
}

// Turns the running arc only while something runs, apart from the board's
// model so the dropdown is not redrawn eight times a second.
final class IconAnimator: ObservableObject {
    @Published var phase: Double = 0
    private var timer: Timer?

    func setSpinning(_ isSpinning: Bool) {
        if isSpinning, timer == nil {
            // Eight steps a turn, eight a second: MenuIcon caches the eight frames.
            let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase = (self.phase + .pi / 4).truncatingRemainder(dividingBy: .pi * 2)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !isSpinning, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }
}
