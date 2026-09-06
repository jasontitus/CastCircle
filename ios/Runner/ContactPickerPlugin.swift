import Flutter
import UIKit
import ContactsUI

/// Native contact picker using CNContactPickerViewController.
/// Opens the system contact picker and returns name + phone/email.
class ContactPickerPlugin: NSObject, FlutterPlugin, CNContactPickerDelegate {
    private var pendingResult: FlutterResult?

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let channel = FlutterMethodChannel(
            name: "com.tiltastech.castcircle/contacts",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        // Registration handled in AppDelegate
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickContact":
            pickContact(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func pickContact(result: @escaping FlutterResult) {
        guard pendingResult == nil else {
            result(FlutterError(
                code: "ALREADY_ACTIVE",
                message: "A contact picker is already open",
                details: nil
            ))
            return
        }

        // Use scene-based window lookup (required for iOS 15+ / scenes).
        // Do not retain the result until all presentation preconditions pass.
        guard let viewController = Self.topViewController() else {
            result(FlutterError(
                code: "NO_VIEW_CONTROLLER",
                message: "Cannot present contact picker",
                details: nil
            ))
            return
        }

        let picker = CNContactPickerViewController()
        picker.delegate = self
        pendingResult = result
        viewController.present(picker, animated: true)
    }

    /// Find the topmost view controller using the scene API.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        guard let rootVC = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }

        var top = rootVC
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - CNContactPickerDelegate

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""

        var phone: String? = nil
        if let firstPhone = contact.phoneNumbers.first {
            phone = firstPhone.value.stringValue
        }

        var email: String? = nil
        if let firstEmail = contact.emailAddresses.first {
            email = firstEmail.value as String
        }

        var resultMap: [String: String] = ["name": name]
        if let phone = phone { resultMap["phone"] = phone }
        if let email = email { resultMap["email"] = email }

        let result = pendingResult
        pendingResult = nil
        result?(resultMap)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        let result = pendingResult
        pendingResult = nil
        result?(FlutterError(code: "CANCELLED", message: "User cancelled", details: nil))
    }
}
