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
  private var speechRecorder: AVAudioRecorder?
  private var speechRecordingResult: FlutterResult?
  private var speechRecordingUrl: URL?
  private var wavPlayer: AVAudioPlayer?
  private var speechResult: FlutterResult?
  private var wavPlaybackResult: FlutterResult?
  private var documentPickerResult: FlutterResult?
  private var documentPickerMode: DocumentPickerMode?

  private enum DocumentPickerMode {
    case voiceSample
    case characterPhoto
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
    purgeLegacyClientOwnedData()
    synthesizer.delegate = self
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
      result([
        "modelId": "hub-required",
        "displayName": "PlushBuddy Hub",
        "ready": false,
        "installSupported": false,
        "installing": false,
        "parentConfigured": false,
        "ageBand": NSNull(),
        "characterAlias": NSNull(),
        "characterTraits": [],
        "parentGuidance": NSNull(),
        "retentionDays": NSNull(),
      ])
    case "installLocalModel":
      hubRequired(result: result)
    case "cancelModelInstall":
      result(nil)
    case "configureParentPin",
      "authorizeParentPin",
      "deleteAllLocalData",
      "loadModel",
      "generateLocal",
      "history",
      "deleteHistory",
      "reasoningProviderStatus",
      "saveProviderApiKey",
      "saveGeminiApiKey",
      "kids",
      "saveKid",
      "deleteKid",
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
      "deleteSecret":
      hubRequired(result: result)
    case "cancelTurn":
      result(nil)
    case "endSession":
      result(nil)
    case "stationClientId":
      result(stationClientId())
    case "stationPairingStatus":
      stationPairingStatus(result: result)
    case "saveStationPairing":
      saveStationPairing(call, result: result)
    case "clearStationPairing":
      clearStationPairing(result: result)
    case "pickCharacterPhoto":
      pickCharacterPhoto(result: result)
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
    case "listen":
      listen(result: result)
    case "recordSpeechWav":
      recordSpeechWav(result: result)
    case "speak":
      speak(call, result: result)
    case "cancelSpeech":
      recognitionTask?.cancel()
      audioEngine.stop()
      finishSpeechRecording(error: FlutterError(code: "speech_cancelled", message: "Speech recording cancelled", details: nil))
      wavPlayer?.stop()
      finishWavPlayback(error: FlutterError(code: "audio_cancelled", message: "Voice playback cancelled", details: nil))
      synthesizer.stopSpeaking(at: .immediate)
      finishSpeech(error: FlutterError(code: "speech_cancelled", message: "Speech cancelled", details: nil))
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func hubRequired(result: FlutterResult) {
    result(FlutterError(
      code: "hub_required",
      message: "Connect PlushBuddy Hub before using family, voice, AI, or conversation data.",
      details: nil
    ))
  }

  private func stationPairingConfig() -> [String: String]? {
    guard
      let data = readProtectedData(account: "station-pairing-v1"),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let baseUrl = object["baseUrl"],
      let cookie = object["cookie"],
      let hubId = object["hubId"],
      !baseUrl.isEmpty,
      cookie.hasPrefix("pp_session="),
      hubId.range(of: #"^hub-[a-f0-9-]{36}$"#, options: .regularExpression) != nil
    else { return nil }
    return [
      "baseUrl": baseUrl,
      "cookie": cookie,
      "clientId": object["clientId"] ?? stationClientId(),
      "hubId": hubId,
    ]
  }

  private func stationPairingStatus(result: FlutterResult) {
    let config = stationPairingConfig()
    result([
      "paired": config != nil,
      "baseUrl": config?["baseUrl"] ?? NSNull(),
      "cookie": config?["cookie"] ?? NSNull(),
      "clientId": config?["clientId"] ?? stationClientId(),
      "hubId": config?["hubId"] ?? NSNull(),
    ])
  }

  private func saveStationPairing(_ call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let base = (arguments["baseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      let cookie = (arguments["cookie"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let hubId = (arguments["hubId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      base.range(of: #"^http://[^/]+:[0-9]+$"#, options: .regularExpression) != nil,
      cookie.hasPrefix("pp_session="),
      cookie.count <= 512,
      hubId.range(of: #"^hub-[a-f0-9-]{36}$"#, options: .regularExpression) != nil
    else {
      result(FlutterError(code: "invalid_pairing", message: "Invalid Hub pairing data", details: nil))
      return
    }
    let providedClientId = (arguments["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let clientId = providedClientId.isEmpty ? stationClientId() : providedClientId
    guard clientId.range(of: #"^ios-[a-f0-9-]{36}$"#, options: .regularExpression) != nil else {
      result(FlutterError(code: "invalid_pairing", message: "Invalid Hub pairing data", details: nil))
      return
    }
    writeJSONObject(["baseUrl": base, "cookie": cookie, "clientId": clientId, "hubId": hubId], account: "station-pairing-v1")
    result(nil)
  }

  private func stationClientId() -> String {
    if
      let data = readProtectedData(account: "station-client-id-v1"),
      let existing = String(data: data, encoding: .utf8),
      existing.range(of: #"^ios-[a-f0-9-]{36}$"#, options: .regularExpression) != nil
    {
      return existing
    }
    let generated = "ios-\(UUID().uuidString.lowercased())"
    writeProtectedData(Data(generated.utf8), account: "station-client-id-v1")
    return generated
  }

  private func clearStationPairing(result: FlutterResult) {
    deleteProtectedData(account: "station-pairing-v1")
    result(nil)
  }

  private func writeJSONObject(_ object: [String: Any], account: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    writeProtectedData(data, account: account)
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

  private func purgeLegacyClientOwnedData() {
    [
      "parent-pin-v1",
      "parent-profile-v1",
      "kids-v1",
      "characters-v1",
      "conversation-history-v1",
      "reasoning-provider-v1",
      "reasoning-api-key-gemini-v1",
      "reasoning-api-key-openai-v1",
      "gemini-api-key-v1",
    ].forEach(deleteProtectedData)
    [
      "plushpal.child-age-band",
      "plushpal.character-alias",
      "plushpal.character-traits",
      "plushpal.parent-guidance",
      "plushpal.retention-days",
    ].forEach(UserDefaults.standard.removeObject)
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
    guard recognizer.supportsOnDeviceRecognition else {
      result(FlutterError(code: "speech_on_device_unavailable", message: "On-device speech recognition is unavailable on this device. Type a message or install offline speech support.", details: nil))
      return
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = true
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

  private func recordSpeechWav(result: @escaping FlutterResult) {
    guard speechRecordingResult == nil else {
      result(FlutterError(code: "speech_busy", message: "Speech recording is already active", details: nil))
      return
    }
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted else {
          result(FlutterError(code: "microphone_permission", message: "Microphone permission is required", details: nil))
          return
        }
        self.startSpeechWavRecording(result: result)
      }
    }
  }

  private func startSpeechWavRecording(result: @escaping FlutterResult) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("plushbuddy-hub-stt-\(UUID().uuidString).wav")
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      recorder.prepareToRecord()
      speechRecorder = recorder
      speechRecordingResult = result
      speechRecordingUrl = url
      recorder.record(forDuration: 8.0)
      DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { [weak self] in
        self?.finishSpeechRecording(error: nil)
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
      result(FlutterError(code: "speech_recording_failed", message: "Microphone recording failed", details: nil))
    }
  }

  private func finishSpeechRecording(error: FlutterError?) {
    guard let result = speechRecordingResult else { return }
    let url = speechRecordingUrl
    speechRecorder?.stop()
    speechRecorder = nil
    speechRecordingResult = nil
    speechRecordingUrl = nil
    defer {
      if let url { try? FileManager.default.removeItem(at: url) }
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    if let error {
      result(error)
      return
    }
    guard let url,
          let data = try? Data(contentsOf: url),
          data.count > 44 else {
      result(FlutterError(code: "speech_no_audio", message: "I did not hear speech yet. Try again after the beep.", details: nil))
      return
    }
    result(FlutterStandardTypedData(bytes: data))
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
