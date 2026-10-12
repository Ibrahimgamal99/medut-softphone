import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // Answered from the lock screen, then opened the app: show the call.
    CallScreenPresenter.present()
  }
}
