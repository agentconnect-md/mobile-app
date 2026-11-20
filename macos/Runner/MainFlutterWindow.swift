import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// `open -a AgentConnect --args -acStartHidden YES` starts in the menu bar
  /// only (for a login item): the window stays off screen until the person
  /// asks for it from the menu bar item, the Dock or a notification.
  private var staysHidden = UserDefaults.standard.bool(forKey: "acStartHidden")

  /// The Flutter engine only starts once its view has been on screen, so a
  /// hidden start still shows the window once, fully transparent, and takes
  /// it off screen again a moment later.
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if staysHidden && place != .out {
      alphaValue = 0
      ignoresMouseEvents = true
      super.order(place, relativeTo: otherWin)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, self.staysHidden else { return }
        self.orderOut(nil)
        self.reveal()
      }
      return
    }
    super.order(place, relativeTo: otherWin)
  }

  /// The person asked for the window: from now on it shows as usual.
  func reveal() {
    staysHidden = false
    alphaValue = 1
    ignoresMouseEvents = false
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // The title bar is the system's own, above the Flutter view: dragging,
    // double-click to zoom (or minimize, as the person set it), the traffic
    // lights and full screen all behave as in any Mac app, with no code here.
    // (Laying the Flutter view under the title bar looked more unified but put
    // those behaviors in the app's hands; it was tried and dropped.) The bar
    // only takes the app's color: transparent, it shows the window's
    // background, which Dart sets to match the theme (`windowStyle`).
    titlebarAppearsTransparent = true
    title = "AgentConnect"

    // Narrowest layout: icon sidebar, conversation list and a phone-width conversation.
    minSize = NSSize(width: 760, height: 520)
    // Closing the window keeps the app (menu bar item, notifications) running.
    isReleasedWhenClosed = false
    if !setFrameUsingName("MainWindow") {
      setContentSize(NSSize(width: 1120, height: 720))
      center()
    }
    setFrameAutosaveName("MainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    NativeBridge.register(with: flutterViewController.registrar(forPlugin: "AgentConnectNative"))
    NativeBridge.shared?.attach(window: self)

    super.awakeFromNib()
  }
}
