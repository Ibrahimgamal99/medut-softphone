import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // PushKit first: on a VoIP-push launch the push is delivered right after
    // this returns, and CallKit must be ready to report it.
    _ = CallKitManager.shared
    CallKitManager.shared.startPushKit()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
