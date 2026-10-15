import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A new install starts empty, and nothing goes into a backup.
    AppData.prepare()
    // The phone first: on a VoIP-push launch the push is delivered right
    // after this returns, and the SDK's CallKit must be ready to report it.
    // The engine registers the accounts and rings calls with no Flutter UI.
    PhoneEngine.shared.start()
    // Missed-call and message banners also pop up while the app is open.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // On a background launch (VoIP push) there is no window yet; some plugins
    // look for one while registering.
    let needsStandIn = window == nil
    if needsStandIn {
      let standIn = UIWindow()
      standIn.rootViewController = UIViewController()
      window = standIn
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if needsStandIn { window = nil }
    MedutBridge.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
