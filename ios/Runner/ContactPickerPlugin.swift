import Flutter
import UIKit
import ContactsUI

final class ContactPickerResultGate {
    private var pending: FlutterResult?

    var isActive: Bool { pending != nil }

    func begin(_ result: @escaping FlutterResult) -> Bool {
        guard pending == nil else { return false }
        pending = result
        return true
    }

    func resolve(_ value: Any?) {
        guard let result = pending else { return }
        pending = nil
        result(value)
    }
}

/// Native contact picker using CNContactPickerViewController.
/// Opens the system contact picker and returns name + phone/email.
class ContactPickerPlugin: NSObject, FlutterPlugin, CNContactPickerDelegate {
    private let resultGate = ContactPickerResultGate()

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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    result(FlutterError(
                        code: "PLUGIN_UNAVAILABLE",
                        message: "Contact picker was released",
                        details: nil
                    ))
                    return
                }
                self.handle(call, result: result)
            }
            return
        }

        switch call.method {
        case "pickContact":
            pickContact(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func pickContact(result: @escaping FlutterResult) {
        guard !resultGate.isActive else {
            result(FlutterError(
                code: "ALREADY_ACTIVE",
                message: "A contact picker is already active",
                details: nil
            ))
            return
        }

        // Do not retain the callback until presentation is actually possible.
        guard let viewController = Self.topViewController() else {
            result(FlutterError(
                code: "NO_VIEW_CONTROLLER",
                message: "Cannot present contact picker",
                details: nil
            ))
            return
        }

        guard resultGate.begin(result) else {
            result(FlutterError(
                code: "ALREADY_ACTIVE",
                message: "A contact picker is already active",
                details: nil
            ))
            return
        }

        let picker = CNContactPickerViewController()
        picker.delegate = self
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

        resultGate.resolve(resultMap)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        resultGate.resolve(FlutterError(
            code: "CANCELLED",
            message: "User cancelled",
            details: nil
        ))
    }
}
