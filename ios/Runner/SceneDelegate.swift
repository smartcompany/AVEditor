import FBSDKCoreKit
import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// The Facebook app returns to `fb<appId>://share?...` after a share.
  /// Hand those to the Facebook SDK only — do not forward them to Flutter,
  /// or MaterialApp treats `/share` as a missing named route and crashes.
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
      } else {
        remaining.insert(context)
      }
    }
    if !remaining.isEmpty {
      super.scene(scene, openURLContexts: remaining)
    }
  }
}
