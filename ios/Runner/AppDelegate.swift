import FBSDKCoreKit
import FBSDKShareKit
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if MediaShareChannel.facebookConfigured {
      ApplicationDelegate.shared.application(
        application,
        didFinishLaunchingWithOptions: launchOptions
      )
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Non-scene / fallback path for `fb<appId>://` return URLs.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme?.hasPrefix("fb") == true {
      return ApplicationDelegate.shared.application(app, open: url, options: options)
    }
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Plugin registrars come from pluginRegistry — applicationRegistrar is only
    // for app-level channels and does not conform to FlutterPluginRegistrar.
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NativeVideoEnginePlugin"
    ) {
      NativeVideoEnginePlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "MediaShareChannel"
    ) {
      MediaShareChannel.register(messenger: registrar.messenger())
    }
  }
}

/// Saves exports to Photos while keeping the asset id, and hands that asset
/// to Instagram so its editor opens with the video already selected.
enum MediaShareChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "aveditor/media_share",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "saveVideo":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path", details: nil))
          return
        }
        saveVideo(path: path, result: result)
      case "shareFile":
        if let path = args?["path"] as? String {
          result(presentShareSheet(items: [URL(fileURLWithPath: path)]))
        } else if let text = args?["text"] as? String {
          result(presentShareSheet(items: [text]))
        } else {
          result(FlutterError(code: "bad_args", message: "path/text", details: nil))
        }
      case "shareToFacebook":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path", details: nil))
          return
        }
        shareToFacebook(
          path: path,
          localIdentifier: args?["localIdentifier"] as? String,
          result: result
        )
      case "shareToWhatsApp":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path", details: nil))
          return
        }
        result(shareToWhatsApp(path: path))
      case "openInstagram":
        guard let id = args?["localIdentifier"] as? String else {
          result(FlutterError(code: "bad_args", message: "localIdentifier", details: nil))
          return
        }
        result(openInstagram(localIdentifier: id))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func saveVideo(path: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "photos_permission_denied", message: nil, details: nil))
        }
        return
      }
      var localIdentifier: String?
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(
          atFileURL: URL(fileURLWithPath: path)
        )
        localIdentifier = request?.placeholderForCreatedAsset?.localIdentifier
      }) { success, error in
        DispatchQueue.main.async {
          if success {
            result(localIdentifier)
          } else {
            result(FlutterError(
              code: "gallery_save_failed",
              message: error?.localizedDescription,
              details: nil
            ))
          }
        }
      }
    }
  }

  /// True once FACEBOOK_APP_ID / FACEBOOK_CLIENT_TOKEN are filled in
  /// (ios/Flutter/Facebook.xcconfig).
  static var facebookConfigured: Bool {
    let id = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String ?? ""
    let token = Bundle.main.object(forInfoDictionaryKey: "FacebookClientToken") as? String ?? ""
    return !id.isEmpty && id != "0" && !token.isEmpty
  }

  private static var facebookDialog: ShareDialog?
  private static var facebookDelegate: FacebookShareDelegate?

  /// Opens the Facebook app's composer with the video attached. Uses the
  /// Photos asset when readable, otherwise the file data.
  /// Replies with {"status": "unavailable"} right away when the SDK is not
  /// configured or Facebook cannot take it; otherwise once the user comes
  /// back: "posted", "cancelled" or "failed" (+ "message").
  private static func shareToFacebook(
    path: String,
    localIdentifier: String?,
    result: @escaping FlutterResult
  ) {
    guard facebookConfigured, let top = topViewController() else {
      result(["status": "unavailable"])
      return
    }
    let video: ShareVideo
    var source = "data"
    if let id = localIdentifier,
       let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
      video = ShareVideo(videoAsset: asset)
      source = "asset"
    } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
      video = ShareVideo(data: data)
    } else {
      result(["status": "unavailable"])
      return
    }
    let content = ShareVideoContent()
    content.video = video
    let delegate = FacebookShareDelegate(source: source) { reply in
      facebookDialog = nil
      facebookDelegate = nil
      result(reply)
    }
    let dialog = ShareDialog(viewController: top, content: content, delegate: delegate)
    dialog.mode = .native
    do {
      try dialog.validate()
    } catch {
      result(["status": "unavailable", "message": error.localizedDescription, "source": source])
      return
    }
    guard dialog.canShow else {
      result(["status": "unavailable", "source": source])
      return
    }
    facebookDialog = dialog
    facebookDelegate = delegate
    if !dialog.show() {
      facebookDialog = nil
      facebookDelegate = nil
      result(["status": "unavailable", "source": source])
    }
  }

  /// Held while the "Open in" menu is up; UIKit does not retain it.
  private static var documentController: UIDocumentInteractionController?

  /// WhatsApp's documented hand-off: a `.wam` copy with the
  /// `net.whatsapp.movie` type shows a menu with only WhatsApp in it, which
  /// then opens its chat picker with the video attached.
  private static func shareToWhatsApp(path: String) -> Bool {
    guard let whatsapp = URL(string: "whatsapp://app"),
          UIApplication.shared.canOpenURL(whatsapp),
          let view = topViewController()?.view
    else {
      return false
    }
    let source = URL(fileURLWithPath: path)
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipgo_share.wam")
    do {
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: source, to: copy)
    } catch {
      return false
    }
    let controller = UIDocumentInteractionController(url: copy)
    controller.uti = "net.whatsapp.movie"
    documentController = controller
    let anchor = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
    return controller.presentOpenInMenu(from: anchor, in: view, animated: true)
  }

  /// System share sheet. Presented from the top view controller because the
  /// scene-based app has no `UIApplication.delegate.window` for plugins.
  private static func presentShareSheet(items: [Any]) -> Bool {
    guard let top = topViewController() else { return false }
    let sheet = UIActivityViewController(
      activityItems: items,
      applicationActivities: nil
    )
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(
        x: top.view.bounds.midX, y: top.view.bounds.maxY - 1, width: 1, height: 1
      )
    }
    top.present(sheet, animated: true)
    return true
  }

  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private static func openInstagram(localIdentifier: String) -> Bool {
    var components = URLComponents()
    components.scheme = "instagram"
    components.host = "library"
    components.queryItems = [URLQueryItem(name: "LocalIdentifier", value: localIdentifier)]
    guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
      return false
    }
    UIApplication.shared.open(url)
    return true
  }
}

/// Reports the Facebook share dialog outcome back to Dart once.
final class FacebookShareDelegate: NSObject, SharingDelegate {
  private var reply: (([String: String]) -> Void)?
  private let source: String

  init(source: String, reply: @escaping ([String: String]) -> Void) {
    self.source = source
    self.reply = reply
  }

  private func finish(_ payload: [String: String]) {
    var payload = payload
    payload["source"] = source
    reply?(payload)
    reply = nil
  }

  func sharer(_ sharer: Sharing, didCompleteWithResults results: [String: Any]) {
    finish(["status": "posted"])
  }

  func sharer(_ sharer: Sharing, didFailWithError error: Error) {
    let nsError = error as NSError
    var message = nsError.localizedDescription
    if let developerMessage = nsError.userInfo["com.facebook.sdk:FBSDKErrorDeveloperMessageKey"] as? String {
      message += " | " + developerMessage
    }
    finish(["status": "failed", "message": "\(nsError.domain) \(nsError.code): \(message)"])
  }

  func sharerDidCancel(_ sharer: Sharing) {
    finish(["status": "cancelled"])
  }
}
