import UIKit

enum PushTokenStore {
    static let key = "chaching.apns.deviceToken"

    static func save(_ token: String) {
        UserDefaults.standard.set(token, forKey: key)
        NotificationCenter.default.post(name: .chachingAPNsTokenAvailable, object: nil)
    }
}

extension Notification.Name {
    static let chachingAPNsTokenAvailable = Notification.Name("chaching.apns.tokenAvailable")
}

final class ChaChingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushTokenStore.save(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        debugPrint("APNs registration failed:", error.localizedDescription)
    }
}
