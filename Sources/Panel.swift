import AppKit
import SwiftUI
import Combine

enum Palette {
    static func color(_ s: SessionState) -> Color {
        switch s {
        case .waiting: Color(red: 0.89, green: 0.29, blue: 0.29)
        case .working: Color(red: 0.94, green: 0.62, blue: 0.15)
        case .done: Color(red: 0.36, green: 0.79, blue: 0.65)
        }
    }

    static func nsColor(_ s: SessionState) -> NSColor { NSColor(color(s)) }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        return "\(Int(s / 3600)) h"
    }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var hovered: String?
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: PanelModel
    @ObservedObject var usage: UsageModel
    let onOpen: @MainActor (Session) -> Void
    let onRemove: @MainActor (Session) -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Fixed reserved area: hover must never change the panel's size, or it jumps.
            // The area is transparent, so clicks pass through to whatever is behind it.
            Color.clear
                .frame(height: 48)
                .overlay(alignment: .bottom) {
                    if ui.hovered == QuotaView.hoverID {
                        QuotaCaption(usage: usage)
                            .fixedSize()
                            .transition(.opacity)
                    } else if let id = ui.hovered, let s = store.sessions.first(where: { $0.id == id }) {
                        HoverCaption(session: s)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
            HStack(spacing: 4) {
                ForEach(store.sessions) { s in
                    Chip(session: s, ui: ui)
                        .onTapGesture { onOpen(s) }
                        .contextMenu {
                            Button("Open in Editor") { onOpen(s) }
                            if let url = s.remoteURL.flatMap(URL.init(string:)) {
                                Button("Open Remote Session") { NSWorkspace.shared.open(url) }
                            }
                            Button("Remove from List") { onRemove(s) }
                        }
                }
                if let five = usage.snapshot?.fiveHour {
                    if !store.sessions.isEmpty {
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 0.5, height: 16)
                            .padding(.horizontal, 4)
                    }
                    QuotaView(window: five, ui: ui)
                        .onTapGesture { usage.refresh() }
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .fixedSize()
        }
        .frame(minWidth: 400)
        .fixedSize()
        .padding(10)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.12), value: ui.hovered)
    }
}

private struct Chip: View {
    let session: Session
    @ObservedObject var ui: PanelModel

    var body: some View {
        let waiting = session.state == .waiting
        let hovered = ui.hovered == session.id
        HStack(spacing: 7) {
            SessionGlyph(state: session.state)
                .frame(width: 14, height: 14)
            Text(session.name)
                .font(.system(size: 13, weight: .medium))
            if session.isRemote {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
            }
            if session.produced > 0 {
                Text(Format.tokens(session.produced))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .opacity(0.55)
            }
        }
        .lineLimit(1)
        .foregroundStyle(waiting ? Color(red: 1, green: 0.62, blue: 0.62) : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                waiting ? Palette.color(.waiting).opacity(hovered ? 0.34 : 0.24)
                        : Color.white.opacity(hovered ? 0.10 : 0)))
        .contentShape(Capsule())
        .onHover { inside in
            if inside { ui.hovered = session.id }
            else if ui.hovered == session.id { ui.hovered = nil }
        }
    }
}

/// Star glyph in the style of Claude Code's terminal spinner.
/// Working: cycles through glyphs. Waiting: pulses. Done: still.
/// Animated by Core Animation, which runs in the window server – the app does no work per frame.
private struct SessionGlyph: NSViewRepresentable {
    let state: SessionState

    func makeNSView(context: Context) -> GlyphView { GlyphView() }
    func updateNSView(_ view: GlyphView, context: Context) { view.state = state }
}

private final class GlyphView: NSView {
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let side: CGFloat = 20
    private static var images: [String: CGImage] = [:]

    private let glyph = CALayer()

