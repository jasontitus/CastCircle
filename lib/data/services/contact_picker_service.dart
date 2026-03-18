import 'package:flutter/services.dart';

/// Result from picking a contact.
class PickedContact {
  final String displayName;
  final String? phone;
  final String? email;

  const PickedContact({
    required this.displayName,
    this.phone,
    this.email,
  });
}

/// Lightweight contact picker using a native platform channel.
/// Avoids the flutter_contacts plugin which crashes on iOS 26 beta.
class ContactPickerService {
  ContactPickerService._();
  static final instance = ContactPickerService._();

  static const _channel = MethodChannel('com.tiltastech.castcircle/contacts');

  /// Open the system contact picker and return the selected contact.
  /// Returns null if the user cancels.
  Future<PickedContact?> pickContact() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>('pickContact');
      if (result == null) return null;
      return PickedContact(
        displayName: result['name'] ?? '',
        phone: result['phone'],
        email: result['email'],
      );
    } on PlatformException catch (e) {
      // User cancelled or permission denied
      if (e.code == 'CANCELLED') return null;
      rethrow;
    } on MissingPluginException {
      // Platform channel not registered (e.g. on macOS/web)
      return null;
    }
  }
}
