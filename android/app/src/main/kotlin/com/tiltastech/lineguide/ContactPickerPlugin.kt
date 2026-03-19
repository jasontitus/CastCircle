package com.tiltastech.castcircle

import android.app.Activity
import android.content.Intent
import android.provider.ContactsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Android implementation of the contact picker channel.
 *
 * Uses Android's system contact picker intent to select a contact
 * and return {name, phone?, email?}.
 */
class ContactPickerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null

    companion object {
        private const val CHANNEL_NAME = "com.tiltastech.castcircle/contacts"
        private const val PICK_CONTACT_REQUEST = 2001
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickContact" -> {
                if (activity == null) {
                    result.error("NO_ACTIVITY", "Activity not available", null)
                    return
                }
                pendingResult = result
                val intent = Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI)
                activity?.startActivityForResult(intent, PICK_CONTACT_REQUEST)
            }
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_CONTACT_REQUEST) return false

        val result = pendingResult ?: return true
        pendingResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }

        try {
            val uri = data.data!!
            val contentResolver = activity?.contentResolver ?: run {
                result.success(null)
                return true
            }

            var name: String? = null
            var phone: String? = null
            var email: String? = null

            // Get contact name
            contentResolver.query(uri, arrayOf(
                ContactsContract.Contacts.DISPLAY_NAME,
                ContactsContract.Contacts._ID
            ), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    name = cursor.getString(0)
                    val contactId = cursor.getString(1)

                    // Get phone
                    contentResolver.query(
                        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                        "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
                        arrayOf(contactId), null
                    )?.use { phoneCursor ->
                        if (phoneCursor.moveToFirst()) {
                            phone = phoneCursor.getString(0)
                        }
                    }

                    // Get email
                    contentResolver.query(
                        ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
                        "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
                        arrayOf(contactId), null
                    )?.use { emailCursor ->
                        if (emailCursor.moveToFirst()) {
                            email = emailCursor.getString(0)
                        }
                    }
                }
            }

            result.success(mapOf(
                "name" to (name ?: ""),
                "phone" to phone,
                "email" to email
            ))
        } catch (e: Exception) {
            result.error("CONTACT_ERROR", e.message, null)
        }

        return true
    }
}