    var state: SessionState? {
        didSet { if state != oldValue { apply() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        glyph.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        glyph.contentsScale = 2
        layer?.addSublayer(glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func apply() {
        guard let state else { return }
        let color = Palette.nsColor(state)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.removeAllAnimations()
        glyph.contents = Self.image("✻", color, state) as Any?
        CATransaction.commit()

        switch state {
        case .working:
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = Self.frames.compactMap { Self.image($0, color, state) }
            a.keyTimes = (0...Self.frames.count).map { NSNumber(value: Double($0) / Double(Self.frames.count)) }
            a.calculationMode = .discrete
            a.duration = 0.12 * Double(Self.frames.count)
            a.repeatCount = .infinity
            glyph.add(a, forKey: "spin")
        case .waiting:
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.55
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyph.add(a, forKey: "pulse")
        case .done:
            break
        }
    }

    /// Glyphs are drawn once per state and reused.
    private static func image(_ s: String, _ color: NSColor, _ state: SessionState) -> CGImage? {
        let key = s + state.rawValue
        if let img = images[key] { return img }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: color,
        ])
        let size = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        str.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        images[key] = rep.cgImage
        return rep.cgImage
    }
}

private struct HoverCaption: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.detail.isEmpty ? session.state.label : session.detail)
                .font(.system(size: 12, weight: .medium))
            // Only ticks while the caption is visible
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                Text(meta(ctx.date))
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func meta(_ now: Date) -> String {
        var parts = ["\(session.state.label) · \(Format.ago(session.updated, now: now))"]
        if session.isRemote { parts.append("remote control") }
        if let p = session.contextPercent { parts.append("context \(p)%") }
        if session.produced > 0 { parts.append("\(Format.tokens(session.produced)) tokens") }
        return parts.joined(separator: " · ")
    }
}

/// The 5-hour quota: "45% · 215m".
private struct QuotaView: View {
    static let hoverID = "__quota"
    let window: UsageWindow
    @ObservedObject var ui: PanelModel

    private var minutesLeft: Int? {
        guard window.utilization > 0, let r = window.resetsAt, r.timeIntervalSinceNow > 0 else { return nil }
        return max(Int(ceil(r.timeIntervalSinceNow / 60)), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(UsageModel.severityColor(window.fraction))
                    .frame(width: 44 * window.fraction)
            }
            .frame(width: 44, height: 5)
            Text("\(Int(window.utilization.rounded()))%" + (minutesLeft.map { " · \($0)m" } ?? ""))
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(ui.hovered == Self.hoverID ? 0.10 : 0)))
        .contentShape(Capsule())
        .onHover { inside in
            if inside { ui.hovered = Self.hoverID }
            else if ui.hovered == Self.hoverID { ui.hovered = nil }
        }
    }
}

private struct QuotaCaption: View {
    @ObservedObject var usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let f = usage.snapshot?.fiveHour {
                Text(line("Session (5h)", f)).font(.system(size: 12, weight: .medium))
            }
            if let w = usage.snapshot?.sevenDay {
                Text(line("Week", w)).font(.system(size: 12))
            }
            Text(footer).font(.system(size: 11)).opacity(0.6)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func line(_ label: String, _ w: UsageWindow) -> String {
        var s = "\(label): \(Int(w.utilization.rounded()))%"
        if let r = w.resetText { s += " · \(r)" }
        if let t = w.timeLeftText { s += " (\(t))" }
        return s
    }

    private var footer: String {
        if let e = usage.lastError { return e.description }
        return [usage.lastUpdatedText, "click to refresh"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Window

/// Non-activating panel, visible on all Spaces (but not in full screen), sitting just above the Dock.
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let panel: StatusPanel
    private let hosting: NSHostingView<PanelView>
    /// Measures the view; NSHostingView with sizingOptions = [] reports fittingSize 0×0.
    private let measurer: NSHostingController<PanelView>
    private let store: SessionStore
    private let usage: UsageModel
    private var bag = Set<AnyCancellable>()

    var enabled = true { didSet { update() } }

    init(store: SessionStore, ui: PanelModel, usage: UsageModel,
         onOpen: @escaping @MainActor (Session) -> Void,
         onRemove: @escaping @MainActor (Session) -> Void) {
        self.store = store
        self.usage = usage
        let root = PanelView(store: store, ui: ui, usage: usage, onOpen: onOpen, onRemove: onRemove)
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        measurer = NSHostingController(rootView: root)

        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting

        // Only session data drives the size – not hover
        store.objectWillChange
            .merge(with: usage.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)

        update()
    }

    /// The screen with the Dock at the bottom; otherwise the main screen.
    private var dockScreen: NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.minY > $0.frame.minY } ?? NSScreen.screens.first
    }

    func update() {
        let hasContent = !store.sessions.isEmpty || usage.snapshot?.fiveHour != nil
        guard enabled, hasContent, let screen = dockScreen else {
            panel.orderOut(nil)
            return
        }
        let measured = measurer.sizeThatFits(in: NSSize(width: 4000, height: 1000))
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        guard size.width > 1, size.height > 1 else {
            NSLog("Lantern: panel measured \(size), not showing")
            panel.orderOut(nil)
            return
        }
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.visibleFrame.minY - 4,   // the view's padding leaves room above the Dock
            width: size.width,
            height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
