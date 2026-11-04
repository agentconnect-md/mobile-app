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

/// Build environment (from the xcconfig via Info.plist), the system sign-in sheet
/// (ASWebAuthenticationSession with an https callback) and the custom-scheme
/// fallback callback. Never logs URLs: they carry the authorization code.
final class NativeBridge: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?
  private var pending: FlutterResult?
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeBridge()
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
      ])
    case "debugTab":
      // `xcrun simctl launch <udid> <bundle> -acDebugTab 2`; only read by debug builds.
      result(UserDefaults.standard.object(forKey: "acDebugTab") as? String)
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
      authenticate(url: url, host: host, path: path, result: result)
    case "cancel":
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authenticate(url: URL, host: String, path: String, result: @escaping FlutterResult) {
    if pending != nil {
      finish(nil, error: FlutterError(code: "CANCELED", message: nil, details: nil))
    }
    pending = result
    // `.https` needs the host's AASA to list this app (webcredentials); without
    // it iOS closes the sheet at once. Until then, complete on the fallback scheme
    // the callback page opens.
    let useHttps = Self.plist("ACHttpsCallback").uppercased() == "YES"
    let scheme = Self.plist("ACURLScheme")
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
