package com.tiltastech.castcircle

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android implementation of the contact picker channel.
 *
 * Uses Android's system contact picker intent to select a contact
 * and return {name, phone?, email?}.
 */
class ContactPickerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var contentResolver: ContentResolver? = null
    private var queryExecutor: ThreadPoolExecutor? = null
    private var pendingRequest: ContactRequest? = null

    private class ContactRequest(val result: MethodChannel.Result) {
        val processing = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
    }

    private data class ContactData(
        val name: String,
        val phone: String?,
        val email: String?,
    )

    companion object {
        private const val CHANNEL_NAME = "com.tiltastech.castcircle/contacts"
        private const val PICK_CONTACT_REQUEST = 2001
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contentResolver = binding.applicationContext.contentResolver
        queryExecutor = ThreadPoolExecutor(
            1,
            1,
            0L,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue(1),
            { runnable -> Thread(runnable, "contact-picker-query") },
            ThreadPoolExecutor.AbortPolicy(),
        )
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        completePendingWithError("PLUGIN_DETACHED", "Contact picker detached")
        queryExecutor?.shutdownNow()
        queryExecutor = null
        contentResolver = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        completePendingWithError("NO_ACTIVITY", "Activity detached during contact pick")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickContact" -> launchContactPicker(result)
            else -> result.notImplemented()
        }
    }

    private fun launchContactPicker(result: MethodChannel.Result) {
        if (pendingRequest != null) {
            result.error("PICK_IN_PROGRESS", "A contact pick is already in progress", null)
            return
        }
        val currentActivity = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        val request = ContactRequest(result)
        val intent = Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI)
        try {
            currentActivity.startActivityForResult(intent, PICK_CONTACT_REQUEST)
            // Publish only after Android accepts the launch. A synchronous
            // launch failure must not leave the channel permanently busy.
            pendingRequest = request
        } catch (t: Throwable) {
            result.error("PICK_FAILED", t.message ?: "Could not open contact picker", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_CONTACT_REQUEST) return false

        val request = pendingRequest ?: return true
        if (!request.processing.compareAndSet(false, true)) return true

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            completeRequest(request) { it.success(null) }
            return true
        }

        val resolver = contentResolver
        val executor = queryExecutor
        if (resolver == null || executor == null) {
            completeRequest(request) {
                it.error("CONTACT_ERROR", "Contact provider not available", null)
            }
            return true
        }

        try {
            executor.execute {
                val contact = try {
                    queryContact(resolver, uri)
                } catch (t: Throwable) {
                    mainHandler.post {
                        completeRequest(request) {
                            it.error("CONTACT_ERROR", t.message ?: t.toString(), null)
                        }
                    }
                    return@execute
                }
                mainHandler.post {
                    completeRequest(request) {
                        it.success(
                            mapOf(
                                "name" to contact.name,
                                "phone" to contact.phone,
                                "email" to contact.email,
                            ),
                        )
                    }
                }
            }
        } catch (t: Throwable) {
            completeRequest(request) {
                it.error("CONTACT_ERROR", t.message ?: "Contact query unavailable", null)
            }
        }
        return true
    }

    private fun queryContact(resolver: ContentResolver, uri: Uri): ContactData {
        var name: String? = null
        var phone: String? = null
        var email: String? = null
        resolver.query(
            uri,
            arrayOf(
                ContactsContract.Contacts.DISPLAY_NAME,
                ContactsContract.Contacts._ID,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.getString(0)
                val contactId = cursor.getString(1)
                try {
                    resolver.query(
                        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                        "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
                        arrayOf(contactId),
                        null,
                    )?.use { phoneCursor ->
                        if (phoneCursor.moveToFirst()) phone = phoneCursor.getString(0)
                    }
                } catch (_: SecurityException) {
                    // The picker grants the selected contact row, not the phone table.
                }
                try {
                    resolver.query(
                        ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                        arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
                        "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
                        arrayOf(contactId),
                        null,
                    )?.use { emailCursor ->
                        if (emailCursor.moveToFirst()) email = emailCursor.getString(0)
                    }
                } catch (_: SecurityException) {
                    // Preserve the already-read name/phone when email is restricted.
                }
            }
        }
        return ContactData(name ?: "", phone, email)
    }

    private fun completePendingWithError(code: String, message: String) {
        val request = pendingRequest ?: return
        completeRequest(request) { it.error(code, message, null) }
    }

    private fun completeRequest(
        request: ContactRequest,
        completion: (MethodChannel.Result) -> Unit,
    ) {
        if (!request.completed.compareAndSet(false, true)) return
        if (pendingRequest === request) pendingRequest = null
        completion(request.result)
    }
}
