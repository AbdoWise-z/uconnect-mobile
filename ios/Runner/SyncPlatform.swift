import Flutter
import Foundation
import Network
import UIKit
import UserNotifications

/// What folder sync asks the platform for beyond files: the iOS counterpart of
/// SyncPlatform.kt, on the same channels (see lib/app/sync_platform.dart):
///
///   "uconnect/power"           state() -> { wifi, charging }
///   "uconnect/power/events"    the same map whenever either changes
///   "uconnect/notify"          show(id, title, text) / cancel(id) / status()
///   "uconnect/storage"         freeSpace(path) -> bytes, or -1
///   "uconnect/window"          keepScreenOn(on)
///
/// "wifi" means an unmetered network: iOS calls the others (cellular, a
/// personal hotspot) expensive. "charging" is true when the battery state
/// cannot be read, as in the simulator: what cannot be told must not hold
/// sync back.
final class SyncPlatform: NSObject, FlutterPlugin, FlutterStreamHandler,
  UNUserNotificationCenterDelegate
{
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SyncPlatform()
    let messenger = registrar.messenger()
    FlutterMethodChannel(name: "uconnect/power", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in instance.power(call, result) }
    FlutterEventChannel(name: "uconnect/power/events", binaryMessenger: messenger)
      .setStreamHandler(instance)
    FlutterMethodChannel(name: "uconnect/notify", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in instance.notify(call, result) }
    FlutterMethodChannel(name: "uconnect/storage", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in instance.storage(call, result) }
    // The screen stays on while this device is another's display
    // (lib/app/keep_awake.dart).
    FlutterMethodChannel(name: "uconnect/window", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        if call.method == "keepScreenOn" {
          let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
          UIApplication.shared.isIdleTimerDisabled = on
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    // Shown as banners while the app is in front too: a sync problem is
    // worth saying whichever page is open.
    UNUserNotificationCenter.current().delegate = instance
    instance.start()
    // The registrar keeps the channels, not this object.
    retained = instance
  }

  private static var retained: SyncPlatform?

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "dev.uconnect.sync-platform")
  private var unmetered = true
  private var sink: FlutterEventSink?

  private func start() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(batteryChanged),
      name: UIDevice.batteryStateDidChangeNotification, object: nil)
    monitor.pathUpdateHandler = { [weak self] path in
      // No network at all is not a metered one: sync has nothing to do then
      // anyway, and "waiting for Wi-Fi" would be the wrong thing to say.
      let unmetered = path.status != .satisfied || !path.isExpensive
      DispatchQueue.main.async {
        guard let self = self, self.unmetered != unmetered else { return }
        self.unmetered = unmetered
        self.push()
      }
    }
    monitor.start(queue: queue)
  }

  private var charging: Bool {
    switch UIDevice.current.batteryState {
    case .unplugged: return false
    case .charging, .full, .unknown: return true
    @unknown default: return true
    }
  }

  private func state() -> [String: Any] { ["wifi": unmetered, "charging": charging] }

  private func push() { sink?(state()) }

  @objc private func batteryChanged() { push() }

  // MARK: - uconnect/power

  private func power(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "state": result(state())
    default: result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - uconnect/notify

  private func notify(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "show":
      let id = (args["id"] as? NSNumber)?.intValue ?? 0
      let content = UNMutableNotificationContent()
      content.title = args["title"] as? String ?? ""
      content.body = args["text"] as? String ?? ""
      content.sound = .default
      // Asks the first time; later calls get the answer at once.
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
          DispatchQueue.main.async {
            result(FlutterError(code: "denied", message: "Notifications are not allowed.", details: nil))
          }
          return
        }
        center.add(UNNotificationRequest(identifier: "sync-\(id)", content: content, trigger: nil)) { error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
        }
      }
    case "cancel":
      let id = (args["id"] as? NSNumber)?.intValue ?? 0
      center.removeDeliveredNotifications(withIdentifiers: ["sync-\(id)"])
      result(nil)
    case "status":
      // Whether a notification would be shown, without asking.
      center.getNotificationSettings { settings in
        let status: String
        switch settings.authorizationStatus {
        case .authorized: status = "allowed"
        case .provisional, .ephemeral: status = "quiet"
        case .denied: status = "denied"
        case .notDetermined: status = "unasked"
        @unknown default: status = "unasked"
        }
        DispatchQueue.main.async { result(status) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  // MARK: - uconnect/storage

  private func storage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "freeSpace":
      guard let path = args["path"] as? String else { return result(-1) }
      // The nearest folder that exists: a synced folder may not be made yet.
      var url = URL(fileURLWithPath: path)
      while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
        url.deleteLastPathComponent()
      }
      let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      if let free = values?.volumeAvailableCapacityForImportantUsage {
        result(free)
      } else {
        result(-1)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
