import AuthenticationServices
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AgentConnectNative") {
      NativeBridge.register(with: registrar)
    }
  }
}

/// A shake reaches the window when no view handles it (it does not travel on to
/// the app delegate). It opens the developer menu in packages that have one
/// (`AC_DEBUG_MENU`); elsewhere `shake()` does nothing.
extension UIWindow {
  open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
    if motion == .motionShake { NativeBridge.shared?.shake() }
    super.motionEnded(motion, with: event)
  }
}

/// Build environment (from the xcconfig via Info.plist), the system sign-in sheet
/// (ASWebAuthenticationSession with an https callback) and the custom-scheme
/// fallback callback. Never logs URLs: they carry the authorization code.
final class NativeBridge: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?
  private var pending: FlutterResult?
  private var channel: FlutterMethodChannel?
  /// A console link the app was launched with, until Dart asks for it.
  private var initialLink: String?
  /// The bridge of the app's one engine, for the window's shake.
  private(set) static weak var shared: NativeBridge?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeBridge()
    shared = instance
    let channel = FlutterMethodChannel(
      name: "agentconnect/native", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  private static func plist(_ key: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
      .trimmingCharacters(in: .whitespaces) ?? ""
  }

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
      // `xcrun simctl launch <udid> <bundle> -acDebugTab 2`; only read by debug builds.
      result(UserDefaults.standard.object(forKey: "acDebugTab") as? String)
    case "initialLink":
      result(initialLink)
      initialLink = nil
    case "debugOpen":
      result(UserDefaults.standard.object(forKey: "acDebugOpen") as? String)
    case "authenticate":
      guard let args = call.arguments as? [String: Any],
        let raw = args["url"] as? String, let url = URL(string: raw),
        let host = args["host"] as? String, let path = args["path"] as? String
      else {
        result(FlutterError(code: "FAILED", message: "bad arguments", details: nil))
        return
      }
      authenticate(
        url: url, host: host, path: path, scheme: args["scheme"] as? String, result: result)
    case "cancel":
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The package has the developer menu (xcconfig `AC_DEBUG_MENU`).
  private static var debugMenu: Bool { plist("ACDebugMenu").uppercased() == "YES" }

  /// The window saw a shake. Only packages with the developer menu tell Dart.
  func shake() {
    if Self.debugMenu { channel?.invokeMethod("shake", arguments: nil) }
  }

  /// [scheme] is the server's fallback scheme; nil or empty means this package's own.
  private func authenticate(
    url: URL, host: String, path: String, scheme requested: String?,
    result: @escaping FlutterResult
  ) {
    if pending != nil {
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
    }
    pending = result
    // `.https` needs the host's AASA to list this app (webcredentials); without
    // it iOS closes the sheet at once. Until then, complete on the fallback scheme
    // the callback page opens. Only this package's own callback host is in the
    // app's Associated Domains, so any other server completes on its scheme.
    let ownHost = host.lowercased() == Self.plist("ACCallbackHost").lowercased()
    let useHttps = ownHost && Self.plist("ACHttpsCallback").uppercased() == "YES"
    let own = Self.plist("ACURLScheme")
    let scheme = (requested ?? "").isEmpty ? own : requested!
    let mode: ASWebAuthenticationSession.Callback =
      useHttps || scheme.isEmpty ? .https(host: host, path: path) : .customScheme(scheme)
    let s = ASWebAuthenticationSession(url: url, callback: mode) {
      [weak self] callback, error in
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
    s.presentationContextProvider = self
    // Not ephemeral: reuse the web console sign-in already in Safari.
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

  /// `<scheme>://oauth/callback?...` from the callback page's "Return to AgentConnect"
  /// button. Hands it to the waiting sign-in (state is checked in Dart).
  private func openCustomScheme(_ url: URL) -> Bool {
    let scheme = Self.plist("ACURLScheme")
    guard !scheme.isEmpty, url.scheme?.lowercased() == scheme.lowercased() else { return false }
    if url.host == "oauth", url.path == "/callback" {
      if pending != nil {
        finish(url.absoluteString, error: nil)
      } else {
        channel?.invokeMethod("staleCallback", arguments: nil)
      }
      return true
    }
    channel?.invokeMethod("link", arguments: url.absoluteString)
    return true
  }

  /// A console session page (`https://<console>/<org>/sessions/<id>…`) opened as a universal
  /// link. Other console pages (the sign-in callback among them) are left alone.
  private static func consoleLink(_ activity: NSUserActivity) -> String? {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL,
      url.scheme == "https", url.host?.lowercased() == plist("ACCallbackHost").lowercased(),
      url.path.contains("/sessions/")
    else { return nil }
    return url.absoluteString
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    // Launched from a link: kept until Dart is ready to ask for it.
    for a in connectionOptions?.userActivities ?? [] {
      if let link = Self.consoleLink(a) { initialLink = link }
    }
    return false
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    guard let link = Self.consoleLink(userActivity) else { return false }
    channel?.invokeMethod("link", arguments: link)
    return true
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    for c in URLContexts where openCustomScheme(c.url) { handled = true }
    return handled
  }

  func application(
    _ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    openCustomScheme(url)
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for s in scenes {
      if let w = s.windows.first(where: { $0.isKeyWindow }) { return w }
    }
    if let s = scenes.first { return s.windows.first ?? ASPresentationAnchor(windowScene: s) }
    return ASPresentationAnchor()
  }
}
