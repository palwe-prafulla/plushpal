package com.plushpal.app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.media.AudioFormat
import android.media.AudioRecord
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.ByteArrayOutputStream
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import kotlin.math.abs

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, TextToSpeech.OnInitListener {
    companion object {
        private const val logTag = "PlushBuddy"
        private const val debugSavePairingAction = "com.plushpal.app.DEBUG_SAVE_PAIRING"
        private const val pickVoiceSampleRequestCode = 7104
        private const val pickCharacterPhotoRequestCode = 7105
    }

    private val channelName = "com.plushpal/platform"
    private val vaultAlias = "com.plushpal.hardware-vault.v1"
    private val vaultPreferences = "plushpal_opaque_secrets"
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingWavResult: MethodChannel.Result? = null
    private var pendingAudioPickResult: MethodChannel.Result? = null
    private var pendingImagePickResult: MethodChannel.Result? = null
    private var pendingMicrophonePermissionResult: MethodChannel.Result? = null
    private var wavPlayer: MediaPlayer? = null
    private val speechRecording = AtomicBoolean(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        purgeLegacyClientOwnedData()
        handleDebugSavePairingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDebugSavePairingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(this)
        textToSpeech = TextToSpeech(this, this)
    }

    override fun onDestroy() {
        speechRecognizer?.destroy()
        textToSpeech?.shutdown()
        super.onDestroy()
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            textToSpeech?.language = Locale.US
            textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) = completeSpeech(null)
                @Deprecated("Deprecated by Android")
                override fun onError(utteranceId: String?) =
                    completeSpeech(FlutterSpeechError("Synthesis failed"))
            })
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceProfile" -> result.success(deviceProfile())
            "modelStatus" -> result.success(
                mapOf(
                    "modelId" to "hub-required",
                    "displayName" to "PlushBuddy Hub",
                    "ready" to false,
                    "installSupported" to false,
                    "installing" to false,
                    "parentConfigured" to false,
                    "ageBand" to null,
                    "characterAlias" to null,
                    "characterTraits" to emptyList<String>(),
                    "parentGuidance" to null,
                    "retentionDays" to null,
                ),
            )
            "installLocalModel" -> hubRequired(result)
            "cancelModelInstall" -> {
                result.success(null)
            }
            "configureParentPin",
            "authorizeParentPin",
            "deleteAllLocalData",
            "loadModel",
            "generateLocal",
            "history",
            "deleteHistory",
            "characters",
            "saveCharacter",
            "saveCharacterPhoto",
            "deleteCharacter",
            "enrollVoice",
            "previewVoice",
            "approveVoice",
            "deleteVoice",
            "speakWithVoice",
            "storeSecret",
            "deleteSecret",
            "reasoningProviderStatus",
            "saveProviderApiKey",
            "saveGeminiApiKey",
            "kids",
            "saveKid",
            "deleteKid" -> hubRequired(result)
            "cancelTurn" -> {
                result.success(null)
            }
            "endSession" -> {
                result.success(null)
            }
            "voiceStatus" -> result.success(
                mapOf(
                    "enrolled" to false,
                    "approved" to false,
                    "runtimeReady" to false,
                ),
            )
            "stationClientId" -> result.success(stationClientId())
            "stationClientLabel" -> result.success(stationClientLabel())
            "stationPairingStatus" -> stationPairingStatus(result)
            "saveStationPairing" -> saveStationPairing(call, result)
            "clearStationPairing" -> clearStationPairing(result)
            "pickVoiceSample" -> pickVoiceSample(result)
            "pickCharacterPhoto" -> pickCharacterPhoto(result)
            "ensureMicrophonePermission" -> ensureMicrophonePermission(result)
            "playWavBytes" -> playWavBytes(call, result)
            "listen" -> listen(result)
            "recordSpeechWav" -> recordSpeechWav(result)
            "speak" -> speak(call, result)
            "cancelSpeech" -> {
                speechRecognizer?.cancel()
                speechRecording.set(false)
                textToSpeech?.stop()
                wavPlayer?.stop()
                wavPlayer?.release()
                wavPlayer = null
                completeWav(null)
                completeSpeech(FlutterSpeechError("Speech cancelled"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hubRequired(result: MethodChannel.Result) {
        result.error(
            "hub_required",
            "Connect PlushBuddy Hub before using family, voice, AI, or conversation data.",
            null,
        )
    }

    private fun deviceProfile(): Map<String, Any> {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
        return mapOf(
            "platform" to "android",
            "memoryBytes" to memory.totalMem,
            "logicalProcessors" to Runtime.getRuntime().availableProcessors(),
        )
    }

    private fun writeEncryptedValue(key: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, vaultKey())
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val committed = getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE).edit()
            .putString(
                key,
                Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP),
            ).commit()
        if (!committed) throw IllegalStateException("Encrypted preference commit failed for $key")
    }

    private fun readEncryptedValue(key: String): String? {
        val encoded = getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
            .getString(key, null) ?: return null
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        require(combined.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            vaultKey(),
            javax.crypto.spec.GCMParameterSpec(128, combined.copyOfRange(0, 12)),
        )
        return String(
            cipher.doFinal(combined.copyOfRange(12, combined.size)),
            StandardCharsets.UTF_8,
        )
    }

    private fun purgeLegacyClientOwnedData() {
        getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE).edit()
            .remove("parent-pin-v1")
            .remove("parent-profile-v1")
            .remove("kids-v1")
            .remove("characters-v1")
            .remove("conversation-history-v1")
            .remove("reasoning-provider-v1")
            .remove("reasoning-api-key-gemini-v1")
            .remove("reasoning-api-key-openai-v1")
            .remove("gemini-api-key-v1")
            .commit()
    }

    private fun vaultKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(vaultAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                vaultAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun stationPairingStatus(result: MethodChannel.Result) {
        val config = runCatching {
            JSONObject(readEncryptedValue("station-pairing-v1") ?: "{}")
        }.getOrElse { JSONObject() }
        val baseUrl = config.optString("baseUrl").takeIf(String::isNotEmpty)
        val cookie = config.optString("cookie").takeIf(String::isNotEmpty)
        val clientId = config.optString("clientId").takeIf(String::isNotEmpty) ?: stationClientId()
        val hubId = config.optString("hubId").takeIf(String::isNotEmpty)
        val validHubId = hubId?.matches(Regex("^hub-[a-f0-9-]{36}$")) == true
        result.success(
            mapOf(
                "paired" to (baseUrl != null && cookie != null && validHubId),
                "baseUrl" to baseUrl,
                "cookie" to cookie,
                "clientId" to clientId,
                "hubId" to hubId,
            ),
        )
    }

    private fun saveStationPairing(call: MethodCall, result: MethodChannel.Result) {
        val baseUrl = call.argument<String>("baseUrl")?.trim().orEmpty().trimEnd('/')
        val cookie = call.argument<String>("cookie")?.trim().orEmpty()
        val clientId = call.argument<String>("clientId")?.trim().orEmpty().ifEmpty { stationClientId() }
        val hubId = call.argument<String>("hubId")?.trim().orEmpty()
        if (!saveStationPairingConfig(baseUrl, cookie, clientId, hubId)) {
            result.error("invalid_pairing", "Invalid Hub pairing data", null)
            return
        }
        result.success(null)
    }

    private fun saveStationPairingConfig(baseUrl: String, cookie: String, clientId: String, hubId: String): Boolean {
        if (!baseUrl.matches(Regex("^http://[^/]+:[0-9]+$")) ||
            !cookie.startsWith("pp_session=") ||
            cookie.length > 512 ||
            !clientId.matches(Regex("^android-[a-f0-9-]{36}$")) ||
            !hubId.matches(Regex("^hub-[a-f0-9-]{36}$"))
        ) {
            return false
        }
        val config = JSONObject()
            .put("baseUrl", baseUrl)
            .put("cookie", cookie)
            .put("clientId", clientId)
            .put("hubId", hubId)
        writeEncryptedValue("station-pairing-v1", config.toString())
        return true
    }

    private fun stationClientId(): String {
        readEncryptedValue("station-client-id-v1")?.let { existing ->
            if (existing.matches(Regex("^android-[a-f0-9-]{36}$"))) return existing
        }
        val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() && it != "9774d56d682e549c" }
        val generated = if (androidId != null) {
            val stable = UUID.nameUUIDFromBytes(
                "plushbuddy:android:$androidId".toByteArray(StandardCharsets.UTF_8),
            )
            "android-$stable"
        } else {
            "android-${UUID.randomUUID()}"
        }
        writeEncryptedValue("station-client-id-v1", generated)
        return generated
    }

    private fun stationClientLabel(): String {
        val manufacturer = Build.MANUFACTURER
            .orEmpty()
            .trim()
            .replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.US) else it.toString() }
        val model = Build.MODEL.orEmpty().trim()
        val label = when {
            manufacturer.isEmpty() && model.isEmpty() -> "Android phone"
            manufacturer.isEmpty() -> model
            model.isEmpty() -> "$manufacturer Android"
            model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> "$manufacturer $model"
        }
        return label.take(80)
    }

    private fun handleDebugSavePairingIntent(intent: Intent?) {
        val debugBuild = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debugBuild || intent?.action != debugSavePairingAction) return
        val baseUrl = intent.getStringExtra("baseUrl")?.trim().orEmpty().trimEnd('/')
        val cookie = intent.getStringExtra("cookie")?.trim().orEmpty()
        val clientId = intent.getStringExtra("clientId")?.trim()
            ?.takeIf { it.matches(Regex("^android-[a-f0-9-]{36}$")) }
            ?: stationClientId()
        val hubId = intent.getStringExtra("hubId")?.trim().orEmpty()
        if (saveStationPairingConfig(baseUrl, cookie, clientId, hubId)) {
            Log.i(logTag, "Debug Hub pairing saved for $baseUrl")
        } else {
            Log.w(logTag, "Debug Hub pairing rejected")
        }
    }

    private fun clearStationPairing(result: MethodChannel.Result) {
        getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
            .edit().remove("station-pairing-v1").commit()
        result.success(null)
    }

    private fun pickVoiceSample(result: MethodChannel.Result) {
        if (pendingAudioPickResult != null) {
            result.error("audio_pick_busy", "Audio picker is already open", null)
            return
        }
        pendingAudioPickResult = result
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "audio/*",
                    "audio/m4a",
                    "audio/mp4",
                    "audio/aac",
                    "audio/mpeg",
                    "audio/wav",
                    "audio/x-wav",
                    "audio/ogg",
                    "audio/webm",
                ),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching {
            startActivityForResult(
                Intent.createChooser(intent, "Choose voice sample"),
                pickVoiceSampleRequestCode,
            )
        }
            .onFailure {
                pendingAudioPickResult = null
                result.error("audio_picker_unavailable", "No audio picker is available", null)
            }
    }

    private fun pickCharacterPhoto(result: MethodChannel.Result) {
        if (pendingImagePickResult != null) {
            result.error("image_pick_busy", "Image picker is already open", null)
            return
        }
        pendingImagePickResult = result
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("image/*", "image/jpeg", "image/png", "image/webp"),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching {
            startActivityForResult(
                Intent.createChooser(intent, "Choose character photo"),
                pickCharacterPhotoRequestCode,
            )
        }
            .onFailure {
                pendingImagePickResult = null
                result.error("image_picker_unavailable", "No image picker is available", null)
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickVoiceSampleRequestCode) {
            finishFilePick(
                pendingAudioPickResult,
                resultCode,
                data,
                maxBytes = 32 * 1024 * 1024,
                defaultMime = "audio/m4a",
                invalidCode = "invalid_audio",
                invalidMessage = "Choose an audio file up to 32 MB",
                cancelledCode = "audio_pick_cancelled",
                cancelledMessage = "No audio sample selected",
            )
            pendingAudioPickResult = null
            return
        }
        if (requestCode == pickCharacterPhotoRequestCode) {
            finishImagePick(
                pendingImagePickResult,
                resultCode,
                data,
            )
            pendingImagePickResult = null
            return
        }
    }

    private fun finishImagePick(
        pending: MethodChannel.Result?,
        resultCode: Int,
        data: Intent?,
    ) {
        if (pending == null) return
        if (resultCode != RESULT_OK || data?.data == null) {
            pending.error("image_pick_cancelled", "No character photo selected", null)
            return
        }
        val uri = data.data!!
        val bytes = runCatching {
            contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes()
            }
        }.getOrNull()
        val normalized = normalizePhotoForStorage(bytes)
        if (normalized == null) {
            pending.error("invalid_photo", "Could not read this image. Try a different photo.", null)
            return
        }
        pending.success(
            mapOf(
                "bytes" to normalized,
                "filename" to displayName(uri),
                "mime" to "image/jpeg",
            ),
        )
    }

    private fun finishFilePick(
        pending: MethodChannel.Result?,
        resultCode: Int,
        data: Intent?,
        maxBytes: Int,
        defaultMime: String,
        invalidCode: String,
        invalidMessage: String,
        cancelledCode: String,
        cancelledMessage: String,
    ) {
        if (pending == null) return
        if (resultCode != RESULT_OK || data?.data == null) {
            pending.error(cancelledCode, cancelledMessage, null)
            return
        }
        val uri = data.data!!
        val bytes = runCatching {
            contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes()
            }
        }.getOrNull()
        if (bytes == null || bytes.isEmpty() || bytes.size > maxBytes) {
            pending.error(invalidCode, invalidMessage, null)
            return
        }
        pending.success(
            mapOf(
                "bytes" to bytes,
                "filename" to displayName(uri),
                "mime" to (contentResolver.getType(uri) ?: defaultMime),
            ),
        )
    }

    private fun normalizePhotoForStorage(bytes: ByteArray?): ByteArray? {
        if (bytes == null || bytes.isEmpty()) return null
        return runCatching {
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            val width = options.outWidth
            val height = options.outHeight
            if (width <= 0 || height <= 0) return null
            val maxDimension = 1024
            var sampleSize = 1
            while ((width / sampleSize) > maxDimension * 2 ||
                (height / sampleSize) > maxDimension * 2
            ) {
                sampleSize *= 2
            }
            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
            }
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions)
                ?: return null
            val longest = maxOf(decoded.width, decoded.height)
            val outputBitmap = if (longest > maxDimension) {
                val scale = maxDimension.toFloat() / longest.toFloat()
                Bitmap.createScaledBitmap(
                    decoded,
                    (decoded.width * scale).toInt().coerceAtLeast(1),
                    (decoded.height * scale).toInt().coerceAtLeast(1),
                    true,
                ).also {
                    if (it !== decoded) decoded.recycle()
                }
            } else {
                decoded
            }
            val output = ByteArrayOutputStream()
            outputBitmap.compress(Bitmap.CompressFormat.JPEG, 86, output)
            outputBitmap.recycle()
            output.toByteArray().takeIf { it.isNotEmpty() }
        }.getOrNull()
    }

    private fun displayName(uri: android.net.Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                return cursor.getString(index)
            }
        }
        return "voice-sample.m4a"
    }

    private fun playWavBytes(call: MethodCall, result: MethodChannel.Result) {
        val wavBytes = call.argument<ByteArray>("wavBytes")
        if (wavBytes == null || wavBytes.isEmpty() || wavBytes.size > 20 * 1024 * 1024) {
            result.error("invalid_audio", "WAV audio is invalid", null)
            return
        }
        if (pendingWavResult != null) {
            result.error("audio_busy", "Voice playback is already active", null)
            return
        }
        pendingWavResult = result
        val file = java.io.File(cacheDir, "plushpal-voice-${UUID.randomUUID()}.wav")
        try {
            file.writeBytes(wavBytes)
            wavPlayer?.release()
            wavPlayer = MediaPlayer().also { player ->
                player.setDataSource(file.absolutePath)
                player.setOnCompletionListener {
                    it.release()
                    if (wavPlayer === it) wavPlayer = null
                    file.delete()
                    completeWav(null)
                }
                player.setOnErrorListener { errored, _, _ ->
                    errored.release()
                    if (wavPlayer === errored) wavPlayer = null
                    file.delete()
                    completeWav(FlutterSpeechError("Voice playback failed"))
                    true
                }
                player.prepare()
                player.start()
            }
        } catch (_: Exception) {
            file.delete()
            wavPlayer?.release()
            wavPlayer = null
            completeWav(FlutterSpeechError("Voice playback failed"))
        }
    }

    private fun completeWav(error: FlutterSpeechError?) {
        val pending = pendingWavResult ?: return
        pendingWavResult = null
        runOnUiThread {
            if (error == null) pending.success(null)
            else pending.error("audio_error", error.message, null)
        }
    }

    private fun ensureMicrophonePermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingMicrophonePermissionResult != null) {
            result.error("permission_busy", "Microphone permission request is already open", null)
            return
        }
        pendingMicrophonePermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 901)
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 901) return
        val pending = pendingMicrophonePermissionResult ?: return
        pendingMicrophonePermissionResult = null
        pending.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    private fun listen(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("microphone_permission", "Microphone permission is required", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            result.error(
                "speech_on_device_unavailable",
                "On-device speech recognition is unavailable on this phone. Type a message or use a phone with offline speech recognition.",
                null,
            )
            return
        }
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        speechRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this).also { recognizer ->
            val completed = AtomicBoolean(false)
            var latestPartialTranscript = ""
            fun bestTranscript(bundle: Bundle?): String =
                bundle
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    .orEmpty()
                    .trim()

            fun finishWithTranscript(transcript: String) {
                if (!completed.compareAndSet(false, true)) return
                result.success(transcript.trim())
                recognizer.destroy()
                speechRecognizer = null
            }

            fun finishWithError(error: Int) {
                if (!completed.compareAndSet(false, true)) return
                val message = speechRecognizerMessage(error)
                Log.w(logTag, "Speech recognition failed: $message ($error)")
                result.error("speech_error", message, error)
                recognizer.destroy()
                speechRecognizer = null
            }

            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onResults(bundle: Bundle) {
                    val transcript = bestTranscript(bundle)
                    if (transcript.isNotEmpty()) {
                        finishWithTranscript(transcript)
                    } else if (latestPartialTranscript.isNotEmpty()) {
                        finishWithTranscript(latestPartialTranscript)
                    } else {
                        finishWithError(SpeechRecognizer.ERROR_NO_MATCH)
                    }
                }
                override fun onError(error: Int) {
                    if (latestPartialTranscript.isNotEmpty()) {
                        finishWithTranscript(latestPartialTranscript)
                    } else {
                        finishWithError(error)
                    }
                }
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onPartialResults(partialResults: Bundle?) {
                    latestPartialTranscript = bestTranscript(partialResults)
                }
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            })
            recognizer.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.US.toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 6_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 6_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 3_500L)
                putExtra(RecognizerIntent.EXTRA_PROMPT, "Talk to PlushBuddy")
            })
        }
    }

    private fun recordSpeechWav(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("microphone_permission", "Microphone permission is required", null)
            return
        }
        if (!speechRecording.compareAndSet(false, true)) {
            result.error("speech_busy", "Speech recording is already active", null)
            return
        }
        Thread {
            val sampleRate = 16_000
            val channelConfig = AudioFormat.CHANNEL_IN_MONO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            if (minBuffer <= 0) {
                speechRecording.set(false)
                runOnUiThread {
                    result.error("speech_recording_unavailable", "Microphone recording is unavailable", null)
                }
                return@Thread
            }
            val bufferSize = maxOf(minBuffer, sampleRate / 2)
            val recorder = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize,
            )
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                speechRecording.set(false)
                runOnUiThread {
                    result.error("speech_recording_unavailable", "Microphone recording is unavailable", null)
                }
                return@Thread
            }
            val pcm = ByteArrayOutputStream()
            val samples = ShortArray(bufferSize / 2)
            val startedAt = System.currentTimeMillis()
            var voiceStarted = false
            var lastVoiceAt = startedAt
            try {
                recorder.startRecording()
                while (speechRecording.get()) {
                    val read = recorder.read(samples, 0, samples.size)
                    if (read <= 0) continue
                    var peak = 0
                    for (i in 0 until read) {
                        val sample = samples[i].toInt()
                        peak = maxOf(peak, abs(sample))
                        pcm.write(sample and 0xff)
                        pcm.write((sample shr 8) and 0xff)
                    }
                    val now = System.currentTimeMillis()
                    if (peak > 900) {
                        voiceStarted = true
                        lastVoiceAt = now
                    }
                    val elapsed = now - startedAt
                    if (elapsed >= 10_000L) break
                    if (voiceStarted && elapsed >= 1_200L && now - lastVoiceAt >= 1_800L) break
                    if (!voiceStarted && elapsed >= 5_000L) break
                }
                val wav = wavFromPcm(pcm.toByteArray(), sampleRate)
                speechRecording.set(false)
                runOnUiThread {
                    if (wav.size <= 44) {
                        result.error("speech_no_audio", "I did not hear speech yet. Try again after the beep.", null)
                    } else {
                        result.success(wav)
                    }
                }
            } catch (error: Exception) {
                speechRecording.set(false)
                runOnUiThread {
                    result.error("speech_recording_failed", "Microphone recording failed", null)
                }
            } finally {
                try {
                    recorder.stop()
                } catch (_: Exception) {
                }
                recorder.release()
            }
        }.start()
    }

    private fun wavFromPcm(pcm: ByteArray, sampleRate: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val dataSize = pcm.size
        val byteRate = sampleRate * 2
        fun writeAscii(value: String) {
            output.write(value.toByteArray(StandardCharsets.US_ASCII))
        }
        fun writeIntLe(value: Int) {
            output.write(value and 0xff)
            output.write((value shr 8) and 0xff)
            output.write((value shr 16) and 0xff)
            output.write((value shr 24) and 0xff)
        }
        fun writeShortLe(value: Int) {
            output.write(value and 0xff)
            output.write((value shr 8) and 0xff)
        }
        writeAscii("RIFF")
        writeIntLe(36 + dataSize)
        writeAscii("WAVE")
        writeAscii("fmt ")
        writeIntLe(16)
        writeShortLe(1)
        writeShortLe(1)
        writeIntLe(sampleRate)
        writeIntLe(byteRate)
        writeShortLe(2)
        writeShortLe(16)
        writeAscii("data")
        writeIntLe(dataSize)
        output.write(pcm)
        return output.toByteArray()
    }

    private fun speechRecognizerMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "The microphone had trouble recording. Please try again."
        SpeechRecognizer.ERROR_CLIENT -> "Speech listening stopped. Please tap the mic and try again."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "Microphone permission is required. Please enable it in Android settings."
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
            "Offline speech recognition is not ready on this phone. Try typing, or install the phone's offline speech language pack."
        SpeechRecognizer.ERROR_NO_MATCH ->
            "I heard you, but could not turn it into words. Try speaking a little closer to the phone."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
            "The microphone is still warming up. Please wait a second and try again."
        SpeechRecognizer.ERROR_SERVER ->
            "Offline speech recognition is having trouble right now. Try typing or try again."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
            "I did not hear speech yet. Try again and start talking after the beep."
        else -> "I did not catch that yet. Try again, or type a message."
    }

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text").orEmpty()
        if (text.isEmpty() || text.length > 2_000) {
            result.error("invalid_speech", "Speech text is invalid", null)
            return
        }
        if (pendingSpeechResult != null) {
            result.error("speech_busy", "Speech is already active", null)
            return
        }
        pendingSpeechResult = result
        val status = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "plushpal-turn")
        if (status == TextToSpeech.ERROR) {
            completeSpeech(FlutterSpeechError("Synthesis failed"))
        }
    }

    private data class FlutterSpeechError(val message: String)

    private fun completeSpeech(error: FlutterSpeechError?) {
        val pending = pendingSpeechResult ?: return
        pendingSpeechResult = null
        runOnUiThread {
            if (error == null) pending.success(null)
            else pending.error("speech_error", error.message, null)
        }
    }
}
