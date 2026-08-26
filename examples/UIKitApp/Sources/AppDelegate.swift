import UIKit

/// The classic UIKit entry point, kept because it is the one `watch` has to
/// describe differently from everything else: there is one delegate per
/// process, and a relaunched process starts from the built binary with no
/// patch in it, so an edit here is the one that really does need a build.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }
}
