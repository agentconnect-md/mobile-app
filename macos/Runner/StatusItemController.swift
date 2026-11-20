import Cocoa

/// The menu bar item. Dart pushes a small snapshot (`statusItem` on the
/// method channel) whenever agents, conversations or approvals change; this
/// draws the icon and builds the menu from it. All text comes from Dart
/// (the app's localized strings); nothing here reads the network.
///
/// The icon is a template image (it follows the menu bar's light or dark
/// look) and shows state by shape, never by color alone:
///   idle     outlined diamond (the brand mark as line art)
///   running  the diamond with two opposite quarters filled
///   waiting  a solid diamond with "!" cut out, and the count beside it
final class StatusItemController: NSObject, NSMenuDelegate {
  static let shared = StatusItemController()

  /// A "Needs you" or agent row was chosen: (kind, id).
  var onPick: ((String, String) -> Void)?
  var onOpenApp: (() -> Void)?

  private static let autosaveName = "AgentConnect"
  private var item: NSStatusItem?
  private var snapshot: [String: Any] = [:]
  private let menu = NSMenu()

  func update(_ s: [String: Any]) {
    snapshot = s
    if item == nil {
      // macOS adds a new item at the far left of the status area, which on a
      // MacBook with a notch and a full menu bar is behind the notch: the item
      // exists but cannot be seen or moved. So the first time, ask for a place
      // among the visible ones (the value is the distance from the screen's
      // right edge, the same key AppKit writes when the person ⌘-drags an
      // item). After that their own placement is what is remembered.
      let place = "NSStatusItem Preferred Position \(Self.autosaveName)"
      if UserDefaults.standard.object(forKey: place) == nil {
        UserDefaults.standard.set(360, forKey: place)
      }
      let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      i.autosaveName = Self.autosaveName
      i.behavior = []
      menu.delegate = self
      menu.autoenablesItems = false
      i.menu = menu
      item = i
      // Seen on macOS 26: the image given in the same turn the item is made
      // can come out empty in the status area. Give it again once the item is up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self, let button = self.item?.button else { return }
        button.image = Self.icon(self.snapshot["state"] as? String ?? "idle")
      }
    }
    guard let button = item?.button else { return }
    let state = s["state"] as? String ?? "idle"
    let count = s["count"] as? Int ?? 0
    button.image = Self.icon(state)
    button.imagePosition = .imageLeading
    button.title = state == "waiting" && count > 0 ? " \(count)" : ""
    button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let tip = s["tooltip"] as? String ?? "AgentConnect"
    button.toolTip = tip
    button.setAccessibilityLabel(tip)
  }

  func remove() {
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil
  }

  /// Debug builds: shows the menu as a click would and closes it after
  /// [seconds], so a screenshot can be taken without clicking.
  func peek(seconds: TimeInterval) {
    guard let button = item?.button else { return }
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      self?.menu.cancelTracking()
    }
    RunLoop.main.add(timer, forMode: .common)
    button.performClick(nil)
  }

  // MARK: Icon

  /// Drawn into a bitmap (2x) rather than left as a drawing block: on macOS 26
  /// the status area is rendered in another process, where an image that is
  /// still a block comes out empty.
  private static func icon(_ state: String) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return image }
    // The size in points first: the context then draws in points at 2x.
    bitmap.size = size
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(state)
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
    image.isTemplate = true
    return image
  }

  private static func draw(_ state: String) {
    do {
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      let top = NSPoint(x: 9, y: 16.6), right = NSPoint(x: 16.6, y: 9)
      let bottom = NSPoint(x: 9, y: 1.4), left = NSPoint(x: 1.4, y: 9)
      let center = NSPoint(x: 9, y: 9)
      func shape(_ points: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: points[0])
        for q in points.dropFirst() { p.line(to: q) }
        p.close()
        p.lineJoinStyle = .round
        return p
      }
      NSColor.black.set()
      let diamond = shape([top, right, bottom, left])
      switch state {
      case "waiting":
        diamond.fill()
        // "!" cut out of the solid diamond.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(roundedRect: NSRect(x: 8.1, y: 7.6, width: 1.8, height: 5.2), xRadius: 0.9, yRadius: 0.9)
          .fill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 4.4, width: 2, height: 2)).fill()
      case "running":
        shape([top, center, left]).fill()
        shape([bottom, center, right]).fill()
        diamond.lineWidth = 1.3
        diamond.stroke()
      default:
        diamond.lineWidth = 1.3
        diamond.stroke()
        let cross = NSBezierPath()
        cross.move(to: top)
        cross.line(to: bottom)
        cross.move(to: left)
        cross.line(to: right)
        cross.lineWidth = 1
        cross.stroke()
      }
    }
  }

  // MARK: Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let s = snapshot
    func text(_ key: String, _ fallback: String) -> String { s[key] as? String ?? fallback }

    let signedIn = s["signedIn"] as? Bool ?? false
    let head = NSMenuItem(title: text("org", "AgentConnect"), action: nil, keyEquivalent: "")
    head.isEnabled = false
    if let summary = s["summary"] as? String, !summary.isEmpty { setSubtitle(head, summary) }
    menu.addItem(head)

    if signedIn {
      menu.addItem(.separator())
      addHeader(text("needsTitle", "Needs you"))
      let needs = s["needs"] as? [[String: Any]] ?? []
      if needs.isEmpty {
        let none = NSMenuItem(title: text("needsEmpty", "Nothing needs you"), action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)
      }
      for row in needs {
        let approval = row["approval"] as? Bool ?? false
        addRow(row, symbol: approval ? "hand.raised" : "ellipsis.bubble", tint: nil)
      }

      menu.addItem(.separator())
      addHeader(text("agentsTitle", "Agents"))
      let agents = s["agents"] as? [[String: Any]] ?? []
      if agents.isEmpty {
        let none = NSMenuItem(title: text("agentsEmpty", "No agents"), action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)
      }
      for row in agents {
        // A different glyph per state, so the state reads without its color.
        let (symbol, tint): (String, NSColor) =
          switch row["health"] as? String {
          case "online": ("circle.fill", .systemGreen)
          case "paused": ("pause.circle", .systemOrange)
          default: ("circle.slash", .secondaryLabelColor)
          }
        addRow(row, symbol: symbol, tint: tint)
      }
      if let more = s["agentsMore"] as? String, !more.isEmpty {
        let item = NSMenuItem(title: more, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["kind": "agents", "id": ""]
        menu.addItem(item)
      }
    }

    menu.addItem(.separator())
    let open = NSMenuItem(
      title: text("open", "Open AgentConnect"), action: #selector(openApp), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let quit = NSMenuItem(
      title: text("quit", "Quit AgentConnect"), action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    quit.target = NSApp
    menu.addItem(quit)
  }

  private func addHeader(_ title: String) {
    if #available(macOS 14.0, *) {
      menu.addItem(.sectionHeader(title: title))
    } else {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
  }

  private func setSubtitle(_ item: NSMenuItem, _ subtitle: String) {
    if #available(macOS 14.4, *) {
      item.subtitle = subtitle
    } else {
      item.title = "\(item.title) — \(subtitle)"
    }
  }

  private func addRow(_ row: [String: Any], symbol: String, tint: NSColor?) {
    let item = NSMenuItem(
      title: row["title"] as? String ?? "", action: #selector(pick(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = ["kind": row["kind"] as? String ?? "", "id": row["id"] as? String ?? ""]
    if let subtitle = row["subtitle"] as? String, !subtitle.isEmpty { setSubtitle(item, subtitle) }
    if var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
      if let tint, let colored = image.withSymbolConfiguration(.init(paletteColors: [tint])) {
        image = colored
      }
      item.image = image
    }
    menu.addItem(item)
  }

  @objc private func pick(_ sender: NSMenuItem) {
    guard let target = sender.representedObject as? [String: String] else { return }
    onPick?(target["kind"] ?? "", target["id"] ?? "")
  }

  @objc private func openApp() { onOpenApp?() }
}
