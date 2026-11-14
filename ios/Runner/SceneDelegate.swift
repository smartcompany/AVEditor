import FBSDKCoreKit
import Flutter
import TikTokOpenSDKCore
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Facebook returns via `fb<appId>://…`; TikTok via its redirect / client-key
  /// scheme. Hand those to the SDKs only — do not forward them to Flutter.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    var remaining = Set<UIOpenURLContext>()
    for context in URLContexts {
      if context.url.scheme?.hasPrefix("fb") == true {
        ApplicationDelegate.shared.application(
          UIApplication.shared,
          open: context.url,
          sourceApplication: context.options.sourceApplication,
          annotation: context.options.annotation
        )
      } else if TikTokURLHandler.handleOpenURL(context.url) {
        continue
      } else {
        remaining.insert(context)
      }
    }
    if !remaining.isEmpty {
      super.scene(scene, openURLContexts: remaining)
    }
  }
}
