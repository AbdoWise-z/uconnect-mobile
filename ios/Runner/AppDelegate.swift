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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "InviteLinks") {
      InviteLinks.register(with: registrar)
    }
  }
}

/// Hands uconn:// invite links (from a scanned QR code or a tapped link) to
/// Dart over the "uconnect/link" channel, like MainActivity does on Android
/// (see lib/app/invite_links.dart). Registered as a plugin so it receives the
/// scene's URL callbacks under the UIScene lifecycle, and the application's
/// under the older one.
final class InviteLinks: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private var channel: FlutterMethodChannel?
  private var pending: String?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = InviteLinks()
    let channel = FlutterMethodChannel(name: "uconnect/link", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "initial" {
      result(pending)
      pending = nil
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private func receive(_ url: URL?) -> Bool {
    guard let url = url, url.scheme?.lowercased() == "uconn" else { return false }
    let link = url.absoluteString
    pending = link
    channel?.invokeMethod("link", arguments: link) { [weak self] reply in
      if reply is FlutterError { return }
      if let object = reply as AnyObject?, object === FlutterMethodNotImplemented { return }
      if self?.pending == link { self?.pending = nil }
    }
    return true
  }

  // UIScene lifecycle: a link that launched the app, then later ones.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    return receive(connectionOptions?.urlContexts.first?.url)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return receive(URLContexts.first?.url)
  }

  // Older application lifecycle.
  func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return receive(url)
  }
}
