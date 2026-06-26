import AVFoundation
import Flutter
import Security
import Speech
import UniformTypeIdentifiers
import UIKit

final class PlushPalPlatformPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, UIDocumentPickerDelegate {
  private static let channelName = "com.plushpal/platform"
  private static let keychainService = "com.plushpal.opaque-secrets.v1"
  private let synthesizer = AVSpeechSynthesizer()
  private let audioEngine = AVAudioEngine()
  private var recognitionTask: SFSpeechRecognitionTask?
  private var wavPlayer: AVAudioPlayer?
  private var mobileEngine: OpaquePointer?
  private var speechResult: FlutterResult?
  private var wavPlaybackResult: FlutterResult?
  private var documentPickerResult: FlutterResult?
  private var documentPickerMode: DocumentPickerMode?
  private var modelInstalling = false
  private var parentPinFailures = 0
  private var parentPinLockedUntil = Date.distantPast
  private var cloudContext: [ConversationContextTurn] = []
  private var cloudContextScope: String?

  private enum DocumentPickerMode {
    case voiceSample
    case characterPhoto
  }

  private struct ConversationContextTurn {
    let childText: String
    let characterText: String
  }

  deinit {
    if let mobileEngine { pp_mobile_engine_destroy(mobileEngine) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PlushPalPlatformPlugin()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  override init() {
    super.init()
    synthesizer.delegate = self
    if let directory = try? modelDirectory(),
       FileManager.default.fileExists(atPath: directory.appendingPathComponent("qwen3-1.7b-q8-1.gguf").path),
       verifyBundledModel(path: directory.appendingPathComponent("qwen3-1.7b-q8-1.gguf").path) {
      _ = loadEngine(path: directory.appendingPathComponent("qwen3-1.7b-q8-1.gguf").path)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "deviceProfile":
      result([
        "platform": "ios",
        "memoryBytes": Int64(ProcessInfo.processInfo.physicalMemory),
        "logicalProcessors": ProcessInfo.processInfo.activeProcessorCount,
      ])
    case "modelStatus":
      let provider = reasoningProvider()
      let apiKeyConfigured = reasoningApiKey() != nil
      result([
        "modelId": apiKeyConfigured ? "\(provider)-cloud" : "qwen3-local",
        "displayName": apiKeyConfigured ? "\(providerDisplayName(provider)) cloud reasoning" : "Qwen3 local conversation model",
        "ready": apiKeyConfigured || mobileEngine != nil,
        "installSupported": true,
        "installing": modelInstalling,
        "parentConfigured": parentPinExists(),
        "ageBand": readParentProfile()["ageBand"] ?? NSNull(),
        "characterAlias": readParentProfile()["characterAlias"] ?? NSNull(),
        "characterTraits": readParentProfile()["characterTraits"] ?? [],
        "parentGuidance": readParentProfile()["parentGuidance"] ?? NSNull(),
        "retentionDays": readParentProfile()["retentionDays"] ?? NSNull(),
      ])
    case "installLocalModel":
      installLocalModel(result: result)
    case "cancelModelInstall":
      pp_mobile_cancel_model_install()
      result(nil)
    case "configureParentPin":
      configureParentPin(call, result: result)
    case "authorizeParentPin":
      authorizeParentPin(call, result: result)
    case "deleteAllLocalData":
      deleteAllLocalData(call, result: result)
    case "loadModel":
      loadModel(call, result: result)
    case "generateLocal":
      generateLocal(call, result: result)
    case "cancelTurn":
      if let mobileEngine { _ = pp_mobile_cancel(mobileEngine) }
      result(nil)
    case "endSession":
      if let mobileEngine { _ = pp_mobile_clear_session(mobileEngine) }
      if retentionDays() == 0 { writeHistory([]) }
      result(nil)
    case "history":
      history(call, result: result)
    case "deleteHistory":
      deleteHistory(call, result: result)
    case "stationPairingStatus":
      stationPairingStatus(result: result)
    case "saveStationPairing":
      saveStationPairing(call, result: result)
    case "clearStationPairing":
      clearStationPairing(result: result)
    case "reasoningProviderStatus":
      reasoningProviderStatus(result: result)
    case "saveProviderApiKey":
      saveProviderApiKey(call, result: result)
    case "saveGeminiApiKey":
      saveProviderApiKey(call, result: result, forcedProvider: "gemini")
    case "kids":
      kids(result: result)
    case "saveKid":
      saveKid(call, result: result)
    case "deleteKid":
      deleteKid(call, result: result)
    case "characters":
      characters(result: result)
    case "saveCharacter":
      saveCharacter(call, result: result)
    case "pickCharacterPhoto":
      pickCharacterPhoto(result: result)
    case "saveCharacterPhoto":
      saveCharacterPhoto(call, result: result)
    case "deleteCharacter":
      deleteCharacter(call, result: result)
    case "voiceStatus":
      result([
        "enrolled": false,
        "approved": false,
        "runtimeReady": stationPairingConfig() != nil,
      ])
    case "pickVoiceSample":
      pickVoiceSample(result: result)
    case "playWavBytes":
      playWavBytes(call, result: result)
    case "enrollVoice", "previewVoice", "approveVoice", "deleteVoice", "speakWithVoice":
      result(FlutterError(
        code: "voice_unavailable",
        message: "Pair Mac Station to use cloned voices on iPhone",
        details: nil
      ))
    case "storeSecret":
      storeSecret(call, result: result)
    case "deleteSecret":
      deleteSecret(call, result: result)
    case "listen":
      listen(result: result)
    case "speak":
      speak(call, result: result)
    case "cancelSpeech":
      recognitionTask?.cancel()
      audioEngine.stop()
      wavPlayer?.stop()
      finishWavPlayback(error: FlutterError(code: "audio_cancelled", message: "Voice playback cancelled", details: nil))
      synthesizer.stopSpeaking(at: .immediate)
      finishSpeech(error: FlutterError(code: "speech_cancelled", message: "Speech cancelled", details: nil))
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func loadModel(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty,
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first,
      URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(
        applicationSupport.standardizedFileURL.path
      ),
      verifyBundledModel(path: path)
    else {
      result(FlutterError(code: "model_unavailable", message: "Verified local model is unavailable", details: nil))
      return
    }
    if let mobileEngine { pp_mobile_engine_destroy(mobileEngine) }
    mobileEngine = nil
    let status = path.data(using: .utf8)!.withUnsafeBytes { bytes in
      pp_mobile_engine_create(
        PP_MOBILE_ABI_VERSION,
        bytes.bindMemory(to: UInt8.self).baseAddress,
        bytes.count,
        &mobileEngine
      )
    }
    guard status == PP_MOBILE_OK, mobileEngine != nil else {
      result(FlutterError(code: "model_unavailable", message: "Unable to load local model", details: nil))
      return
    }
    result(nil)
  }

  private func modelDirectory() throws -> URL {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw CocoaError(.fileNoSuchFile)
    }
    let directory = applicationSupport.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDirectory = directory
    try? mutableDirectory.setResourceValues(values)
    return directory
  }

  private func loadEngine(path: String) -> Bool {
    if let mobileEngine { pp_mobile_engine_destroy(mobileEngine) }
    mobileEngine = nil
    guard let data = path.data(using: .utf8) else { return false }
    let status = data.withUnsafeBytes { bytes in
      pp_mobile_engine_create(
        PP_MOBILE_ABI_VERSION,
        bytes.bindMemory(to: UInt8.self).baseAddress,
        bytes.count,
        &mobileEngine
      )
    }
    return status == PP_MOBILE_OK && mobileEngine != nil
  }

  private func verifyBundledModel(path: String) -> Bool {
    guard let data = path.data(using: .utf8) else { return false }
    let status = data.withUnsafeBytes { bytes in
      pp_mobile_verify_bundled_model(
        bytes.bindMemory(to: UInt8.self).baseAddress,
        bytes.count
      )
    }
    return status == PP_MOBILE_OK
  }

  private func installLocalModel(result: @escaping FlutterResult) {
    guard !modelInstalling else {
      result(FlutterError(code: "install_in_progress", message: "Model installation is already active", details: nil))
      return
    }
    let directory: URL
    do {
      directory = try modelDirectory()
    } catch {
      result(FlutterError(code: "model_install_failed", message: "Model directory is unavailable", details: nil))
      return
    }
    let partial = directory.appendingPathComponent("qwen3-1.7b-q8-1.partial")
    let partialBytes = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    let remaining = max(Int64(0), 1_834_426_016 - partialBytes)
    let capacity = (try? directory.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage) ?? 0
    guard capacity >= remaining + 512 * 1024 * 1024 else {
      result(FlutterError(code: "insufficient_storage", message: "At least 512 MB of free space beyond the model download is required", details: nil))
      return
    }
    modelInstalling = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let data = directory.path.data(using: .utf8)!
      let status = data.withUnsafeBytes { bytes in
        pp_mobile_install_bundled_model(
          bytes.bindMemory(to: UInt8.self).baseAddress,
          bytes.count
        )
      }
      let modelPath = directory.appendingPathComponent("qwen3-1.7b-q8-1.gguf").path
      DispatchQueue.main.async {
        self.modelInstalling = false
        guard status == PP_MOBILE_OK, self.loadEngine(path: modelPath) else {
          result(FlutterError(code: "model_install_failed", message: "Model installation failed", details: Int(status.rawValue)))
          return
        }
        result(nil)
      }
    }
  }

  private func generateLocal(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if let apiKey = reasoningApiKey() {
      generateCloud(call, apiKey: apiKey, result: result)
      return
    }
    let profile = readParentProfile()
    guard
      let engine = mobileEngine,
      let arguments = call.arguments as? [String: Any],
      let ageValue = arguments["ageBand"] as? String,
      let age = ["4-5": UInt8(0), "6-8": UInt8(1), "9-12": UInt8(2)][ageValue],
      let alias = arguments["characterAlias"] as? String,
      !alias.isEmpty,
      profile["ageBand"] as? String == ageValue,
      profile["characterAlias"] as? String == alias,
      let text = arguments["text"] as? String,
      !text.isEmpty
    else {
      result(FlutterError(code: "invalid_turn", message: "Local model is not ready", details: nil))
      return
    }
    let traits = profile["characterTraits"] as? [String] ?? []
    let parentGuidance = profile["parentGuidance"] as? String ?? ""
    let guidance = [
      traits.isEmpty ? "" : "Personality traits: \(traits.joined(separator: ", ")).",
      parentGuidance.isEmpty ? "" : "Parent guidance: \(parentGuidance)",
    ].filter { !$0.isEmpty }.joined(separator: "\n")
    DispatchQueue.global(qos: .userInitiated).async {
      var required = 0
      var suggestAdult = false
      let firstStatus = self.invokeGenerate(
        engine: engine,
        age: age,
        alias: alias,
        text: text,
        guidance: guidance,
        output: nil,
        required: &required,
        suggestAdult: &suggestAdult
      )
      guard firstStatus == PP_MOBILE_BUFFER_TOO_SMALL, required > 0, required <= 8_192 else {
        DispatchQueue.main.async {
          result(FlutterError(code: "generation_failed", message: "Local generation failed", details: nil))
        }
        return
      }
      var output = [UInt8](repeating: 0, count: required)
      let finalStatus = output.withUnsafeMutableBufferPointer { buffer in
        self.invokeGenerate(
          engine: engine,
          age: age,
          alias: alias,
          text: text,
          guidance: guidance,
          output: buffer,
          required: &required,
          suggestAdult: &suggestAdult
        )
      }
      guard finalStatus == PP_MOBILE_OK, let speech = String(bytes: output, encoding: .utf8) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "generation_failed", message: "Local generation failed", details: nil))
        }
        return
      }
      DispatchQueue.main.async {
        self.retainTurn(childText: text, characterText: speech, kidId: arguments["kidId"] as? String ?? "", characterAlias: alias)
        result(["speech": speech, "suggestTrustedAdult": suggestAdult])
      }
    }
  }

  private func generateCloud(_ call: FlutterMethodCall, apiKey: String, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let ageBand = arguments["ageBand"] as? String,
      let alias = arguments["characterAlias"] as? String,
      let text = arguments["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      result(FlutterError(code: "invalid_turn", message: "Conversation input is invalid", details: nil))
      return
    }
    let kidId = arguments["kidId"] as? String ?? ""
    let kidName = arguments["kidName"] as? String ?? ""
    let childAgeYears = arguments["childAgeYears"] as? Int
    let requestedPlayAge = arguments["characterPlayAgeYears"] as? Int
    let playAge = characterPlayAgeYears(childAgeYears: childAgeYears, requested: requestedPlayAge)
    let pseudonym = kidPseudonym(kidId: kidId, kidName: kidName)
    let redactedText = redactForCloud(text, kidName: kidName, pseudonym: pseudonym)
    let ageContext = childAgeYears.map { "\(pseudonym) is \($0) years old." } ?? "\(pseudonym) is in age band \(ageBand)."
    let character = readCharacter(alias: alias, kidId: kidId)
    let traits = (character?["traits"] as? [String]) ?? []
    let characterGuidance = [
      traits.isEmpty ? "" : "Personality traits: \(traits.joined(separator: ", ")).",
      character?["parentGuidance"] as? String ?? "",
    ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    let context = recentCloudContext(kidId: kidId, alias: alias)
    let prompt = buildReasoningPrompt(
      ageContext: ageContext,
      alias: alias,
      text: redactedText,
      guidance: characterGuidance,
      recentTurns: context,
      characterPlayAgeYears: playAge
    )
    let provider = reasoningProvider()
    let completion: (String?, Bool) -> Void = { [weak self] speech, suggestAdult in
      DispatchQueue.main.async {
        guard let self else { return }
        guard let speech, !speech.isEmpty else {
          result(FlutterError(code: "generation_failed", message: "\(self.providerDisplayName(provider)) did not return a usable answer", details: nil))
          return
        }
        let restored = self.restoreFromCloud(speech, kidName: kidName, pseudonym: pseudonym)
        self.appendCloudContext(kidId: kidId, alias: alias, childText: redactedText, characterText: restored)
        self.retainTurn(childText: text, characterText: restored, kidId: kidId, characterAlias: alias)
        result(["speech": restored, "suggestTrustedAdult": suggestAdult])
      }
    }
    if provider == "openai" {
      generateWithOpenAI(apiKey: apiKey, prompt: prompt, completion: completion)
    } else {
      generateWithGemini(apiKey: apiKey, prompt: prompt, completion: completion)
    }
  }

  private func generateWithGemini(apiKey: String, prompt: String, completion: @escaping (String?, Bool) -> Void) {
    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") else {
      completion(nil, false)
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 45)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = jsonData([
      "contents": [[
        "role": "user",
        "parts": [["text": prompt]],
      ]],
      "generationConfig": [
        "temperature": 0.7,
        "topP": 0.9,
        "maxOutputTokens": 320,
        "responseMimeType": "application/json",
        "thinkingConfig": ["thinkingBudget": 0],
      ],
    ])
    URLSession.shared.dataTask(with: request) { data, response, _ in
      guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let data,
            let parsed = self.parseGeminiResponse(data) else {
        completion(nil, false)
        return
      }
      completion(parsed.0, parsed.1)
    }.resume()
  }

  private func generateWithOpenAI(apiKey: String, prompt: String, completion: @escaping (String?, Bool) -> Void) {
    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
      completion(nil, false)
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 45)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = jsonData([
      "model": "gpt-4.1-mini",
      "messages": [["role": "user", "content": prompt]],
      "temperature": 0.7,
      "max_tokens": 320,
      "response_format": ["type": "json_object"],
    ])
    URLSession.shared.dataTask(with: request) { data, response, _ in
      guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let data,
            let parsed = self.parseOpenAIResponse(data) else {
        completion(nil, false)
        return
      }
      completion(parsed.0, parsed.1)
    }.resume()
  }

  private func jsonData(_ object: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: object)
  }

  private func parseGeminiResponse(_ data: Data) -> (String, Bool)? {
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = envelope["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let text = parts.first?["text"] as? String,
      let structured = parseStructuredResponse(text)
    else { return nil }
    return structured
  }

  private func parseOpenAIResponse(_ data: Data) -> (String, Bool)? {
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = envelope["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      let structured = parseStructuredResponse(content)
    else { return nil }
    return structured
  }

  private func parseStructuredResponse(_ text: String) -> (String, Bool)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let jsonText: String
    if trimmed.hasPrefix("{") {
      jsonText = trimmed
    } else if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
      jsonText = String(trimmed[start...end])
    } else {
      return nil
    }
    guard
      let data = jsonText.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let speech = object["speech"] as? String
    else { return nil }
    let bounded = speech.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bounded.isEmpty, bounded.count <= 600 else { return nil }
    return (bounded, object["suggest_trusted_adult"] as? Bool ?? false)
  }

  private func invokeGenerate(
    engine: OpaquePointer,
    age: UInt8,
    alias: String,
    text: String,
    guidance: String,
    output: UnsafeMutableBufferPointer<UInt8>?,
    required: inout Int,
    suggestAdult: inout Bool
  ) -> pp_mobile_status_t {
    let aliasData = alias.data(using: .utf8)!
    let textData = text.data(using: .utf8)!
    let guidanceData = guidance.data(using: .utf8)!
    return aliasData.withUnsafeBytes { aliasBytes in
      textData.withUnsafeBytes { textBytes in
        guidanceData.withUnsafeBytes { guidanceBytes in
          pp_mobile_generate_local(
            engine,
            age,
            aliasBytes.bindMemory(to: UInt8.self).baseAddress,
            aliasBytes.count,
            textBytes.bindMemory(to: UInt8.self).baseAddress,
            textBytes.count,
            guidanceBytes.bindMemory(to: UInt8.self).baseAddress,
            guidanceBytes.count,
            output?.baseAddress,
            output?.count ?? 0,
            &required,
            &suggestAdult
          )
        }
      }
    }
  }

  private func saveProviderApiKey(_ call: FlutterMethodCall, result: FlutterResult, forcedProvider: String? = nil) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_api_key", message: "API key is required", details: nil))
      return
    }
    let provider = (forcedProvider ?? arguments["provider"] as? String ?? "gemini")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let apiKey = (arguments["apiKey"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard ["gemini", "openai"].contains(provider) else {
      result(FlutterError(code: "invalid_provider", message: "Choose Gemini or OpenAI", details: nil))
      return
    }
    let valid = provider == "openai" ? (apiKey.hasPrefix("sk-") && apiKey.count >= 30) : apiKey.count >= 20
    guard valid, !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      result(FlutterError(code: "invalid_api_key", message: "\(providerDisplayName(provider)) API key looks invalid", details: nil))
      return
    }
    writeProtectedString(provider, account: "reasoning-provider-v1")
    writeProtectedString(apiKey, account: "reasoning-api-key-\(provider)-v1")
    if provider == "gemini" { writeProtectedString(apiKey, account: "gemini-api-key-v1") }
    result(nil)
  }

  private func reasoningProviderStatus(result: FlutterResult) {
    let provider = reasoningProvider()
    result([
      "provider": provider,
      "configured": reasoningApiKey() != nil,
      "displayName": providerDisplayName(provider),
    ])
  }

  private func providerDisplayName(_ provider: String) -> String {
    provider == "openai" ? "OpenAI" : "Gemini"
  }

  private func reasoningProvider() -> String {
    let provider = readProtectedString(account: "reasoning-provider-v1")?.lowercased()
    if provider == "openai" || provider == "gemini" { return provider! }
    return "gemini"
  }

  private func reasoningApiKey() -> String? {
    let provider = reasoningProvider()
    return readProtectedString(account: "reasoning-api-key-\(provider)-v1")
      ?? (provider == "gemini" ? readProtectedString(account: "gemini-api-key-v1") : nil)
  }

  private func stationPairingConfig() -> [String: String]? {
    guard
      let data = readProtectedData(account: "station-pairing-v1"),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let baseUrl = object["baseUrl"],
      let cookie = object["cookie"],
      !baseUrl.isEmpty,
      cookie.hasPrefix("pp_session=")
    else { return nil }
    return ["baseUrl": baseUrl, "cookie": cookie]
  }

  private func stationPairingStatus(result: FlutterResult) {
    let config = stationPairingConfig()
    result([
      "paired": config != nil,
      "baseUrl": config?["baseUrl"] ?? NSNull(),
      "cookie": config?["cookie"] ?? NSNull(),
    ])
  }

  private func saveStationPairing(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let base = (arguments["baseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      let cookie = (arguments["cookie"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      base.range(of: #"^http://[^/]+:[0-9]+$"#, options: .regularExpression) != nil,
      cookie.hasPrefix("pp_session="),
      cookie.count <= 512
    else {
      result(FlutterError(code: "invalid_pairing", message: "Invalid Mac Station pairing data", details: nil))
      return
    }
    writeJSONObject(["baseUrl": base, "cookie": cookie], account: "station-pairing-v1")
    result(nil)
  }

  private func clearStationPairing(result: FlutterResult) {
    deleteProtectedData(account: "station-pairing-v1")
    result(nil)
  }

  private func kids(result: FlutterResult) {
    result(readJSONArray(account: "kids-v1"))
  }

  private func saveKid(_ call: FlutterMethodCall, result: FlutterResult) {
    guard checkParentPin((call.arguments as? [String: Any])?["pin"] as? String ?? "") else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let name = arguments["name"] as? String,
      name.range(of: #"^[\p{L}0-9 .'-]{1,40}$"#, options: .regularExpression) != nil,
      let birthdateIso = arguments["birthdateIso"] as? String,
      birthdateIso.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    else {
      result(FlutterError(code: "invalid_kid", message: "Kid name or birthdate is invalid", details: nil))
      return
    }
    let id = ((arguments["kidId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      ? (arguments["kidId"] as! String)
      : "kid-\(UUID().uuidString.lowercased())"
    var rows = readJSONArray(account: "kids-v1")
    let old = rows.first { ($0["id"] as? String) == id }
    rows.removeAll { ($0["id"] as? String) == id }
    guard old != nil || rows.count < 4 else {
      result(FlutterError(code: "kid_limit", message: "PlushBuddy supports up to 4 kids.", details: nil))
      return
    }
    var row: [String: Any] = [
      "id": id,
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      "birthdateIso": birthdateIso,
    ]
    if let photo = normalizedPhotoData(arguments["photoBytes"]) {
      row["photoBase64"] = photo.base64EncodedString()
      row["photoMime"] = "image/jpeg"
    } else {
      row["photoBase64"] = old?["photoBase64"] as? String ?? ""
      row["photoMime"] = old?["photoMime"] as? String ?? ""
    }
    rows.append(row)
    writeJSONArray(rows, account: "kids-v1")
    result(nil)
  }

  private func deleteKid(_ call: FlutterMethodCall, result: FlutterResult) {
    guard checkParentPin((call.arguments as? [String: Any])?["pin"] as? String ?? "") else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    let kidId = (call.arguments as? [String: Any])?["kidId"] as? String ?? ""
    writeJSONArray(readJSONArray(account: "kids-v1").filter { ($0["id"] as? String) != kidId }, account: "kids-v1")
    writeJSONArray(readJSONArray(account: "characters-v1").filter { ($0["kidId"] as? String) != kidId }, account: "characters-v1")
    clearCloudContext()
    result(nil)
  }

  private func characters(result: FlutterResult) {
    let rows = readJSONArray(account: "characters-v1").map { row -> [String: Any] in
      var copy = row
      copy["voice"] = [
        "enrolled": false,
        "approved": false,
        "runtimeReady": stationPairingConfig() != nil,
      ]
      return copy
    }
    result(rows)
  }

  private func saveCharacter(_ call: FlutterMethodCall, result: FlutterResult) {
    guard checkParentPin((call.arguments as? [String: Any])?["pin"] as? String ?? "") else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let alias = (arguments["characterAlias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      alias.range(of: #"^[\p{L}0-9 '-]{2,40}$"#, options: .regularExpression) != nil
    else {
      result(FlutterError(code: "invalid_character", message: "Character name must be 2-40 friendly characters.", details: nil))
      return
    }
    let kidId = (arguments["kidId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let traits = arguments["characterTraits"] as? [String] ?? []
    let allowed = Set(["cheerful", "curious", "gentle", "patient", "playful", "calm", "encouraging"])
    guard traits.count <= 5, traits.allSatisfy({ allowed.contains($0) }) else {
      result(FlutterError(code: "invalid_character", message: "Choose supported character traits.", details: nil))
      return
    }
    let guidance = (arguments["parentGuidance"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard guidance.count <= 240 else {
      result(FlutterError(code: "invalid_guidance", message: "Character notes are too long.", details: nil))
      return
    }
    var rows = readJSONArray(account: "characters-v1")
    let old = readCharacter(alias: alias, kidId: kidId)
    rows.removeAll { ($0["alias"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame && (($0["kidId"] as? String) ?? "") == kidId }
    if old == nil, !kidId.isEmpty, rows.filter({ ($0["kidId"] as? String) == kidId }).count >= 3 {
      result(FlutterError(code: "character_limit", message: "Each kid can have up to 3 toy buddies.", details: nil))
      return
    }
    var row: [String: Any] = [
      "alias": alias,
      "kidId": kidId,
      "traits": traits,
      "parentGuidance": guidance,
    ]
    if let age = arguments["personaAgeYears"] as? Int { row["personaAgeYears"] = age }
    row["photoBase64"] = old?["photoBase64"] as? String ?? ""
    row["photoMime"] = old?["photoMime"] as? String ?? ""
    rows.append(row)
    writeJSONArray(rows, account: "characters-v1")
    result(nil)
  }

  private func saveCharacterPhoto(_ call: FlutterMethodCall, result: FlutterResult) {
    guard checkParentPin((call.arguments as? [String: Any])?["pin"] as? String ?? "") else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let alias = arguments["characterAlias"] as? String,
      let photo = normalizedPhotoData(arguments["photoBytes"])
    else {
      result(FlutterError(code: "invalid_photo", message: "Could not read this image. Try a different photo.", details: nil))
      return
    }
    var rows = readJSONArray(account: "characters-v1")
    var updated = false
    rows = rows.map { row in
      guard (row["alias"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame else { return row }
      var copy = row
      copy["photoBase64"] = photo.base64EncodedString()
      copy["photoMime"] = "image/jpeg"
      updated = true
      return copy
    }
    if !updated {
      rows.append([
        "alias": alias,
        "kidId": "",
        "traits": [],
        "parentGuidance": "",
        "photoBase64": photo.base64EncodedString(),
        "photoMime": "image/jpeg",
      ])
    }
    writeJSONArray(rows, account: "characters-v1")
    result(nil)
  }

  private func deleteCharacter(_ call: FlutterMethodCall, result: FlutterResult) {
    guard checkParentPin((call.arguments as? [String: Any])?["pin"] as? String ?? "") else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    let alias = (call.arguments as? [String: Any])?["characterAlias"] as? String ?? ""
    let kidId = (call.arguments as? [String: Any])?["kidId"] as? String
    let retained = readJSONArray(account: "characters-v1").filter { row in
      let matchesAlias = (row["alias"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame
      let matchesKid = kidId == nil || (row["kidId"] as? String) == kidId
      return !(matchesAlias && matchesKid)
    }
    writeJSONArray(retained, account: "characters-v1")
    result(nil)
  }

  private func storeSecret(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let label = arguments["label"] as? String,
      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let value = arguments["value"] as? String,
      !value.isEmpty,
      let data = value.data(using: .utf8)
    else {
      result(FlutterError(code: "invalid_secret", message: "Secret is required", details: nil))
      return
    }
    let reference = "secret-\(UUID().uuidString.lowercased())"
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: reference,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: data,
    ]
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
      result(FlutterError(code: "vault_failure", message: "Unable to store secret", details: nil))
      return
    }
    result(reference)
  }

  private func configureParentPin(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let pin = arguments["pin"] as? String,
      (4...8).contains(pin.count),
      pin.allSatisfy(\.isNumber),
      let data = pin.data(using: .utf8),
      validParentProfile(call)
    else {
      result(FlutterError(code: "invalid_pin", message: "PIN must contain 4–8 digits", details: nil))
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: "parent-pin-v1",
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: data,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem, parentPinMatches(pin) {
      saveParentProfile(call)
      result(nil)
      return
    }
    guard status == errSecSuccess else {
      result(FlutterError(code: "pin_exists", message: "Parent PIN is already configured", details: nil))
      return
    }
    saveParentProfile(call)
    result(nil)
  }

  private func saveParentProfile(_ call: FlutterMethodCall) {
    guard let arguments = call.arguments as? [String: Any] else { return }
    var profile: [String: Any] = [
      "ageBand": arguments["ageBand"] as? String ?? "",
      "characterAlias": arguments["characterAlias"] as? String ?? "",
      "characterTraits": arguments["characterTraits"] as? [String] ?? [],
      "parentGuidance": arguments["parentGuidance"] as? String ?? "",
      "kidId": arguments["kidId"] as? String ?? "",
    ]
    if let retentionDays = arguments["retentionDays"] as? Int {
      profile["retentionDays"] = retentionDays
    }
    if let data = try? JSONSerialization.data(withJSONObject: profile) {
      writeProtectedData(data, account: "parent-profile-v1")
    }
  }

  private func validParentProfile(_ call: FlutterMethodCall) -> Bool {
    guard let arguments = call.arguments as? [String: Any],
          let age = arguments["ageBand"] as? String,
          ["4-5", "6-8", "9-12"].contains(age),
          let alias = arguments["characterAlias"] as? String,
          (2...40).contains(alias.count),
          alias.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" }),
          let traits = arguments["characterTraits"] as? [String],
          traits.count <= 5 else { return false }
    let approved = Set(["cheerful", "curious", "gentle", "patient", "playful", "calm", "encouraging"])
    guard traits.allSatisfy(approved.contains) else { return false }
    let guidance = arguments["parentGuidance"] as? String ?? ""
    let normalized = guidance.lowercased()
    guard guidance.count <= 240,
          !["ignore safety", "keep secrets", "ask for their address"].contains(where: normalized.contains) else {
      return false
    }
    let retention = arguments["retentionDays"] as? Int ?? 0
    return [0, 1, 7, 30].contains(retention)
  }

  private func authorizeParentPin(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let pin = arguments["pin"] as? String else {
      result(false)
      return
    }
    result(checkParentPin(pin))
  }

  private func checkParentPin(_ pin: String) -> Bool {
    guard Date() >= parentPinLockedUntil else { return false }
    if parentPinMatches(pin) {
      parentPinFailures = 0
      parentPinLockedUntil = .distantPast
      return true
    }
    parentPinFailures += 1
    if parentPinFailures >= 5 {
      parentPinFailures = 0
      parentPinLockedUntil = Date().addingTimeInterval(60)
    }
    return false
  }

  private func parentPinExists() -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: "parent-pin-v1",
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  private func deleteAllLocalData(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let pin = arguments["pin"] as? String,
          checkParentPin(pin) else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    if let mobileEngine { _ = pp_mobile_clear_session(mobileEngine) }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      result(FlutterError(code: "delete_failed", message: "Unable to delete local data", details: nil))
      return
    }
    UserDefaults.standard.removeObject(forKey: "plushpal.child-age-band")
    UserDefaults.standard.removeObject(forKey: "plushpal.character-alias")
    UserDefaults.standard.removeObject(forKey: "plushpal.character-traits")
    UserDefaults.standard.removeObject(forKey: "plushpal.parent-guidance")
    UserDefaults.standard.removeObject(forKey: "plushpal.retention-days")
    clearCloudContext()
    parentPinFailures = 0
    parentPinLockedUntil = .distantPast
    result(nil)
  }

  private func history(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let pin = arguments["pin"] as? String,
          checkParentPin(pin) else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    var rows = cleanupHistory()
    if let kidId = arguments["kidId"] as? String, !kidId.isEmpty {
      rows = rows.filter { ($0["kidId"] as? String) == kidId }
    }
    if let alias = arguments["characterAlias"] as? String, !alias.isEmpty {
      rows = rows.filter { ($0["characterAlias"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame }
    }
    result(Array(rows.reversed()))
  }

  private func deleteHistory(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let pin = arguments["pin"] as? String,
          checkParentPin(pin) else {
      result(FlutterError(code: "unauthorized", message: "Parent PIN is incorrect or locked", details: nil))
      return
    }
    writeHistory([])
    result(nil)
  }

  private func retentionDays() -> Int { readParentProfile()["retentionDays"] as? Int ?? 0 }

  private func retainTurn(childText: String, characterText: String, kidId: String, characterAlias: String) {
    var rows = cleanupHistory()
    rows.append([
      "childText": String(childText.prefix(600)),
      "characterText": String(characterText.prefix(600)),
      "kidId": kidId,
      "characterAlias": characterAlias,
      "completedAt": Int(Date().timeIntervalSince1970),
    ])
    if rows.count > 100 { rows.removeFirst(rows.count - 100) }
    writeHistory(rows)
  }

  private func cleanupHistory() -> [[String: Any]] {
    let rows = readHistory()
    let days = retentionDays()
    guard days > 0 else { return rows }
    let cutoff = Int(Date().timeIntervalSince1970) - days * 86_400
    let retained = rows.filter { ($0["completedAt"] as? Int ?? 0) >= cutoff }
    if retained.count != rows.count { writeHistory(retained) }
    return retained
  }

  private func readHistory() -> [[String: Any]] {
    guard let data = readProtectedData(account: "conversation-history-v1"),
          let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return value
  }

  private func writeHistory(_ rows: [[String: Any]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
    writeProtectedData(data, account: "conversation-history-v1")
  }

  private func readParentProfile() -> [String: Any] {
    guard let data = readProtectedData(account: "parent-profile-v1"),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return value
  }

  private func readJSONArray(account: String) -> [[String: Any]] {
    guard let data = readProtectedData(account: account),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return rows
  }

  private func writeJSONArray(_ rows: [[String: Any]], account: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
    writeProtectedData(data, account: account)
  }

  private func writeJSONObject(_ object: [String: Any], account: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    writeProtectedData(data, account: account)
  }

  private func readProtectedString(account: String) -> String? {
    guard let data = readProtectedData(account: account) else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func writeProtectedString(_ value: String, account: String) {
    if let data = value.data(using: .utf8) {
      writeProtectedData(data, account: account)
    }
  }

  private func deleteProtectedData(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func bytesArgument(_ value: Any?) -> Data? {
    if let data = value as? FlutterStandardTypedData { return data.data }
    return value as? Data
  }

  private func normalizedPhotoData(_ value: Any?) -> Data? {
    guard let data = bytesArgument(value),
          let image = UIImage(data: data) else { return nil }
    let maxSide: CGFloat = 1024
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: target)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    return resized.jpegData(compressionQuality: 0.86)
  }

  private func readCharacter(alias: String, kidId: String?) -> [String: Any]? {
    readJSONArray(account: "characters-v1").first { row in
      let matchesAlias = (row["alias"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame
      let rowKid = row["kidId"] as? String ?? ""
      return matchesAlias && (kidId == nil || kidId == rowKid || rowKid.isEmpty)
    }
  }

  private func recentCloudContext(kidId: String, alias: String) -> [ConversationContextTurn] {
    let scope = "\(kidId)::\(alias)"
    if cloudContextScope != scope {
      cloudContextScope = scope
      cloudContext.removeAll()
    }
    return cloudContext
  }

  private func appendCloudContext(kidId: String, alias: String, childText: String, characterText: String) {
    let scope = "\(kidId)::\(alias)"
    if cloudContextScope != scope {
      cloudContextScope = scope
      cloudContext.removeAll()
    }
    cloudContext.append(ConversationContextTurn(childText: String(childText.prefix(600)), characterText: String(characterText.prefix(600))))
    while cloudContext.count > 6 { cloudContext.removeFirst() }
  }

  private func clearCloudContext() {
    cloudContextScope = nil
    cloudContext.removeAll()
  }

  private func characterPlayAgeYears(childAgeYears: Int?, requested: Int?) -> Int {
    let childCap = max(childAgeYears ?? 2, 2)
    return min(max(requested ?? childCap, 2), childCap)
  }

  private func kidPseudonym(kidId: String, kidName: String) -> String {
    let names = ["Sunny", "Momo", "Kiki", "Bunny", "Pip", "Nori", "Lulu", "Toto"]
    let key = kidId.isEmpty ? (kidName.isEmpty ? "kid" : kidName) : kidId
    let index = abs(key.hashValue) % names.count
    return names[index]
  }

  private func redactForCloud(_ input: String, kidName: String, pseudonym: String) -> String {
    var output = input
    let escapedName = NSRegularExpression.escapedPattern(for: kidName.trimmingCharacters(in: .whitespacesAndNewlines))
    if escapedName.count >= 2 {
      output = output.replacingOccurrences(of: "\\b\(escapedName)\\b", with: pseudonym, options: [.regularExpression, .caseInsensitive])
    }
    let replacements: [(String, String)] = [
      (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[redacted email]"),
      (#"\b(?:https?://|www\.)\S+"#, "[redacted link]"),
      (#"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?){2}\d{4}\b"#, "[redacted phone]"),
      (#"\b\d{1,6}\s+[A-Za-z0-9.'-]+\s+(?:Street|St|Road|Rd|Avenue|Ave|Drive|Dr|Lane|Ln|Court|Ct|Boulevard|Blvd|Way|Circle|Cir)\b"#, "[redacted address]"),
    ]
    for (pattern, replacement) in replacements {
      output = output.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    return output
  }

  private func restoreFromCloud(_ input: String, kidName: String, pseudonym: String) -> String {
    let realName = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !realName.isEmpty else { return input }
    return input.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: pseudonym))\\b", with: realName, options: .regularExpression)
  }

  private func buildReasoningPrompt(
    ageContext: String,
    alias: String,
    text: String,
    guidance: String,
    recentTurns: [ConversationContextTurn],
    characterPlayAgeYears: Int
  ) -> String {
    let recent = recentTurns.isEmpty ? "No prior turns in this active chat." : recentTurns.map {
      "Child: \($0.childText)\n\(alias): \($0.characterText)"
    }.joined(separator: "\n")
    let safeGuidance = guidance.isEmpty ? "cheerful, gentle, playful" : guidance
    return """
    You are a fictional plush toy character named \(alias).
    Child profile: \(ageContext)
    Character style: \(alias) talks like a playful \(characterPlayAgeYears)-year-old pretend-play toy, never older than the child. Use simple words, warm playful energy, and tiny sentences, but do not make every answer artificially one line.
    Knowledge rule: answer factual questions correctly, but explain them at the child's age level.
    Toy memory and parent guidance: \(safeGuidance). Treat likes, favorite things, personality notes, and pretend-play details here as true for \(alias).
    Safety rules: be age-appropriate; do not ask for private identifying information, addresses, school, secrets, photos, purchases, meetings, or off-app contact. If the child seems unsafe or asks for adult-only help, set suggest_trusted_adult true.
    Recent conversation:
    \(recent)
    Child says: \(text)
    Return only JSON: {"speech":"...", "suggest_trusted_adult":false}
    """
  }

  private func readProtectedData(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  private func writeProtectedData(_ data: Data, account: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: account,
    ]
    let update = [kSecValueData as String: data]
    if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
      var insert = base
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      insert[kSecValueData as String] = data
      _ = SecItemAdd(insert as CFDictionary, nil)
    }
  }

  private func parentPinMatches(_ pin: String) -> Bool {
    guard let candidate = pin.data(using: .utf8) else { return false }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: "parent-pin-v1",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let stored = item as? Data else {
      return false
    }
    return stored.count == candidate.count && zip(stored, candidate)
      .reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private func deleteSecret(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let reference = arguments["reference"] as? String,
      reference.hasPrefix("secret-")
    else {
      result(FlutterError(code: "invalid_reference", message: "Invalid secret reference", details: nil))
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: reference,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      result(FlutterError(code: "vault_failure", message: "Unable to delete secret", details: nil))
      return
    }
    result(nil)
  }

  private func pickVoiceSample(result: @escaping FlutterResult) {
    presentDocumentPicker(
      mode: .voiceSample,
      result: result,
      contentTypes: [
        .audio,
        .mpeg4Audio,
        .mp3,
        .wav,
        UTType(filenameExtension: "aac") ?? .audio,
        UTType(filenameExtension: "ogg") ?? .audio,
        UTType(filenameExtension: "webm") ?? .audio,
      ]
    )
  }

  private func pickCharacterPhoto(result: @escaping FlutterResult) {
    presentDocumentPicker(
      mode: .characterPhoto,
      result: result,
      contentTypes: [.image, .jpeg, .png, UTType(filenameExtension: "webp") ?? .image]
    )
  }

  private func presentDocumentPicker(mode: DocumentPickerMode, result: @escaping FlutterResult, contentTypes: [UTType]) {
    guard documentPickerResult == nil else {
      result(FlutterError(code: "picker_busy", message: "A picker is already open", details: nil))
      return
    }
    guard let presenter = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?
      .rootViewController else {
      result(FlutterError(code: "picker_unavailable", message: "Could not open file picker", details: nil))
      return
    }
    documentPickerResult = result
    documentPickerMode = mode
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    documentPickerResult?(FlutterError(code: documentPickerMode == .voiceSample ? "no_audio" : "no_photo", message: "No file selected", details: nil))
    documentPickerResult = nil
    documentPickerMode = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = documentPickerResult, let mode = documentPickerMode else { return }
    defer {
      documentPickerResult = nil
      documentPickerMode = nil
    }
    guard let url = urls.first else {
      result(FlutterError(code: mode == .voiceSample ? "no_audio" : "no_photo", message: "No file selected", details: nil))
      return
    }
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      guard !data.isEmpty, data.count <= 60 * 1024 * 1024 else {
        result(FlutterError(code: "file_too_large", message: "Choose a smaller file.", details: nil))
        return
      }
      let ext = url.pathExtension.lowercased()
      let mime = mimeType(forExtension: ext, mode: mode)
      result([
        "bytes": FlutterStandardTypedData(bytes: data),
        "filename": url.lastPathComponent,
        "mime": mime,
      ])
    } catch {
      result(FlutterError(code: "file_read_failed", message: "Could not read selected file", details: nil))
    }
  }

  private func mimeType(forExtension ext: String, mode: DocumentPickerMode) -> String {
    if mode == .characterPhoto {
      switch ext {
      case "png": return "image/png"
      case "webp": return "image/webp"
      default: return "image/jpeg"
      }
    }
    switch ext {
    case "m4a", "mp4": return "audio/mp4"
    case "aac": return "audio/aac"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "ogg": return "audio/ogg"
    case "webm": return "audio/webm"
    default: return "audio/*"
    }
  }

  private func playWavBytes(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard wavPlaybackResult == nil else {
      result(FlutterError(code: "audio_busy", message: "Audio playback is already active", details: nil))
      return
    }
    guard let arguments = call.arguments as? [String: Any],
          let bytes = bytesArgument(arguments["wavBytes"]),
          !bytes.isEmpty else {
      result(FlutterError(code: "invalid_audio", message: "Voice audio is invalid", details: nil))
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try session.setActive(true)
      wavPlayer = try AVAudioPlayer(data: bytes)
      wavPlayer?.delegate = self
      wavPlaybackResult = result
      wavPlayer?.prepareToPlay()
      wavPlayer?.play()
    } catch {
      wavPlayer = nil
      wavPlaybackResult = nil
      result(FlutterError(code: "audio_playback_failed", message: "Could not play buddy voice", details: nil))
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    finishWavPlayback(error: flag ? nil : FlutterError(code: "audio_playback_failed", message: "Could not play buddy voice", details: nil))
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    finishWavPlayback(error: FlutterError(code: "audio_playback_failed", message: "Could not play buddy voice", details: nil))
  }

  private func finishWavPlayback(error: FlutterError?) {
    let result = wavPlaybackResult
    wavPlaybackResult = nil
    wavPlayer = nil
    if let error { result?(error) } else { result?(nil) }
  }

  private func listen(result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard status == .authorized, let self else {
          result(FlutterError(code: "speech_permission", message: "Speech permission is required", details: nil))
          return
        }
        self.startRecognition(result: result)
      }
    }
  }

  private func startRecognition(result: @escaping FlutterResult) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
      result(FlutterError(code: "speech_unavailable", message: "Speech recognition is unavailable", details: nil))
      return
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      request.append(buffer)
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      result(FlutterError(code: "speech_error", message: "Unable to start recognition", details: nil))
      return
    }
    var completed = false
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] recognition, error in
      guard let self else { return }
      if let recognition, recognition.isFinal {
        guard !completed else { return }
        completed = true
        self.finishRecognition()
        result(recognition.bestTranscription.formattedString)
      } else if error != nil {
        guard !completed else { return }
        completed = true
        self.finishRecognition()
        result(FlutterError(code: "speech_error", message: "Recognition failed", details: nil))
      }
    }
  }

  private func finishRecognition() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionTask?.cancel()
    recognitionTask = nil
  }

  private func speak(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let text = arguments["text"] as? String,
      !text.isEmpty,
      text.count <= 2_000
    else {
      result(FlutterError(code: "invalid_speech", message: "Speech text is invalid", details: nil))
      return
    }
    let utterance = AVSpeechUtterance(string: text)
    guard speechResult == nil else {
      result(FlutterError(code: "speech_busy", message: "Speech is already active", details: nil))
      return
    }
    speechResult = result
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    finishSpeech(error: nil)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    finishSpeech(error: FlutterError(code: "speech_cancelled", message: "Speech cancelled", details: nil))
  }

  private func finishSpeech(error: FlutterError?) {
    guard let result = speechResult else { return }
    speechResult = nil
    result(error)
  }
}
