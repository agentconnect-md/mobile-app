import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
