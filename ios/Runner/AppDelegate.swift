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
    // Plugin registrars come from pluginRegistry — applicationRegistrar is only
    // for app-level channels and does not conform to FlutterPluginRegistrar.
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NativeVideoEnginePlugin"
    ) {
      NativeVideoEnginePlugin.register(with: registrar)
    }
  }
}
