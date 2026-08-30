import UIKit
import EmberRuntime

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // No `#if` around it: without EMBER_ENABLED the package compiles the
        // dialling and loading code out and this does nothing.
        Ember.start()
    }
}
