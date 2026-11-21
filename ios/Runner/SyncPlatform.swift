import Flutter
import Foundation
import Network
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// What folder sync asks the platform for beyond files: the iOS counterpart of
/// SyncPlatform.kt, on the same channels (see lib/app/sync_platform.dart):
///
///   "uconnect/power"           state() -> { wifi, charging }
///   "uconnect/power/events"    the same map whenever either changes
///   "uconnect/notify"          show(id, title, text) / cancel(id) / status()
///   "uconnect/storage"         freeSpace(path) -> bytes, or -1
///                              pickFolder() -> path or null
///                              restoreFolders() -> { saved path: path now }
///                              adoptFolder(path) -> path or null
///                              releaseFolder(path)
///   "uconnect/window"          keepScreenOn(on)
///
/// "wifi" means an unmetered network: iOS calls the others (cellular, a
/// personal hotspot) expensive. "charging" is true when the battery state
/// cannot be read, as in the simulator: what cannot be told must not hold
/// sync back.
final class SyncPlatform: NSObject, FlutterPlugin, FlutterStreamHandler,
  UNUserNotificationCenterDelegate, UIDocumentPickerDelegate
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
    case "pickFolder":
      pickFolder(result)
    case "restoreFolders":
      result(restoreFolders())
    case "adoptFolder":
      guard let path = args["path"] as? String else { return result(nil) }
      result(adopt(URL(fileURLWithPath: path, isDirectory: true)))
    case "releaseFolder":
      if let path = args["path"] as? String { release(path) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - folders outside the app
  //
  // A folder the user picks in the Files picker (iCloud Drive, "On My iPhone",
  // another app's folder) lies outside this app's container. iOS lets the app
  // into it only while a "security scope" on its URL is open, and only for as
  // long as the app runs, unless the app keeps a bookmark: opaque data from
  // which the URL, and the right to open its scope, can be had again at the
  // next launch. So a picked folder is bookmarked at once, the bookmarks live
  // in the app's defaults under the path they were made for, and at each
  // launch all of them are resolved and their scopes opened before anything
  // reads a file. The scope is process-wide, so the library and the sync
  // isolate then use the folder by its plain path.

  private let bookmarksKey = "UCFolderBookmarks"
  /// Folders whose scope is open, by path.
  private var scoped: [String: URL] = [:]
  private var pendingPick: FlutterResult?

  private func bookmarks() -> [String: Data] {
    UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
  }

  /// Opens `url`'s scope and remembers a bookmark for it; its path, or nil
  /// when iOS will not give a bookmark (the folder is gone, or not ours to
  /// keep).
  private func adopt(_ url: URL) -> String? {
    let opened = url.startAccessingSecurityScopedResource()
    guard
      let data = try? url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    else {
      if opened { url.stopAccessingSecurityScopedResource() }
      return nil
    }
    let path = url.path
    var all = bookmarks()
    all[path] = data
    UserDefaults.standard.set(all, forKey: bookmarksKey)
    // One open scope per folder: opens and closes must balance.
    if let earlier = scoped.removeValue(forKey: path) {
      earlier.stopAccessingSecurityScopedResource()
    }
    if opened { scoped[path] = url }
    return path
  }

  /// Resolves every bookmark and opens its scope. Maps the path each was
  /// saved under to where the folder is now (the provider may have moved it),
  /// or to "" when it cannot be reached at present.
  private func restoreFolders() -> [String: String] {
    var out: [String: String] = [:]
    var all = bookmarks()
    var changed = false
    for (saved, data) in all {
      var stale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: data, options: [], relativeTo: nil,
          bookmarkDataIsStale: &stale)
      else {
        // Kept: a folder on a drive that is unplugged, or in an account that
        // is signed out, comes back.
        out[saved] = ""
        continue
      }
      let path = url.path
      if scoped[path] == nil, url.startAccessingSecurityScopedResource() {
        scoped[path] = url
      }
      if stale || path != saved {
        // iOS asks for a stale bookmark to be made anew; a moved folder is
        // kept under its new path.
        if let fresh = try? url.bookmarkData(
          options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        {
          all.removeValue(forKey: saved)
          all[path] = fresh
          changed = true
        }
      }
      out[saved] = path
    }
    if changed { UserDefaults.standard.set(all, forKey: bookmarksKey) }
    return out
  }

  private func release(_ path: String) {
    if let url = scoped.removeValue(forKey: path) {
      url.stopAccessingSecurityScopedResource()
    }
    var all = bookmarks()
    if all.removeValue(forKey: path) != nil {
      UserDefaults.standard.set(all, forKey: bookmarksKey)
    }
  }

  private func pickFolder(_ result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      return result(FlutterError(code: "busy", message: "a folder is being picked", details: nil))
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window =
      scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    guard var top = window?.rootViewController else {
      return result(FlutterError(code: "no-window", message: "no window to show it in", details: nil))
    }
    while let above = top.presentedViewController { top = above }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingPick = result
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    let result = pendingPick
    pendingPick = nil
    guard let url = urls.first else {
      result?(nil)
      return
    }
    result?(adopt(url))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingPick
    pendingPick = nil
    result?(nil)
  }
}
