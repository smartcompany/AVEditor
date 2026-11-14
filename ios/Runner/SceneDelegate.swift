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
      } else if context.url.scheme == "easyclipshare" {
        // Safari fallback from the callback page: rebuild the redirect URI
        // the SDK expects and hand TikTok's result to it.
        _ = TikTokURLHandler.handleOpenURL(Self.tiktokRedirectURL(from: context.url))
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

  /// `easyclipshare://tiktok/callback?…` → `<TikTokRedirectURI>?…`.
  static func tiktokRedirectURL(from url: URL) -> URL? {
    guard let redirect = Bundle.main.object(forInfoDictionaryKey: "TikTokRedirectURI") as? String,
          var components = URLComponents(string: redirect)
    else { return nil }
    components.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
    return components.url
  }

  /// TikTok Share Kit returns through the universal link
  /// https://aveditorserver.vercel.app/tiktok/callback.
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       TikTokURLHandler.handleOpenURL(userActivity.webpageURL) {
      return
    }
    super.scene(scene, continue: userActivity)
  }
}
