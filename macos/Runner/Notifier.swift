import Cocoa
import FlutterMacOS
import UserNotifications

/// System notifications. Dart decides what is worth one (it compares
/// successive states of the organization) and posts it here; a click comes
/// back as (kind, target) and opens that conversation or agent in the window.
/// Read-only: a notification has no actions.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()

  /// A notification was clicked: (kind, target).
  var onOpen: ((String, String) -> Void)?

  private var center: UNUserNotificationCenter { .current() }

  /// Set before the app finishes launching, so a click that launched the app
  /// is delivered too.
  func start() {
    center.delegate = self
  }

  /// "granted", "denied" or "undetermined" (never asked).
  func status(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      let value: String =
        switch settings.authorizationStatus {
        case .authorized, .provisional: "granted"
        case .denied: "denied"
        default: "undetermined"
        }
      DispatchQueue.main.async { result(value) }
    }
  }

  /// Shows the system's permission prompt when it was never answered.
  func request(_ result: @escaping FlutterResult) {
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      // The system can refuse outright, without a prompt: the reason is worth
      // a line in the log.
      if let error { NSLog("AgentConnect: notifications not authorized: %@", error.localizedDescription) }
      DispatchQueue.main.async { result(granted) }
    }
  }

  func post(id: String, title: String, body: String, kind: String, target: String, group: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["kind": kind, "target": target]
    if let group { content.threadIdentifier = group }
    center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
      if let error { NSLog("AgentConnect: notification not posted: %@", error.localizedDescription) }
    }
  }

  /// Debug builds: what the system says about this app's notifications
  /// (authorization, banner style, how many are delivered), to the log.
  func logState() {
    center.getNotificationSettings { settings in
      self.center.getDeliveredNotifications { delivered in
        NSLog(
          "AgentConnect: notifications authorization=%ld alert=%ld style=%ld center=%ld delivered=%ld",
          settings.authorizationStatus.rawValue, settings.alertSetting.rawValue, settings.alertStyle.rawValue,
          settings.notificationCenterSetting.rawValue, delivered.count)
      }
    }
  }

  func clear(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  /// Also shown while the app is in front: Dart already leaves out the
  /// conversation that is open there.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let kind = info["kind"] as? String, let target = info["target"] as? String
    {
      DispatchQueue.main.async { self.onOpen?(kind, target) }
    }
    completionHandler()
  }
}
