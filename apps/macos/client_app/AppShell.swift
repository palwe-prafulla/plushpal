import AppKit
import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers
import WebKit

private final class NativeSpeechSession {
    let id: String
    let audioEngine: AVAudioEngine
    let request: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask?
    var latestTranscript = ""
    var lastTranscriptAt = Date()
    let startedAt = Date()

    init(id: String, audioEngine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest) {
        self.id = id
        self.audioEngine = audioEngine
        self.request = request
    }
}

final class MacClientAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVAudioPlayerDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var fallbackView: NSView!
    private var statusLabel: NSTextField!
    private var nativeSpeechSession: NativeSpeechSession?
    private var nativeAudioPlayer: AVAudioPlayer?
    private var nativeAudioCallbackId: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        loadStationUrlIfAvailable()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "toytalkLog")
        userContentController.add(self, name: "toytalkNativeSpeech")
        userContentController.add(self, name: "toytalkNativeAudio")
        userContentController.addUserScript(WKUserScript(
            source: """
            (() => {
              window.__toytalkClientPlatform = 'macos';
              window.__toytalkClientLabel = 'ToyTalk Mac app';
              window.__toytalkNativeSpeechCallbacks = new Map();
              window.__toytalkNativeSpeechResolve = (payload) => {
                const callback = window.__toytalkNativeSpeechCallbacks.get(payload && payload.id);
                if (!callback) return;
                window.__toytalkNativeSpeechCallbacks.delete(payload.id);
                if (payload.ok) {
                  callback.resolve(String(payload.text || ''));
                } else {
                  callback.reject(new Error(String(payload.error || 'Native speech failed.')));
                }
              };
              window.toytalkNativeSpeechSupported = () =>
                Boolean(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.toytalkNativeSpeech);
              window.toytalkNativeListen = () => new Promise((resolve, reject) => {
                const id = `mac-speech-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
                window.__toytalkNativeSpeechCallbacks.set(id, {resolve, reject});
                try {
                  window.webkit.messageHandlers.toytalkNativeSpeech.postMessage({id});
                } catch (error) {
                  window.__toytalkNativeSpeechCallbacks.delete(id);
                  reject(error);
                }
              });
              window.__toytalkNativeAudioCallbacks = new Map();
              window.__toytalkNativeAudioResolve = (payload) => {
                const callback = window.__toytalkNativeAudioCallbacks.get(payload && payload.id);
                if (!callback) return;
                window.__toytalkNativeAudioCallbacks.delete(payload.id);
                if (payload.ok) {
                  callback.resolve();
                } else {
                  callback.reject(new Error(String(payload.error || 'Native audio playback failed.')));
                }
              };
              window.toytalkNativeAudioSupported = () =>
                Boolean(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.toytalkNativeAudio);
              window.toytalkNativePlayWavBase64 = (wavBase64) => new Promise((resolve, reject) => {
                const id = `mac-audio-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
                window.__toytalkNativeAudioCallbacks.set(id, {resolve, reject});
                try {
                  window.webkit.messageHandlers.toytalkNativeAudio.postMessage({id, wavBase64: String(wavBase64 || '')});
                } catch (error) {
                  window.__toytalkNativeAudioCallbacks.delete(id);
                  reject(error);
                }
              });
              const stringify = (value) => {
                try {
                  if (value instanceof Error) return value.stack || value.message;
                  if (typeof value === 'string') return value;
                  return JSON.stringify(value);
                } catch (_) {
                  return String(value);
                }
              };
              const send = (level, values) => {
                try {
                  window.webkit.messageHandlers.toytalkLog.postMessage({
                    level,
                    message: Array.from(values).map(stringify).join(' '),
                    url: window.location.href,
                  });
                } catch (_) {}
              };
              for (const level of ['log', 'warn', 'error']) {
                const original = console[level];
                console[level] = function(...args) {
                  send(`console.${level}`, args);
                  return original.apply(this, args);
                };
              }
              window.addEventListener('error', (event) => {
                send('window.error', [
                  event.message,
                  `${event.filename || ''}:${event.lineno || 0}:${event.colno || 0}`,
                ]);
              });
              window.addEventListener('unhandledrejection', (event) => {
                send('window.unhandledrejection', [event.reason]);
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        fallbackView = NSView()
        fallbackView.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Open ToyTalk from Hub")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: """
        ToyTalk is the Mac client UI. Start ToyTalk Hub first so it can prepare voice services, then click “Open Mac client” in Hub.
        """)
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let openStationButton = NSButton(title: "Open ToyTalk Hub", target: self, action: #selector(openStation))
        openStationButton.bezelStyle = .rounded
        openStationButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, statusLabel, openStationButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.addSubview(stack)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fallbackView)
        content.addSubview(webView)

        NSLayoutConstraint.activate([
            fallbackView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fallbackView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fallbackView.topAnchor.constraint(equalTo: content.topAnchor),
            fallbackView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fallbackView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: fallbackView.leadingAnchor, constant: 60),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackView.trailingAnchor, constant: -60),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            openStationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ToyTalk"
        window.minSize = NSSize(width: 820, height: 600)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func loadStationUrlIfAvailable() {
        if let url = stationUrlFromArguments() ?? persistedStationUrl() {
            load(url)
        } else {
            fallbackView.isHidden = false
            webView.isHidden = true
        }
    }

    private func load(_ url: URL) {
        appendLog("client-app.log", "loading station url \(url.absoluteString)")
        fallbackView.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    private func stationUrlFromArguments() -> URL? {
        let args = CommandLine.arguments
        for index in args.indices {
            guard args[index] == "--station-url", args.indices.contains(index + 1) else { continue }
            return URL(string: args[index + 1])
        }
        if let value = ProcessInfo.processInfo.environment["PLUSHBUDDY_STATION_URL"] {
            return URL(string: value)
        }
        return nil
    }

    private func persistedStationUrl() -> URL? {
        let candidates = ["Hub", "Station"].map {
            applicationSupportDirectory()
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("latest-client-url.txt", isDirectory: false)
        }
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            return URL(string: text)
        }
        return nil
    }

    @objc private func openStation() {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ToyTalk Hub.app", isDirectory: true),
        ]
        if let station = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: station, configuration: NSWorkspace.OpenConfiguration())
        } else {
            statusLabel.stringValue = "I could not find ToyTalk Hub next to this app. Open Hub manually, then launch this app from Hub."
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendLog("client-app.log", "navigation finished \(webView.url?.absoluteString ?? "<unknown>")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    private func showLoadFailure(_ error: Error) {
        appendLog("client-app.log", "navigation failed \(error.localizedDescription)")
        fallbackView.isHidden = false
        webView.isHidden = true
        statusLabel.stringValue = "ToyTalk could not connect to Hub: \(error.localizedDescription). Start Hub and try again."
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "toytalkNativeSpeech" {
            guard let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  !id.isEmpty else {
                return
            }
            startNativeSpeech(id: id)
            return
        }
        if message.name == "toytalkNativeAudio" {
            guard let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let wavBase64 = body["wavBase64"] as? String,
                  !id.isEmpty else {
                return
            }
            playNativeWav(id: id, wavBase64: wavBase64)
            return
        }
        appendLog("client-web.log", "\(message.body)")
    }

    private func playNativeWav(id: String, wavBase64: String) {
        DispatchQueue.main.async {
            if let previousId = self.nativeAudioCallbackId {
                self.nativeAudioPlayer?.stop()
                self.resolveNativeAudio(id: previousId, error: "Audio playback was interrupted by a new response.")
            }
            guard let data = Data(base64Encoded: wavBase64), !data.isEmpty else {
                self.resolveNativeAudio(id: id, error: "ToyTalk received empty voice audio.")
                return
            }
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.prepareToPlay()
                self.nativeAudioPlayer = player
                self.nativeAudioCallbackId = id
                if !player.play() {
                    self.nativeAudioPlayer = nil
                    self.nativeAudioCallbackId = nil
                    self.resolveNativeAudio(id: id, error: "ToyTalk could not start voice playback.")
                }
            } catch {
                self.nativeAudioPlayer = nil
                self.nativeAudioCallbackId = nil
                self.resolveNativeAudio(id: id, error: error.localizedDescription)
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === nativeAudioPlayer else { return }
        let id = nativeAudioCallbackId
        nativeAudioPlayer = nil
        nativeAudioCallbackId = nil
        if let id {
            resolveNativeAudio(id: id, error: flag ? nil : "ToyTalk voice playback stopped early.")
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === nativeAudioPlayer else { return }
        let id = nativeAudioCallbackId
        nativeAudioPlayer = nil
        nativeAudioCallbackId = nil
        if let id {
            resolveNativeAudio(id: id, error: error?.localizedDescription ?? "ToyTalk could not decode voice audio.")
        }
    }

    private func resolveNativeAudio(id: String, error: String?) {
        let payload: [String: Any] = [
            "id": id,
            "ok": error == nil,
            "error": error ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__toytalkNativeAudioResolve(\(json));")
    }

    private func startNativeSpeech(id: String) {
        DispatchQueue.main.async {
            guard self.nativeSpeechSession == nil else {
                self.resolveNativeSpeech(id: id, text: nil, error: "The microphone is already listening.")
                return
            }
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            guard let recognizer, recognizer.isAvailable else {
                self.resolveNativeSpeech(id: id, text: nil, error: "Mac on-device speech recognition is unavailable.")
                return
            }
            if #available(macOS 13.0, *) {
                guard recognizer.supportsOnDeviceRecognition else {
                    self.resolveNativeSpeech(id: id, text: nil, error: "Mac on-device speech recognition is not available on this Mac.")
                    return
                }
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        self.resolveNativeSpeech(id: id, text: nil, error: "Speech recognition permission is required.")
                        return
                    }
                    self.requestMicrophoneAndStartNativeSpeech(id: id, recognizer: recognizer)
                }
            }
        }
    }

    private func requestMicrophoneAndStartNativeSpeech(id: String, recognizer: SFSpeechRecognizer) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            runNativeSpeech(id: id, recognizer: recognizer)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.runNativeSpeech(id: id, recognizer: recognizer)
                    } else {
                        self.resolveNativeSpeech(id: id, text: nil, error: "Microphone permission is required.")
                    }
                }
            }
        default:
            resolveNativeSpeech(id: id, text: nil, error: "Microphone permission is required.")
        }
    }

    private func runNativeSpeech(id: String, recognizer: SFSpeechRecognizer) {
        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            resolveNativeSpeech(id: id, text: nil, error: "The microphone is not ready.")
            return
        }
        let session = NativeSpeechSession(id: id, audioEngine: audioEngine, request: request)
        nativeSpeechSession = session
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            nativeSpeechSession = nil
            resolveNativeSpeech(id: id, text: nil, error: "The microphone could not start.")
            return
        }
        session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self,
                      let active = self.nativeSpeechSession,
                      active.id == id else {
                    return
                }
                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    active.latestTranscript = text
                    active.lastTranscriptAt = Date()
                }
                if let error {
                    self.finishNativeSpeech(id: id, error: error.localizedDescription)
                } else if result?.isFinal == true {
                    self.finishNativeSpeech(id: id, error: nil)
                }
            }
        }
        appendLog("client-app.log", "native on-device speech started")
        scheduleNativeSpeechCheck(id: id)
    }

    private func scheduleNativeSpeechCheck(id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let session = self.nativeSpeechSession, session.id == id else { return }
            let now = Date()
            if !session.latestTranscript.isEmpty && now.timeIntervalSince(session.lastTranscriptAt) >= 1.4 {
                self.finishNativeSpeech(id: id, error: nil)
                return
            }
            if now.timeIntervalSince(session.startedAt) >= 10 {
                self.finishNativeSpeech(id: id, error: session.latestTranscript.isEmpty ? "I did not hear speech yet. Try again after the beep." : nil)
                return
            }
            self.scheduleNativeSpeechCheck(id: id)
        }
    }

    private func finishNativeSpeech(id: String, error: String?) {
        guard let session = nativeSpeechSession, session.id == id else { return }
        session.audioEngine.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
        session.request.endAudio()
        session.task?.cancel()
        nativeSpeechSession = nil
        if let error {
            appendLog("client-app.log", "native on-device speech failed: \(error)")
            resolveNativeSpeech(id: id, text: nil, error: error)
            return
        }
        let transcript = session.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        appendLog("client-app.log", "native on-device speech finished chars=\(transcript.count)")
        resolveNativeSpeech(id: id, text: transcript, error: transcript.isEmpty ? "I did not hear speech yet. Try again after the beep." : nil)
    }

    private func resolveNativeSpeech(id: String, text: String?, error: String?) {
        let payload: [String: Any] = [
            "id": id,
            "ok": error == nil,
            "text": text ?? "",
            "error": error ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__toytalkNativeSpeechResolve(\(json));")
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose voice sample or character photo"
        panel.prompt = "Choose file"
        panel.message = "Choose a voice sample or character photo."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                .image,
                .mpeg4Audio,
                .wav,
                .mp3,
                .audio,
                UTType(filenameExtension: "aac") ?? .audio,
                UTType(filenameExtension: "ogg") ?? .audio,
                UTType(filenameExtension: "webm") ?? .audio,
            ]
        } else {
            panel.allowedFileTypes = ["png", "jpg", "jpeg", "webp", "heic", "m4a", "mp4", "aac", "wav", "mp3", "ogg", "webm"]
        }
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    private func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ToyTalk", isDirectory: true)
    }

    private func appendLog(_ fileName: String, _ message: String) {
        let line = "[\(Date())] \(message)\n"
        let logs = applicationSupportDirectory().appendingPathComponent("logs", isDirectory: true)
        let file = logs.appendingPathComponent(fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging must never block the client UI.
        }
    }
}

let application = NSApplication.shared
let delegate = MacClientAppDelegate()
application.delegate = delegate
application.run()
