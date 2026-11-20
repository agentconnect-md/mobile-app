import AuthenticationServices
import Cocoa
import FlutterMacOS

/// The macOS side of method channel `agentconnect/native`: the same calls as
/// `NativeBridge` in ios/Runner/AppDelegate.swift (build environment from the
/// xcconfig via Info.plist, the system sign-in sheet, the custom-scheme
/// callback), plus the desktop pieces: the menu bar item, system
/// notifications and the main window. Never logs URLs: they carry the
/// authorization code.
final class NativeBridge: NSObject, FlutterPlugin, FlutterAppLifecycleDelegate,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?
  private var pending: FlutterResult?
  private var channel: FlutterMethodChannel?
  /// A link the app was launched with, until Dart asks for it.
  private var initialLink: String?
  /// A menu bar row or notification chosen before Dart was listening.
  private var initialOpen: [String: String]?
  private var dartReady = false
  private weak var window: NSWindow?
  /// Keeps the live stream and its timers running while no window shows
  /// (App Nap would otherwise delay them); the Mac may still sleep.
  private var activity: NSObjectProtocol?
  private(set) static var shared: NativeBridge?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeBridge()
    shared = instance
    let channel = FlutterMethodChannel(
      name: "agentconnect/native", binaryMessenger: registrar.messenger)
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    StatusItemController.shared.onPick = { [weak instance] kind, id in
      instance?.open(kind: kind, id: id)
    }
    StatusItemController.shared.onOpenApp = { [weak instance] in instance?.showWindow() }
    Notifier.shared.onOpen = { [weak instance] kind, id in instance?.open(kind: kind, id: id) }
    Notifier.shared.start()
  }

  /// The app's one window: sign-in is anchored on it, and Dart is told when
  /// it is in front (nothing is announced for the conversation being read).
  func attach(window: NSWindow) {
    self.window = window
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification,
      object: window)
    center.addObserver(
      self, selector: #selector(windowChanged), name: NSWindow.didResignKeyNotification,
      object: window)
    center.addObserver(
      self, selector: #selector(windowChanged), name: NSWindow.willCloseNotification,
      object: window)
  }

  @objc private func windowChanged(_ note: Notification) {
    let front = note.name != NSWindow.willCloseNotification && (window?.isKeyWindow ?? false)
    channel?.invokeMethod("windowFront", arguments: front)
  }

  /// Brings the main window forward, reopening it when it was closed.
  func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    (window as? MainFlutterWindow)?.reveal()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  /// A menu bar row or a notification was chosen: show the window on it.
  private func open(kind: String, id: String) {
    showWindow()
    let target = ["kind": kind, "id": id]
    if dartReady {
      channel?.invokeMethod("open", arguments: target)
    } else {
      initialOpen = target
    }
  }

  private static func plist(_ key: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
      .trimmingCharacters(in: .whitespaces) ?? ""
  }

  /// The package has the developer menu (xcconfig `AC_DEBUG_MENU`).
  private static var debugMenu: Bool { plist("ACDebugMenu").uppercased() == "YES" }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "env":
      result([
        "name": Self.plist("ACEnvName"),
        "apiBase": Self.plist("ACApiBase"),
        "callbackHost": Self.plist("ACCallbackHost"),
        "callbackPath": Self.plist("ACCallbackPath"),
        "urlScheme": Self.plist("ACURLScheme"),
        "debugMenu": Self.debugMenu ? "YES" : "NO",
        "altName": Self.plist("ACAltEnvName"),
        "altApiHost": Self.plist("ACAltApiHost"),
        "altApiPath": Self.plist("ACAltApiPath"),
        "altCallbackHost": Self.plist("ACAltCallbackHost"),
        "altUrlScheme": Self.plist("ACAltURLScheme"),
      ])
    case "debugTab":
      // `open -a AgentConnect --args -acDebugTab 2`; only read by debug builds.
      result(UserDefaults.standard.object(forKey: "acDebugTab") as? String)
    case "debugOpen":
      result(UserDefaults.standard.object(forKey: "acDebugOpen") as? String)
    case "initialLink":
      result(initialLink)
      initialLink = nil
    case "initialOpen":
      dartReady = true
      result(initialOpen)
      initialOpen = nil
    case "authenticate":
      guard let args = call.arguments as? [String: Any],
        let raw = args["url"] as? String, let url = URL(string: raw)
      else {
        result(FlutterError(code: "FAILED", message: "bad arguments", details: nil))
        return
      }
      authenticate(url: url, scheme: args["scheme"] as? String, result: result)
    case "cancel":
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
      result(nil)
    case "statusItem":
      if let snapshot = call.arguments as? [String: Any] {
        StatusItemController.shared.update(snapshot)
        keepAwake(snapshot["signedIn"] as? Bool ?? false)
      } else {
        StatusItemController.shared.remove()
        keepAwake(false)
      }
      result(nil)
    case "showWindow":
      showWindow()
      result(nil)
    case "windowStyle":
      // The title bar follows the app's own light or dark theme (which the
      // person can set apart from the system's) and takes its color.
      if let args = call.arguments as? [String: Any], let window {
        let dark = args["dark"] as? Bool ?? false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let argb = (args["color"] as? NSNumber)?.uint32Value {
          window.backgroundColor = NSColor(
            srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
        }
      }
      result(nil)
    case "closeWindow":
      window?.performClose(nil)
      result(nil)
    case "debugWindow":
      // Debug builds, for screenshots: `<scheme>://debug?size=760x520`.
      if let args = call.arguments as? [String: Any], let w = args["width"] as? Double,
        let h = args["height"] as? Double, let window
      {
        var frame = window.frame
        frame.origin.y += frame.height - CGFloat(h)
        frame.size = NSSize(width: CGFloat(w), height: CGFloat(h))
        window.setFrame(frame, display: true)
      }
      result(nil)
    case "debugNotifications":
      Notifier.shared.logState()
      result(nil)
    case "debugStatusMenu":
      result(nil)
      DispatchQueue.main.async { StatusItemController.shared.peek(seconds: 4) }
    case "notifyStatus":
      Notifier.shared.status(result)
    case "notifyRequest":
      Notifier.shared.request(result)
    case "notify":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String,
        let title = args["title"] as? String
      else {
        result(FlutterError(code: "FAILED", message: "bad arguments", details: nil))
        return
      }
      Notifier.shared.post(
        id: id, title: title, body: args["body"] as? String ?? "",
        kind: args["kind"] as? String ?? "", target: args["target"] as? String ?? "",
        group: args["group"] as? String)
      result(nil)
    case "notifyClear":
      Notifier.shared.clear(call.arguments as? [String] ?? [])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func keepAwake(_ on: Bool) {
    if on, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Watching agents for the menu bar and notifications")
    } else if !on, let a = activity {
      ProcessInfo.processInfo.endActivity(a)
      activity = nil
    }
  }

  /// The sheet completes on the server's fallback scheme, which the callback
  /// page's "Return to AgentConnect" button opens. (An https callback needs
  /// Associated Domains, which a Mac app gets only with a provisioning
  /// profile; this package has none.) [requested] nil or empty means this
  /// package's own scheme.
  private func authenticate(url: URL, scheme requested: String?, result: @escaping FlutterResult) {
    if pending != nil {
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
    }
    let own = Self.plist("ACURLScheme")
    let scheme = (requested ?? "").isEmpty ? own : requested!
    guard !scheme.isEmpty else {
      result(FlutterError(code: "FAILED", message: "no callback scheme", details: nil))
      return
    }
    pending = result
    let done: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let callback {
          self.finish(callback.absoluteString, error: nil)
        } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
          self.finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
        } else {
          self.finish(nil, error: FlutterError(code: "FAILED", message: nil, details: nil))
        }
      }
    }
    let s: ASWebAuthenticationSession
    if #available(macOS 14.4, *) {
      s = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: done)
    } else {
      s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: done)
    }
    s.presentationContextProvider = self
    // Not ephemeral: reuse the web console sign-in already in the browser.
    s.prefersEphemeralWebBrowserSession = false
    session = s
    if !s.start() {
      finish(nil, error: FlutterError(code: "FAILED", message: nil, details: nil))
    }
  }

  private func finish(_ url: String?, error: FlutterError?) {
    let r = pending
    pending = nil
    let s = session
    session = nil
    if url != nil || error != nil { s?.cancel() }
    if let url { r?(url) } else if let error { r?(error) }
  }

  /// `<scheme>://oauth/callback?...` opened outside the sign-in sheet (the
  /// callback page in an ordinary browser tab). Hands it to the waiting
  /// sign-in (state is checked in Dart). Other links of the scheme go to Dart.
  private func openCustomScheme(_ url: URL) -> Bool {
    let scheme = Self.plist("ACURLScheme")
    guard !scheme.isEmpty, url.scheme?.lowercased() == scheme.lowercased() else { return false }
    if url.host == "oauth", url.path == "/callback" {
      if pending != nil {
        finish(url.absoluteString, error: nil)
        showWindow()
      } else {
        channel?.invokeMethod("staleCallback", arguments: nil)
      }
      return true
    }
    if dartReady {
      channel?.invokeMethod("link", arguments: url.absoluteString)
    } else {
      initialLink = url.absoluteString
    }
    return true
  }

  func handleOpen(_ urls: [URL]) -> Bool {
    var handled = false
    for url in urls where openCustomScheme(url) { handled = true }
    return handled
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
  }
}
