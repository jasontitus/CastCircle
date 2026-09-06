package com.tiltastech.castcircle

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Android implementation of the contact picker channel.
 *
 * Uses Android's system contact picker intent to select a contact
 * and return {name, phone?, email?}.
 */
class ContactPickerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var queryExecutor: ExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val CHANNEL_NAME = "com.tiltastech.castcircle/contacts"
        private const val PICK_CONTACT_REQUEST = 2001
        private const val READ_CONTACTS_REQUEST = 2002
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        queryExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "contact-picker-query")
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachActivityBinding()
        activity = null
        completePendingError("DETACHED", "Contact picker detached")
        queryExecutor?.shutdownNow()
        queryExecutor = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivityBinding(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivityBinding()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivityBinding(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivityBinding()
        activity = null
        completePendingError("NO_ACTIVITY", "Activity no longer available")
    }

    private fun attachActivityBinding(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    private fun detachActivityBinding() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickContact" -> pickContact(result)
            else -> result.notImplemented()
        }
    }

    private fun pickContact(result: MethodChannel.Result) {
        val currentActivity = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        if (pendingResult != null) {
            result.error("PICK_IN_PROGRESS", "A contact pick is already in progress", null)
            return
        }

        pendingResult = result
        if (ContextCompat.checkSelfPermission(currentActivity, Manifest.permission.READ_CONTACTS) !=
            PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.READ_CONTACTS),
                READ_CONTACTS_REQUEST,
            )
            return
        }
        launchPicker(currentActivity)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != READ_CONTACTS_REQUEST) return false
        val currentActivity = activity
        if (currentActivity == null) {
            completePendingError("NO_ACTIVITY", "Activity not available")
        } else {
            // A denied permission still permits the picked row's display name.
            launchPicker(currentActivity)
        }
        return true
    }

    private fun launchPicker(currentActivity: Activity) {
        if (pendingResult == null) return
        val intent = Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI)
        try {
            currentActivity.startActivityForResult(intent, PICK_CONTACT_REQUEST)
        } catch (e: ActivityNotFoundException) {
            completePendingError("PICKER_UNAVAILABLE", "No contact picker is available")
        } catch (e: SecurityException) {
            completePendingError("PICKER_UNAVAILABLE", e.message ?: "Contact picker is unavailable")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_CONTACT_REQUEST) return false
        val result = pendingResult ?: return true

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            completePendingSuccess(result, null)
            return true
        }

        val resolver = activity?.contentResolver
        if (resolver == null) {
            completePendingError("NO_ACTIVITY", "Activity not available")
            return true
        }

        try {
            queryExecutor?.execute {
                try {
                    val contact = readContact(resolver, uri)
                    mainHandler.post { completePendingSuccess(result, contact) }
                } catch (e: Exception) {
                    mainHandler.post {
                        completePendingError("CONTACT_ERROR", e.message ?: "Could not read contact")
                    }
                }
            } ?: completePendingError("DETACHED", "Contact picker detached")
        } catch (_: RejectedExecutionException) {
            completePendingError("DETACHED", "Contact picker detached")
        }
        return true
    }

    private fun readContact(
        contentResolver: ContentResolver,
        uri: android.net.Uri,
    ): Map<String, Any?> {
        var name: String? = null
        var phone: String? = null
        var email: String? = null

        contentResolver.query(
            uri,
            arrayOf(ContactsContract.Contacts.DISPLAY_NAME, ContactsContract.Contacts._ID),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.getString(0)
                val contactId = cursor.getString(1)
                try {
                    contentResolver.query(
                        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                        "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
                        arrayOf(contactId),
                        null,
                    )?.use { phoneCursor ->
                        if (phoneCursor.moveToFirst()) phone = phoneCursor.getString(0)
                    }
                } catch (_: SecurityException) {
                    // Permission can be denied or revoked after the picked-row grant.
                }

                try {
                    contentResolver.query(
                        ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
                        "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
                        arrayOf(contactId),
                        null,
                    )?.use { emailCursor ->
                        if (emailCursor.moveToFirst()) email = emailCursor.getString(0)
                    }
                } catch (_: SecurityException) {
                    // Preserve the already-read name/phone if permission changes.
                }
            }
        }

        return mapOf("name" to (name ?: ""), "phone" to phone, "email" to email)
    }

    private fun completePendingSuccess(result: MethodChannel.Result, value: Any?) {
        if (pendingResult !== result) return
        pendingResult = null
        result.success(value)
    }

    private fun completePendingError(code: String, message: String) {
        val result = pendingResult ?: return
        pendingResult = null
        result.error(code, message, null)
    }
}
