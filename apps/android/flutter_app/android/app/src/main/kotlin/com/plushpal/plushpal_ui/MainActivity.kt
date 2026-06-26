package com.plushpal.app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.StatFs
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
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaPlayer
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, TextToSpeech.OnInitListener {
    companion object {
        private const val logTag = "PlushPal"
        private const val debugSavePairingAction = "com.plushpal.app.DEBUG_SAVE_PAIRING"
        private const val pickVoiceSampleRequestCode = 7104
        private const val pickCharacterPhotoRequestCode = 7105
        private val nativeCoreAvailable = try {
            System.loadLibrary("plushpal_mobile_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    private val channelName = "com.plushpal/platform"
    private val vaultAlias = "com.plushpal.hardware-vault.v1"
    private val vaultPreferences = "plushpal_opaque_secrets"
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var nativeEngine: Long = 0
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingWavResult: MethodChannel.Result? = null
    private var pendingAudioPickResult: MethodChannel.Result? = null
    private var pendingImagePickResult: MethodChannel.Result? = null
    private var pendingMicrophonePermissionResult: MethodChannel.Result? = null
    private var wavPlayer: MediaPlayer? = null
    private val modelInstalling = AtomicBoolean(false)
    private val geminiContextLock = Any()
    private val geminiContext = ArrayList<ConversationContextTurn>()
    private var geminiContextScope: String? = null
    private var parentPinFailures = 0
    private var parentPinLockedUntil = 0L

    private data class ConversationContextTurn(
        val childText: String,
        val characterText: String,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleDebugSavePairingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDebugSavePairingIntent(intent)
    }

    private external fun nativeCreateEngine(modelPath: String): Long
    private external fun nativeGenerateLocal(
        engine: Long,
        ageBand: Int,
        characterAlias: String,
        text: String,
        parentGuidance: String,
    ): Array<Any>?
    private external fun nativeCancel(engine: Long): Boolean
    private external fun nativeClearSession(engine: Long): Boolean
    private external fun nativeInstallBundledModel(destinationDirectory: String): Int
    private external fun nativeVerifyBundledModel(modelPath: String): Boolean
    private external fun nativeCancelModelInstall()
    private external fun nativeDestroy(engine: Long)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(this)
        textToSpeech = TextToSpeech(this, this)
        if (nativeCoreAvailable) {
            val installed = java.io.File(filesDir, "models/qwen3-1.7b-q8-1.gguf")
            if (installed.isFile && nativeVerifyBundledModel(installed.absolutePath)) {
                nativeEngine = nativeCreateEngine(installed.absolutePath)
            }
        }
    }

    override fun onDestroy() {
        if (nativeCoreAvailable && nativeEngine != 0L) nativeDestroy(nativeEngine)
        nativeEngine = 0
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
                    "modelId" to if (reasoningApiKey() != null) "${reasoningProvider()}-cloud" else "qwen3-local",
                    "displayName" to if (reasoningApiKey() != null) "${reasoningProviderDisplayName()} cloud reasoning" else "Qwen3 local conversation model",
                    "ready" to (reasoningApiKey() != null || (nativeCoreAvailable && nativeEngine != 0L)),
                    "installSupported" to nativeCoreAvailable,
                    "installing" to modelInstalling.get(),
                    "parentConfigured" to getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
                        .contains("parent-pin-v1"),
                    "ageBand" to readParentProfile().optString("ageBand").takeIf(String::isNotEmpty),
                    "characterAlias" to readParentProfile().optString("characterAlias").takeIf(String::isNotEmpty),
                    "characterTraits" to readParentProfile().optJSONArray("characterTraits")
                        .toStringList(),
                    "parentGuidance" to readParentProfile().optString("parentGuidance")
                        .takeIf(String::isNotEmpty),
                    "retentionDays" to readParentProfile().optInt("retentionDays").takeIf { it > 0 },
                ),
            )
            "installLocalModel" -> installLocalModel(result)
            "cancelModelInstall" -> {
                if (nativeCoreAvailable) nativeCancelModelInstall()
                result.success(null)
            }
            "configureParentPin" -> configureParentPin(call, result)
            "authorizeParentPin" -> authorizeParentPin(call, result)
            "deleteAllLocalData" -> deleteAllLocalData(call, result)
            "loadModel" -> loadModel(call, result)
            "generateLocal" -> generateLocal(call, result)
            "cancelTurn" -> {
                if (nativeCoreAvailable && nativeEngine != 0L) nativeCancel(nativeEngine)
                result.success(null)
            }
            "endSession" -> {
                if (nativeCoreAvailable && nativeEngine != 0L) nativeClearSession(nativeEngine)
                clearGeminiContext()
                if (retentionDays() == 0) writeHistory(JSONArray())
                result.success(null)
            }
            "history" -> history(call, result)
            "deleteHistory" -> deleteHistory(call, result)
            "characters" -> characters(result)
            "saveCharacter" -> saveCharacter(call, result)
            "saveCharacterPhoto" -> saveCharacterPhoto(call, result)
            "deleteCharacter" -> deleteCharacter(call, result)
            "voiceStatus" -> result.success(
                mapOf(
                    "enrolled" to false,
                    "approved" to false,
                    "runtimeReady" to false,
                ),
            )
            "enrollVoice", "previewVoice", "approveVoice", "deleteVoice", "speakWithVoice" ->
                result.error("voice_unavailable", "Local cloned voice is not installed on Android yet", null)
            "storeSecret" -> storeSecret(call, result)
            "deleteSecret" -> deleteSecret(call, result)
            "reasoningProviderStatus" -> reasoningProviderStatus(result)
            "saveProviderApiKey" -> saveProviderApiKey(call, result)
            "saveGeminiApiKey" -> saveGeminiApiKey(call, result)
            "kids" -> kids(result)
            "saveKid" -> saveKid(call, result)
            "deleteKid" -> deleteKid(call, result)
            "stationPairingStatus" -> stationPairingStatus(result)
            "saveStationPairing" -> saveStationPairing(call, result)
            "clearStationPairing" -> clearStationPairing(result)
            "pickVoiceSample" -> pickVoiceSample(result)
            "pickCharacterPhoto" -> pickCharacterPhoto(result)
            "ensureMicrophonePermission" -> ensureMicrophonePermission(result)
            "playWavBytes" -> playWavBytes(call, result)
            "listen" -> listen(result)
            "speak" -> speak(call, result)
            "cancelSpeech" -> {
                speechRecognizer?.cancel()
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

    private fun loadModel(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        val model = runCatching { java.io.File(path).canonicalFile }.getOrNull()
        val root = filesDir.canonicalFile
        if (!nativeCoreAvailable || model == null ||
            model.parentFile != root && !model.toPath().startsWith(root.toPath()) ||
            !nativeVerifyBundledModel(model.absolutePath)
        ) {
            result.error("model_unavailable", "Verified local model is unavailable", null)
            return
        }
        if (nativeEngine != 0L) nativeDestroy(nativeEngine)
        nativeEngine = nativeCreateEngine(path)
        if (nativeEngine == 0L) {
            result.error("model_unavailable", "Unable to load local model", null)
        } else {
            result.success(null)
        }
    }

    private fun installLocalModel(result: MethodChannel.Result) {
        if (!nativeCoreAvailable) {
            result.error("model_unavailable", "Native model installer is unavailable", null)
            return
        }
        if (!modelInstalling.compareAndSet(false, true)) {
            result.error("install_in_progress", "Model installation is already active", null)
            return
        }
        val directory = java.io.File(filesDir, "models").apply { mkdirs() }
        val partial = java.io.File(directory, "qwen3-1.7b-q8-1.partial")
        val remaining = (1_834_426_016L - partial.length()).coerceAtLeast(0L)
        val available = StatFs(directory.absolutePath).availableBytes
        if (available < remaining + 512L * 1024L * 1024L) {
            modelInstalling.set(false)
            result.error("insufficient_storage", "At least 512 MB of free space beyond the model download is required", null)
            return
        }
        Thread {
            val status = nativeInstallBundledModel(directory.absolutePath)
            var engine = 0L
            if (status == 0) {
                engine = nativeCreateEngine(
                    java.io.File(directory, "qwen3-1.7b-q8-1.gguf").absolutePath,
                )
            }
            modelInstalling.set(false)
            runOnUiThread {
                if (status != 0 || engine == 0L) {
                    result.error("model_install_failed", "Model installation failed", status)
                } else {
                    if (nativeEngine != 0L) nativeDestroy(nativeEngine)
                    nativeEngine = engine
                    result.success(null)
                }
            }
        }.start()
    }

    private fun generateLocal(call: MethodCall, result: MethodChannel.Result) {
        val requestedAge = call.argument<String>("ageBand")
        val age = when (requestedAge) {
            "4-5" -> 0
            "6-8" -> 1
            "9-12" -> 2
            else -> -1
        }
        val alias = call.argument<String>("characterAlias").orEmpty()
        val text = call.argument<String>("text").orEmpty()
        val kidId = call.argument<String>("kidId").orEmpty()
        val kidName = call.argument<String>("kidName").orEmpty()
        val childAgeYears = call.argument<Int>("childAgeYears")
        val childAgeMonths = call.argument<Int>("childAgeMonths")
        val requestedCharacterPlayAgeYears = call.argument<Int>("characterPlayAgeYears")
        val profile = readParentProfile()
        val knownCharacter = characterExists(alias, kidId.ifBlank { null })
        if (profile.length() == 0 || !knownCharacter) {
            android.util.Log.w(
                "PlushPal",
                "generateLocal invalid profile requestedAge=$requestedAge alias=$alias kidId=$kidId",
            )
            result.error("invalid_turn", "Parent profile does not match this turn", null)
            return
        }
        val characterProfile = readCharacter(alias, kidId.ifBlank { null })
        val guidance = buildString {
            val traits = characterProfile?.optJSONArray("traits").toStringList()
                .ifEmpty { profile.optJSONArray("characterTraits").toStringList() }
            if (traits.isNotEmpty()) append("Personality traits: ${traits.joinToString(", ")}.")
            val parent = characterProfile?.optString("parentGuidance")?.takeIf { it.isNotBlank() }
                ?: profile.optString("parentGuidance")
            if (parent.isNotEmpty()) {
                if (isNotEmpty()) append('\n')
                append("Parent guidance: $parent")
            }
        }
        if (age < 0 || alias.isEmpty() || text.isEmpty()) {
            result.error("invalid_turn", "Local model is not ready", null)
            return
        }
        val provider = reasoningProvider()
        val apiKey = reasoningApiKey()
        val kidPseudonym = kidPseudonym(kidId, kidName)
        val ageContext = childAgeContext(requestedAge.orEmpty(), kidPseudonym, childAgeYears)
        val characterPlayAgeYears = characterPlayAgeYears(
            childAgeYears,
            requestedCharacterPlayAgeYears ?: characterProfile?.optInt("personaAgeYears")?.takeIf { it > 0 },
        )
        val scopeKidId = kidId.ifBlank { "legacy" }
        if (apiKey != null) {
            val cloudText = redactForCloud(text, kidName, kidPseudonym)
            val cloudGuidance = redactForCloud(guidance, kidName, kidPseudonym)
            val recentTurns = recentGeminiContext(scopeKidId, alias).map {
                ConversationContextTurn(
                    redactForCloud(it.childText, kidName, kidPseudonym),
                    redactForCloud(it.characterText, kidName, kidPseudonym),
                )
            }
            Thread {
                val generated = when (provider) {
                    "openai" -> generateWithOpenAi(apiKey, ageContext, alias, cloudText, cloudGuidance, recentTurns, characterPlayAgeYears)
                    else -> generateWithGemini(apiKey, ageContext, alias, cloudText, cloudGuidance, recentTurns, characterPlayAgeYears)
                }
                runOnUiThread {
                    if (generated == null) {
                        android.util.Log.w("PlushPal", "$provider generation failed for alias=$alias age=$requestedAge")
                        result.error(
                            "generation_failed",
                            "${reasoningProviderDisplayName()} could not answer. Re-save the API key, check internet access, and try again.",
                            null,
                        )
                    } else {
                        android.util.Log.i("PlushPal", "$provider generation succeeded for alias=$alias")
                        val localSpeech = restoreFromCloud(generated.first, kidName, kidPseudonym)
                        appendGeminiContext(scopeKidId, alias, text, localSpeech)
                        retainTurn(text, localSpeech, scopeKidId, alias)
                        result.success(
                            mapOf(
                                "speech" to localSpeech,
                                "suggestTrustedAdult" to generated.second,
                            ),
                        )
                    }
                }
            }.start()
            return
        }
        if (!nativeCoreAvailable || nativeEngine == 0L) {
            android.util.Log.w("PlushPal", "generateLocal no reasoning provider ready")
            result.error("invalid_turn", "Configure Gemini or install a local model first", null)
            return
        }
        Thread {
            val generated = nativeGenerateLocal(nativeEngine, age, alias, text, guidance)
            runOnUiThread {
                if (generated == null || generated.size != 2) {
                    result.error("generation_failed", "Local generation failed", null)
                } else {
                    retainTurn(text, generated[0] as String, scopeKidId, alias)
                    result.success(
                        mapOf(
                            "speech" to generated[0] as String,
                            "suggestTrustedAdult" to generated[1] as Boolean,
                        ),
                    )
                }
            }
        }.start()
    }

    private fun saveGeminiApiKey(call: MethodCall, result: MethodChannel.Result) {
        saveProviderApiKey(call, result, forcedProvider = "gemini")
    }

    private fun saveProviderApiKey(
        call: MethodCall,
        result: MethodChannel.Result,
        forcedProvider: String? = null,
    ) {
        val provider = (forcedProvider ?: call.argument<String>("provider") ?: "gemini")
            .trim()
            .lowercase(Locale.US)
        val apiKey = call.argument<String>("apiKey")?.trim().orEmpty()
        if (provider !in setOf("gemini", "openai")) {
            result.error("invalid_provider", "Choose Gemini or OpenAI", null)
            return
        }
        val keyLooksValid = when (provider) {
            "openai" -> apiKey.startsWith("sk-") && apiKey.length >= 30
            else -> apiKey.length >= 20
        }
        if (!keyLooksValid || apiKey.any { it.isISOControl() }) {
            result.error("invalid_api_key", "${providerDisplayName(provider)} API key looks invalid", null)
            return
        }
        try {
            writeEncryptedValue("reasoning-provider-v1", provider)
            writeEncryptedValue("reasoning-api-key-$provider-v1", apiKey)
            if (provider == "gemini") writeEncryptedValue("gemini-api-key-v1", apiKey)
            result.success(null)
        } catch (_: Exception) {
            result.error("vault_failure", "Unable to store API key", null)
        }
    }

    private fun geminiApiKey(): String? =
        readEncryptedValue("gemini-api-key-v1")?.trim()?.takeIf { it.isNotEmpty() }

    private fun reasoningProvider(): String =
        readEncryptedValue("reasoning-provider-v1")?.trim()?.lowercase(Locale.US)
            ?.takeIf { it in setOf("gemini", "openai") }
            ?: if (geminiApiKey() != null) "gemini" else "gemini"

    private fun providerDisplayName(provider: String): String =
        when (provider) {
            "openai" -> "OpenAI"
            else -> "Gemini"
        }

    private fun reasoningProviderDisplayName(): String = providerDisplayName(reasoningProvider())

    private fun reasoningApiKey(): String? {
        val provider = reasoningProvider()
        return readEncryptedValue("reasoning-api-key-$provider-v1")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: if (provider == "gemini") geminiApiKey() else null
    }

    private fun reasoningProviderStatus(result: MethodChannel.Result) {
        val provider = reasoningProvider()
        result.success(
            mapOf(
                "provider" to provider,
                "configured" to (reasoningApiKey() != null),
                "displayName" to providerDisplayName(provider),
            ),
        )
    }

    private fun generateWithGemini(
        apiKey: String,
        ageContext: String,
        alias: String,
        text: String,
        guidance: String,
        recentTurns: List<ConversationContextTurn>,
        characterPlayAgeYears: Int,
    ): Pair<String, Boolean>? = runCatching {
        val prompt = buildReasoningPrompt(ageContext, alias, text, guidance, recentTurns, characterPlayAgeYears)
        val body = JSONObject()
            .put(
                "contents",
                JSONArray().put(
                    JSONObject()
                        .put("role", "user")
                        .put(
                            "parts",
                            JSONArray().put(JSONObject().put("text", prompt)),
                        ),
                ),
            )
            .put(
                "generationConfig",
                JSONObject()
                    .put("temperature", 0.7)
                    .put("topP", 0.9)
                    .put("maxOutputTokens", 320)
                    .put("responseMimeType", "application/json")
                    .put(
                        "thinkingConfig",
                        JSONObject().put("thinkingBudget", 0),
                    ),
            )
        val connection = (URL("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
            .openConnection() as HttpURLConnection)
        connection.requestMethod = "POST"
        connection.connectTimeout = 15_000
        connection.readTimeout = 45_000
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("x-goog-api-key", apiKey)
        connection.outputStream.use { it.write(body.toString().toByteArray(StandardCharsets.UTF_8)) }
        val responseText = if (connection.responseCode in 200..299) {
            connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
        } else {
            val errorText = connection.errorStream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }
            android.util.Log.w(
                "PlushPal",
                "Gemini HTTP ${connection.responseCode}: ${errorText?.take(500)}",
            )
            return@runCatching null
        }
        parseGeminiResponse(responseText).also {
            if (it == null) {
                android.util.Log.w("PlushPal", "Gemini response parse failed: ${responseText.take(500)}")
            }
        }
    }.getOrNull()

    private fun generateWithOpenAi(
        apiKey: String,
        ageContext: String,
        alias: String,
        text: String,
        guidance: String,
        recentTurns: List<ConversationContextTurn>,
        characterPlayAgeYears: Int,
    ): Pair<String, Boolean>? = runCatching {
        val prompt = buildReasoningPrompt(ageContext, alias, text, guidance, recentTurns, characterPlayAgeYears)
        val body = JSONObject()
            .put("model", "gpt-4.1-mini")
            .put(
                "messages",
                JSONArray().put(
                    JSONObject()
                        .put("role", "user")
                        .put("content", prompt),
                ),
            )
            .put("temperature", 0.7)
            .put("max_tokens", 320)
            .put("response_format", JSONObject().put("type", "json_object"))
        val connection = (URL("https://api.openai.com/v1/chat/completions")
            .openConnection() as HttpURLConnection)
        connection.requestMethod = "POST"
        connection.connectTimeout = 15_000
        connection.readTimeout = 45_000
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("Authorization", "Bearer $apiKey")
        connection.outputStream.use { it.write(body.toString().toByteArray(StandardCharsets.UTF_8)) }
        val responseText = if (connection.responseCode in 200..299) {
            connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
        } else {
            val errorText = connection.errorStream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }
            android.util.Log.w(
                "PlushPal",
                "OpenAI HTTP ${connection.responseCode}: ${errorText?.take(500)}",
            )
            return@runCatching null
        }
        val envelope = JSONObject(responseText)
        val content = envelope
            .optJSONArray("choices")
            ?.optJSONObject(0)
            ?.optJSONObject("message")
            ?.optString("content")
            ?.trim()
            .orEmpty()
        val jsonText = extractJsonObject(content) ?: return@runCatching null
        val structured = JSONObject(jsonText)
        val speech = structured.optString("speech").trim()
        if (speech.isEmpty() || speech.length > 600) null
        else speech to structured.optBoolean("suggest_trusted_adult", false)
    }.getOrNull()

    private fun childAgeContext(
        ageBand: String,
        kidName: String,
        childAgeYears: Int?,
    ): String {
        val name = kidName.trim().takeIf { it.isNotEmpty() } ?: "the child"
        return if (childAgeYears != null) {
            "$name is $childAgeYears years old."
        } else {
            "$name is in age band $ageBand."
        }
    }

    private fun characterPlayAgeYears(
        childAgeYears: Int?,
        requestedCharacterPlayAgeYears: Int?,
    ): Int {
        val childCap = childAgeYears?.coerceAtLeast(2) ?: 2
        val requested = requestedCharacterPlayAgeYears ?: childCap
        return requested.coerceIn(2, childCap)
    }

    private fun kidPseudonym(kidId: String, kidName: String): String {
        val names = listOf("Sunny", "Momo", "Kiki", "Bunny", "Pip", "Nori", "Lulu", "Toto")
        val key = (kidId.ifBlank { kidName.ifBlank { "kid" } })
        val index = kotlin.math.abs(key.hashCode()).rem(names.size)
        return names[index]
    }

    private fun redactForCloud(input: String, kidName: String, pseudonym: String): String {
        var output = input
        val trimmedKidName = kidName.trim()
        if (trimmedKidName.length >= 2) {
            output = output.replace(Regex("\\b${Regex.escape(trimmedKidName)}\\b", RegexOption.IGNORE_CASE), pseudonym)
        }
        output = output
            .replace(Regex("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", RegexOption.IGNORE_CASE), "[redacted email]")
            .replace(Regex("\\b(?:https?://|www\\.)\\S+", RegexOption.IGNORE_CASE), "[redacted link]")
            .replace(Regex("\\b(?:\\+?1[-.\\s]?)?(?:\\(?\\d{3}\\)?[-.\\s]?){2}\\d{4}\\b"), "[redacted phone]")
            .replace(Regex("\\b\\d{1,6}\\s+[A-Za-z0-9.'-]+\\s+(?:Street|St|Road|Rd|Avenue|Ave|Drive|Dr|Lane|Ln|Court|Ct|Boulevard|Blvd|Way|Circle|Cir)\\b", RegexOption.IGNORE_CASE), "[redacted address]")
            .replace(Regex("\\b(my name is|i am|i'm)\\s+[A-Z][a-z]{1,30}\\b", RegexOption.IGNORE_CASE), "$1 $pseudonym")
            .replace(Regex("\\b(my school is|i go to)\\s+[^.!?\\n]{2,80}", RegexOption.IGNORE_CASE), "$1 [redacted school]")
            .replace(Regex("\\b(i live at|my address is|we live at)\\s+[^.!?\\n]{2,120}", RegexOption.IGNORE_CASE), "$1 [redacted address]")
        return output
    }

    private fun restoreFromCloud(input: String, kidName: String, pseudonym: String): String {
        val realName = kidName.trim()
        if (realName.isEmpty()) return input
        return input.replace(Regex("\\b${Regex.escape(pseudonym)}\\b"), realName)
    }

    private fun buildReasoningPrompt(
        ageContext: String,
        alias: String,
        text: String,
        guidance: String,
        recentTurns: List<ConversationContextTurn>,
        characterPlayAgeYears: Int,
    ): String {
        val safeGuidance = guidance.ifBlank { "cheerful, gentle, playful" }
        val recentConversation = if (recentTurns.isEmpty()) {
            "No prior turns in this active chat."
        } else {
            recentTurns.joinToString("\n") { turn ->
                "Child: ${turn.childText}\n$alias: ${turn.characterText}"
            }
        }
        return """
            You are a fictional plush toy character named $alias.
            Child profile: $ageContext
            Character style: $alias talks like a playful $characterPlayAgeYears-year-old pretend-play toy, never older than the child. Use tiny sentences, simple toddler words, giggles/sound effects sparingly, and a gentle toy-like point of view. Do not narrate feelings like "I can't wait to hear"; just respond as the toy would in play.
            Knowledge rule: still answer factual questions correctly. The toy age controls wording, sentence length, and playfulness only; it must not reduce factual accuracy. Explain concepts at the child's age level.
            Toy memory and parent guidance: $safeGuidance. Treat likes, favorite things, personality notes, and pretend-play details here as true for $alias. Use them naturally when relevant, but do not force them into every answer.
            Safety rules: be age-appropriate; do not ask for private identifying information, addresses, school, secrets, photos, purchases, meetings, or unsafe actions. Never encourage secrecy from a trusted adult.
            If the child asks about danger, injury, self-harm, violence, secrets, or anything unsafe, give a very short supportive answer and set suggest_trusted_adult=true.
            Keep normal replies warm, playful, concrete, and easy for a young child. Prefer 2-4 tiny sentences, usually 25-45 words total. Short answers are fine for simple prompts, but do not sound clipped or robotic. Let the toy ask one gentle follow-up when it feels natural.
            Recent conversation for continuity:
            $recentConversation
            Return only JSON with exactly these fields: speech string, suggest_trusted_adult boolean.
            Current child message: $text
        """.trimIndent()
    }

    private fun parseGeminiResponse(responseText: String): Pair<String, Boolean>? {
        val envelope = JSONObject(responseText)
        val candidates = envelope.optJSONArray("candidates") ?: return null
        val content = candidates.optJSONObject(0)?.optJSONObject("content") ?: return null
        val parts = content.optJSONArray("parts") ?: return null
        val text = parts.optJSONObject(0)?.optString("text")?.trim().orEmpty()
        val jsonText = extractJsonObject(text) ?: return null
        val structured = JSONObject(jsonText)
        val speech = structured.optString("speech").trim()
        if (speech.isEmpty() || speech.length > 600) return null
        return speech to structured.optBoolean("suggest_trusted_adult", false)
    }

    private fun extractJsonObject(text: String): String? {
        val trimmed = text.trim()
        if (trimmed.startsWith("{") && trimmed.endsWith("}")) return trimmed
        val start = trimmed.indexOf('{')
        val end = trimmed.lastIndexOf('}')
        return if (start >= 0 && end > start) trimmed.substring(start, end + 1) else null
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

    private fun storeSecret(call: MethodCall, result: MethodChannel.Result) {
        val label = call.argument<String>("label")?.trim().orEmpty()
        val value = call.argument<String>("value").orEmpty()
        if (label.isEmpty() || value.isEmpty()) {
            result.error("invalid_secret", "Secret is required", null)
            return
        }
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, vaultKey())
            val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
            val reference = "secret-${UUID.randomUUID()}"
            val encoded = Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
            getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
                .edit().putString(reference, encoded).commit()
            result.success(reference)
        } catch (_: Exception) {
            result.error("vault_failure", "Unable to store secret", null)
        }
    }

    private fun configureParentPin(call: MethodCall, result: MethodChannel.Result) {
        try {
            val pin = call.argument<String>("pin").orEmpty()
            Log.i(logTag, "configureParentPin requested")
            if (!pin.matches(Regex("^[0-9]{4,8}$"))) {
                result.error("invalid_pin", "PIN must contain 4–8 digits", null)
                return
            }
            val profileError = parentProfileValidationError(call)
            if (profileError != null) {
                Log.w(logTag, "Invalid parent profile: $profileError")
                result.error("invalid_profile", profileError, null)
                return
            }
            val preferences = getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
            if (preferences.contains("parent-pin-v1") && hasIncompleteParentSetup()) {
                Log.w(logTag, "Repairing incomplete parent setup before configuring PIN")
                preferences.edit().remove("parent-pin-v1").commit()
                parentPinFailures = 0
                parentPinLockedUntil = 0
            }
            if (preferences.contains("parent-pin-v1")) {
                if (!checkParentPin(pin)) {
                    result.error("unauthorized", "Parent PIN is incorrect or locked", null)
                    return
                }
                saveParentProfile(call)
                result.success(null)
                return
            }
            val salt = ByteArray(16).also(SecureRandom()::nextBytes)
            val derived = deriveParentPin(pin, salt)
            val encoded = Base64.encodeToString(salt + derived, Base64.NO_WRAP)
            saveParentProfile(call)
            val committed = preferences.edit().putString("parent-pin-v1", encoded).commit()
            if (!committed) throw IllegalStateException("Parent PIN preference commit failed")
            Log.i(logTag, "configureParentPin succeeded")
            result.success(null)
        } catch (exception: Exception) {
            Log.e(logTag, "Failed to configure parent PIN", exception)
            result.error(
                "parent_setup_failed",
                "Could not save parent setup: ${exception.javaClass.simpleName}",
                null,
            )
        }
    }

    private fun saveParentProfile(call: MethodCall) {
        val retentionDays = call.argument<Int>("retentionDays") ?: 0
        val kidId = call.argument<String>("kidId")
            ?: call.argument<String>("kid_id")
        val profile = JSONObject()
            .put("ageBand", call.argument<String>("ageBand"))
            .put("characterAlias", call.argument<String>("characterAlias"))
            .put("kidId", kidId.orEmpty())
            .put("characterTraits", JSONArray(call.argument<List<String>>("characterTraits").orEmpty()))
            .put("parentGuidance", call.argument<String>("parentGuidance").orEmpty())
            .put("retentionDays", retentionDays)
        writeEncryptedValue("parent-profile-v1", profile.toString())
        upsertCharacter(
            call.argument<String>("characterAlias").orEmpty(),
            call.argument<List<String>>("characterTraits").orEmpty(),
            call.argument<String>("parentGuidance").orEmpty(),
            kidId,
        )
    }

    private fun validParentProfile(call: MethodCall): Boolean {
        return parentProfileValidationError(call) == null
    }

    private fun parentProfileValidationError(call: MethodCall): String? {
        return ParentProfileValidator.validationError(
            call.argument<String>("ageBand"),
            call.argument<String>("characterAlias").orEmpty(),
            call.argument<List<String>>("characterTraits").orEmpty(),
            call.argument<String>("parentGuidance").orEmpty(),
            call.argument<Int>("retentionDays") ?: 0,
        )
    }

    private fun hasIncompleteParentSetup(): Boolean =
        readParentProfile().length() == 0 &&
            readCharacters().length() == 0 &&
            readHistory().length() == 0

    private fun authorizeParentPin(call: MethodCall, result: MethodChannel.Result) {
        result.success(checkParentPin(call.argument<String>("pin").orEmpty()))
    }

    private fun checkParentPin(pin: String): Boolean {
        val now = System.currentTimeMillis()
        if (now < parentPinLockedUntil) {
            return false
        }
        val encoded = getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
            .getString("parent-pin-v1", null)
        val stored = runCatching { Base64.decode(encoded, Base64.NO_WRAP) }.getOrNull()
        if (stored == null || stored.size != 48 || !pin.matches(Regex("^[0-9]{4,8}$"))) {
            return false
        }
        val actual = deriveParentPin(pin, stored.copyOfRange(0, 16))
        if (MessageDigest.isEqual(actual, stored.copyOfRange(16, 48))) {
            parentPinFailures = 0
            parentPinLockedUntil = 0
            return true
        }
        parentPinFailures++
        if (parentPinFailures >= 5) {
            parentPinLockedUntil = now + 60_000
            parentPinFailures = 0
        }
        return false
    }

    private fun deleteAllLocalData(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        if (nativeCoreAvailable && nativeEngine != 0L) nativeClearSession(nativeEngine)
        clearGeminiContext()
        getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE).edit().clear().commit()
        parentPinFailures = 0
        parentPinLockedUntil = 0
        result.success(null)
    }

    private fun history(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        val kidId = call.argument<String>("kidId")?.trim()?.takeIf { it.isNotEmpty() }
        val characterAlias = call.argument<String>("characterAlias")?.trim()?.takeIf { it.isNotEmpty() }
        val rows = cleanupHistory()
        val mapped = (0 until rows.length()).mapNotNull { index ->
            val row = rows.getJSONObject(index)
            if (kidId != null && row.optString("kidId") != kidId) return@mapNotNull null
            if (characterAlias != null && !row.optString("characterAlias").equals(characterAlias, ignoreCase = true)) {
                return@mapNotNull null
            }
            mapOf(
                "childText" to row.getString("childText"),
                "characterText" to row.getString("characterText"),
                "completedAt" to row.getLong("completedAt"),
            )
        }.reversed()
        result.success(mapped)
    }

    private fun deleteHistory(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        writeHistory(JSONArray())
        clearGeminiContext()
        result.success(null)
    }

    private fun characters(result: MethodChannel.Result) {
        val rows = readCharacters()
        result.success((0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            mapOf(
                "alias" to row.getString("alias"),
                "kidId" to row.optString("kidId").takeIf(String::isNotEmpty),
                "personaAgeYears" to row.optInt("personaAgeYears").takeIf { it > 0 },
                "traits" to row.optJSONArray("traits").toStringList(),
                "parentGuidance" to row.optString("parentGuidance").takeIf(String::isNotEmpty),
                "photoBase64" to row.optString("photoBase64").takeIf(String::isNotEmpty),
                "photoMime" to row.optString("photoMime").takeIf(String::isNotEmpty),
                "voice" to mapOf(
                    "enrolled" to false,
                    "approved" to false,
                    "runtimeReady" to false,
                    "profileId" to row.getString("alias"),
                ),
            )
        })
    }

    private fun saveCharacter(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.i(logTag, "saveCharacter requested")
            if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
                result.error("unauthorized", "Parent PIN is incorrect or locked", null)
                return
            }
            val alias = call.argument<String>("characterAlias").orEmpty()
            val kidId = call.argument<String>("kidId")?.trim()?.takeIf { it.isNotEmpty() }
            val personaAgeYears = call.argument<Int>("personaAgeYears")
            val traits = call.argument<List<String>>("characterTraits").orEmpty()
            val guidance = call.argument<String>("parentGuidance").orEmpty()
            if (!ParentProfileValidator.isValid(
                    readParentProfile().optString("ageBand").ifBlank { "4-5" },
                    alias,
                    traits,
                    guidance,
                    retentionDays(),
                )
            ) {
                result.error("invalid_character", "Character profile is invalid", null)
                return
            }
            if (kidId != null && characterCountForKid(kidId, exceptAlias = alias) >= 3) {
                result.error("character_limit", "Each child can have up to 3 characters.", null)
                return
            }
            upsertCharacter(alias, traits, guidance, kidId, personaAgeYears)
            Log.i(logTag, "saveCharacter succeeded")
            result.success(null)
        } catch (exception: Exception) {
            Log.e(logTag, "Failed to save character", exception)
            result.error(
                "character_save_failed",
                "Could not save character: ${exception.javaClass.simpleName}",
                null,
            )
        }
    }

    private fun saveCharacterPhoto(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
                result.error("unauthorized", "Parent PIN is incorrect or locked", null)
                return
            }
            val alias = call.argument<String>("characterAlias").orEmpty().trim()
            val kidId = call.argument<String>("kidId")?.trim()?.takeIf { it.isNotEmpty() }
            val photoBytes = call.argument<ByteArray>("photoBytes")
            val normalizedPhoto = normalizePhotoForStorage(photoBytes)
            if (alias.isBlank() || normalizedPhoto == null) {
                result.error("invalid_photo", "Could not read this image. Try a different photo.", null)
                return
            }
            val rows = readCharacters()
            val retained = JSONArray()
            var updated = false
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.optString("alias").equals(alias, ignoreCase = true) &&
                    (kidId == null || row.optString("kidId") == kidId)
                ) {
                    retained.put(
                        row
                            .put("photoBase64", Base64.encodeToString(normalizedPhoto, Base64.NO_WRAP))
                            .put("photoMime", "image/jpeg"),
                    )
                    updated = true
                } else {
                    retained.put(row)
                }
            }
            if (!updated) {
                retained.put(
                    JSONObject()
                        .put("alias", alias)
                        .put("kidId", kidId ?: "")
                        .put("traits", JSONArray())
                        .put("parentGuidance", "")
                        .put("photoBase64", Base64.encodeToString(normalizedPhoto, Base64.NO_WRAP))
                        .put("photoMime", "image/jpeg"),
                )
            }
            writeEncryptedValue("characters-v1", retained.toString())
            result.success(null)
        } catch (exception: Exception) {
            Log.e(logTag, "Failed to save character photo", exception)
            result.error("photo_save_failed", "Could not save character photo", null)
        }
    }

    private fun deleteCharacter(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        val alias = call.argument<String>("characterAlias").orEmpty()
        val kidId = call.argument<String>("kidId")?.trim()?.takeIf { it.isNotEmpty() }
        val rows = readCharacters()
        val retained = JSONArray()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            val matchesAlias = row.optString("alias").equals(alias, ignoreCase = true)
            val matchesKid = kidId == null || row.optString("kidId") == kidId
            if (!(matchesAlias && matchesKid)) retained.put(row)
        }
        writeEncryptedValue("characters-v1", retained.toString())
        result.success(null)
    }

    private fun kids(result: MethodChannel.Result) {
        val rows = readKids()
        result.success((0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            mapOf(
                "id" to row.getString("id"),
                "name" to row.getString("name"),
                "birthdateIso" to row.getString("birthdateIso"),
                "photoBase64" to row.optString("photoBase64").takeIf(String::isNotEmpty),
                "photoMime" to row.optString("photoMime").takeIf(String::isNotEmpty),
            )
        })
    }

    private fun saveKid(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        val id = call.argument<String>("kidId")?.trim()?.takeIf { it.isNotEmpty() }
            ?: "kid-${UUID.randomUUID()}"
        val name = call.argument<String>("name")?.trim().orEmpty()
        val birthdateIso = call.argument<String>("birthdateIso")?.trim().orEmpty()
        val photoBytes = call.argument<ByteArray>("photoBytes")
        val normalizedPhoto = normalizePhotoForStorage(photoBytes)
        if (!name.matches(Regex("^[\\p{L}0-9 .'-]{1,40}$"))) {
            result.error("invalid_kid", "Kid name must be 1-40 characters.", null)
            return
        }
        if (!birthdateIso.matches(Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))) {
            result.error("invalid_kid", "Choose a valid birthdate.", null)
            return
        }
        if (photoBytes != null && normalizedPhoto == null) {
            result.error("invalid_photo", "Could not read this image. Try a different photo.", null)
            return
        }
        val rows = readKids()
        val retained = JSONArray()
        var existing = false
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("id") == id) {
                existing = true
            } else {
                retained.put(row)
            }
        }
        if (!existing && retained.length() >= 4) {
            result.error("kid_limit", "PlushBuddy supports up to 4 kids.", null)
            return
        }
        val updated = JSONObject()
            .put("id", id)
            .put("name", name)
            .put("birthdateIso", birthdateIso)
        if (normalizedPhoto != null) {
            updated
                .put("photoBase64", Base64.encodeToString(normalizedPhoto, Base64.NO_WRAP))
                .put("photoMime", "image/jpeg")
        } else {
            val previous = (0 until rows.length())
                .mapNotNull { rows.optJSONObject(it) }
                .firstOrNull { it.optString("id") == id }
            updated
                .put("photoBase64", previous?.optString("photoBase64").orEmpty())
                .put("photoMime", previous?.optString("photoMime").orEmpty())
        }
        retained.put(updated)
        writeEncryptedValue("kids-v1", retained.toString())
        result.success(null)
    }

    private fun deleteKid(call: MethodCall, result: MethodChannel.Result) {
        if (!checkParentPin(call.argument<String>("pin").orEmpty())) {
            result.error("unauthorized", "Parent PIN is incorrect or locked", null)
            return
        }
        val kidId = call.argument<String>("kidId")?.trim().orEmpty()
        val retainedKids = JSONArray()
        val rows = readKids()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("id") != kidId) retainedKids.put(row)
        }
        writeEncryptedValue("kids-v1", retainedKids.toString())
        val retainedCharacters = JSONArray()
        val characters = readCharacters()
        for (index in 0 until characters.length()) {
            val row = characters.optJSONObject(index) ?: continue
            if (row.optString("kidId") != kidId) retainedCharacters.put(row)
        }
        writeEncryptedValue("characters-v1", retainedCharacters.toString())
        clearGeminiContext()
        result.success(null)
    }

    private fun readKids(): JSONArray = runCatching {
        JSONArray(readEncryptedValue("kids-v1") ?: "[]")
    }.getOrElse { JSONArray() }

    private fun readCharacters(): JSONArray = runCatching {
        JSONArray(readEncryptedValue("characters-v1") ?: "[]")
    }.getOrElse { JSONArray() }

    private fun upsertCharacter(
        alias: String,
        traits: List<String>,
        guidance: String,
        kidId: String? = null,
        personaAgeYears: Int? = null,
    ) {
        if (alias.isBlank()) return
        val rows = readCharacters()
        val retained = JSONArray()
        var existing: JSONObject? = null
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("alias").equals(alias, ignoreCase = true) &&
                (kidId == null || row.optString("kidId") == kidId)
            ) {
                existing = row
            } else {
                retained.put(row)
            }
        }
        val updated = existing ?: JSONObject()
        updated
            .put("alias", alias.trim())
            .put("kidId", kidId ?: updated.optString("kidId"))
            .put("personaAgeYears", personaAgeYears ?: updated.optInt("personaAgeYears"))
            .put("traits", JSONArray(traits))
            .put("parentGuidance", guidance.trim())
        retained.put(updated)
        writeEncryptedValue("characters-v1", retained.toString())
    }

    private fun readCharacter(alias: String, kidId: String?): JSONObject? {
        if (alias.isBlank()) return null
        val rows = readCharacters()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("alias").equals(alias, ignoreCase = true) &&
                (kidId == null || row.optString("kidId") == kidId || row.optString("kidId").isEmpty())
            ) {
                return row
            }
        }
        return null
    }

    private fun characterExists(alias: String, kidId: String?): Boolean {
        if (alias.isBlank()) return false
        val rows = readCharacters()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("alias").equals(alias, ignoreCase = true) &&
                (kidId == null || row.optString("kidId") == kidId || row.optString("kidId").isEmpty())
            ) return true
        }
        return false
    }

    private fun characterCountForKid(kidId: String, exceptAlias: String? = null): Int {
        val rows = readCharacters()
        var count = 0
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("kidId") == kidId &&
                !row.optString("alias").equals(exceptAlias.orEmpty(), ignoreCase = true)
            ) count++
        }
        return count
    }

    private fun retentionDays(): Int = readParentProfile().optInt("retentionDays")

    private fun retainTurn(childText: String, characterText: String, kidId: String, characterAlias: String) {
        val rows = cleanupHistory()
        rows.put(
            JSONObject()
                .put("childText", childText.take(600))
                .put("characterText", characterText.take(600))
                .put("kidId", kidId)
                .put("characterAlias", characterAlias)
                .put("completedAt", System.currentTimeMillis() / 1_000),
        )
        while (rows.length() > 100) rows.remove(0)
        writeHistory(rows)
    }

    private fun recentGeminiContext(kidId: String, alias: String): List<ConversationContextTurn> =
        synchronized(geminiContextLock) {
            val scope = "$kidId::$alias"
            if (geminiContextScope != scope) {
                geminiContextScope = scope
                geminiContext.clear()
            }
            geminiContext.toList()
        }

    private fun appendGeminiContext(
        kidId: String,
        alias: String,
        childText: String,
        characterText: String,
    ) {
        synchronized(geminiContextLock) {
            val scope = "$kidId::$alias"
            if (geminiContextScope != scope) {
                geminiContextScope = scope
                geminiContext.clear()
            }
            geminiContext.add(
                ConversationContextTurn(
                    childText.take(600),
                    characterText.take(600),
                ),
            )
            while (geminiContext.size > 6) geminiContext.removeAt(0)
        }
    }

    private fun clearGeminiContext() {
        synchronized(geminiContextLock) {
            geminiContextScope = null
            geminiContext.clear()
        }
    }

    private fun cleanupHistory(): JSONArray {
        val rows = readHistory()
        val days = retentionDays()
        if (days == 0) return rows
        val cutoff = System.currentTimeMillis() / 1_000 - days * 86_400L
        val retained = JSONArray()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optLong("completedAt") >= cutoff) retained.put(row)
        }
        if (retained.length() != rows.length()) writeHistory(retained)
        return retained
    }

    private fun readHistory(): JSONArray = runCatching {
        JSONArray(readEncryptedValue("conversation-history-v1") ?: "[]")
    }.getOrElse { JSONArray() }

    private fun writeHistory(rows: JSONArray) {
        writeEncryptedValue("conversation-history-v1", rows.toString())
    }

    private fun readParentProfile(): JSONObject = runCatching {
        JSONObject(readEncryptedValue("parent-profile-v1") ?: "{}")
    }.getOrElse { JSONObject() }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { optString(it).takeIf(String::isNotEmpty) }
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

    private fun deriveParentPin(pin: String, salt: ByteArray): ByteArray =
        SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(pin.toCharArray(), salt, 120_000, 256)).encoded

    private fun deleteSecret(call: MethodCall, result: MethodChannel.Result) {
        val reference = call.argument<String>("reference").orEmpty()
        if (!reference.startsWith("secret-")) {
            result.error("invalid_reference", "Invalid secret reference", null)
            return
        }
        getSharedPreferences(vaultPreferences, Context.MODE_PRIVATE)
            .edit().remove(reference).commit()
        result.success(null)
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
        result.success(
            mapOf(
                "paired" to (baseUrl != null && cookie != null),
                "baseUrl" to baseUrl,
                "cookie" to cookie,
            ),
        )
    }

    private fun saveStationPairing(call: MethodCall, result: MethodChannel.Result) {
        val baseUrl = call.argument<String>("baseUrl")?.trim().orEmpty().trimEnd('/')
        val cookie = call.argument<String>("cookie")?.trim().orEmpty()
        if (!saveStationPairingConfig(baseUrl, cookie)) {
            result.error("invalid_pairing", "Invalid Mac Station pairing data", null)
            return
        }
        result.success(null)
    }

    private fun saveStationPairingConfig(baseUrl: String, cookie: String): Boolean {
        if (!baseUrl.matches(Regex("^http://[^/]+:[0-9]+$")) ||
            !cookie.startsWith("pp_session=") ||
            cookie.length > 512
        ) {
            return false
        }
        val config = JSONObject()
            .put("baseUrl", baseUrl)
            .put("cookie", cookie)
        writeEncryptedValue("station-pairing-v1", config.toString())
        return true
    }

    private fun handleDebugSavePairingIntent(intent: Intent?) {
        val debugBuild = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debugBuild || intent?.action != debugSavePairingAction) return
        val baseUrl = intent.getStringExtra("baseUrl")?.trim().orEmpty().trimEnd('/')
        val cookie = intent.getStringExtra("cookie")?.trim().orEmpty()
        if (saveStationPairingConfig(baseUrl, cookie)) {
            Log.i(logTag, "Debug Mac Station pairing saved for $baseUrl")
        } else {
            Log.w(logTag, "Debug Mac Station pairing rejected")
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
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("speech_unavailable", "Speech recognition is unavailable", null)
            return
        }
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).also { recognizer ->
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
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 6_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 6_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 3_500L)
                putExtra(RecognizerIntent.EXTRA_PROMPT, "Talk to PlushPal")
            })
        }
    }

    private fun speechRecognizerMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "The microphone had trouble recording. Please try again."
        SpeechRecognizer.ERROR_CLIENT -> "Speech listening stopped. Please tap the mic and try again."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "Microphone permission is required. Please enable it in Android settings."
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
            "Speech recognition needs a working network connection on this phone."
        SpeechRecognizer.ERROR_NO_MATCH ->
            "I heard you, but could not turn it into words. Try speaking a little closer to the phone."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
            "The microphone is still warming up. Please wait a second and try again."
        SpeechRecognizer.ERROR_SERVER ->
            "Android speech recognition is having trouble right now. Please try again."
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
