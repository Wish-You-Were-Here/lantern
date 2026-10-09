import AppKit
import Combine
import ServiceManagement

@main
enum LanternMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let ui = PanelModel()
    private let usage = UsageModel()
    private var panel: PanelController!
    private var bag = Set<AnyCancellable>()
    private var lastWaiting = 0
    private var lastIconKey = ""

    private var panelEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "panelEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "panelEnabled")
            panel.enabled = newValue
        }
    }

    /// App opened on click. Change with: defaults write se.wishyouwerehere.lantern editorApp "Cursor"
    private var editorApp: String {
        UserDefaults.standard.string(forKey: "editorApp") ?? "Visual Studio Code"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(
            store: store, ui: ui, usage: usage,
            onOpen: { [weak self] in self?.open($0) },
            onRemove: { [weak self] in self?.store.remove($0) })
        panel.enabled = panelEnabled

        store.$sessions
            .sink { [weak self] in self?.sessionsChanged($0) }
            .store(in: &bag)
    }

    private func sessionsChanged(_ sessions: [Session]) {
        let waiting = sessions.filter { $0.state == .waiting }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        if waiting > lastWaiting { NSApp.requestUserAttention(.informationalRequest) }
        lastWaiting = waiting

        let key = sessions.prefix(4).map(\.state.rawValue).joined(separator: ",")
        if key != lastIconKey {
            lastIconKey = key
            NSApp.applicationIconImage = DockIcon.make(sessions.prefix(4).map(\.state))
        }
    }

    private func open(_ s: Session) {
        guard !s.cwd.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", editorApp, s.cwd]
        try? p.run()
    }

    // Clicking the Dock icon toggles the panel
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelEnabled.toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        if store.sessions.isEmpty {
            let empty = NSMenuItem(title: "No Active Sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for s in store.sessions {
            let detail = s.detail.isEmpty ? s.state.label : s.detail
            let remote = s.isRemote ? " 📱" : ""
            let item = NSMenuItem(title: "\(s.state.emoji)  \(s.name)\(remote) — \(detail)",
                                  action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addItem(to: menu, "Show Panel", #selector(togglePanel), on: panelEnabled)
        addItem(to: menu, "Clear Done", #selector(clearDone), on: nil)
        addItem(to: menu, "Open at Login", #selector(toggleLogin),
                on: SMAppService.mainApp.status == .enabled)
        return menu
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, on: Bool?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = store.sessions.first(where: { $0.id == id }) else { return }
        open(s)
    }

    @objc private func togglePanel() { panelEnabled.toggle() }

    @objc private func clearDone() { store.removeDone() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Lantern: could not change login item: \(error)")
        }
    }
}

/// Draws the Dock icon: up to four dots in session order (waiting first).
enum DockIcon {
    static func make(_ states: [SessionState]) -> NSImage {
        let colors = states.map(Palette.nsColor)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let box = rect.insetBy(dx: 50, dy: 50)
            let tile = NSBezierPath(roundedRect: box, xRadius: 92, yRadius: 92)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.shadowBlurRadius = 16
            shadow.set()
            NSColor.black.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.24, alpha: 1),
                       ending: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1))?
                .draw(in: tile, angle: -90)

            let rim = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: 90.5, yRadius: 90.5)
            rim.lineWidth = 3
            NSColor(white: 1, alpha: 0.10).setStroke()
            rim.stroke()

            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
                let c = NSPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
                NSGradient(starting: color.withAlphaComponent(0.45), ending: color.withAlphaComponent(0))?
                    .draw(fromCenter: c, radius: r, toCenter: c, radius: r * 1.8, options: [])
                let disc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                NSGradient(starting: color.blended(withFraction: 0.4, of: .white) ?? color, ending: color)?
                    .draw(in: disc, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
            }

            switch colors.count {
            case 0:
                let ring = NSBezierPath(ovalIn: NSRect(x: box.midX - 70, y: box.midY - 70, width: 140, height: 140))
                ring.lineWidth = 16
                NSColor(white: 0.45, alpha: 1).setStroke()
                ring.stroke()
            case 1:
                dot(0.5, 0.5, 90, colors[0])
            case 2:
                dot(0.3, 0.5, 62, colors[0])
                dot(0.7, 0.5, 62, colors[1])
            default:
                let grid: [(CGFloat, CGFloat)] = [(0.3, 0.7), (0.7, 0.7), (0.3, 0.3), (0.7, 0.3)]
                for (i, c) in colors.enumerated() { dot(grid[i].0, grid[i].1, 62, c) }
            }
            return true
        }
    }
}
