import AppKit
import CoreImage
import Foundation
import Security
import UniformTypeIdentifiers
import WebKit

private enum StartupState {
    case preparingVoiceRuntime
    case startingHost
    case loadingApp
    case stationReady(URL)
    case ready
    case failed(String)
}

private struct StartupFailure: Error {
    let message: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var splashView: NSView!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var serviceStatusStack: NSStackView!
    private var storageStatusLabel: NSTextField!
    private var reasoningStatusLabel: NSTextField!
    private var voiceStatusLabel: NSTextField!
    private var hostStatusLabel: NSTextField!
    private var browserStatusLabel: NSTextField!
    private var retryButton: NSButton!
    private var quitButton: NSButton!
    private var openBrowserButton: NSButton!
    private var pairAndroidButton: NSButton!
    private var openInAppButton: NSButton!
    private var configureGeminiButton: NSButton!
    private var pairingWindow: NSWindow?
    private var currentPairingUrlText: String?
    private var hostProcess: Process?
    private var installProcess: Process?
    private var hostPipe: Pipe?
    private var installPipe: Pipe?
    private var hostOutput = Data()
    private var setupOutput = Data()
    private var didLoadHostUrl = false
    private var hostUrl: URL?
    private var parsedHostUrlText: String?
    private var lanPairingUrl: URL?
    private var isTerminating = false
    private let logQueue = DispatchQueue(label: "com.plushpal.app-shell.logs")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prepareAndStart()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        installPipe?.fileHandleForReading.readabilityHandler = nil
        hostPipe?.fileHandleForReading.readabilityHandler = nil
        installProcess?.terminate()
        hostProcess?.terminate()
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "plushpalLog")
        userContentController.addUserScript(WKUserScript(
            source: """
            (() => {
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
                  window.webkit.messageHandlers.plushpalLog.postMessage({
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

        splashView = NSView()
        splashView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "Starting PlushPal")
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "Preparing the local app on this Mac…")
        detailLabel.font = .systemFont(ofSize: 15, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 10
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        progress.translatesAutoresizingMaskIntoConstraints = false

        storageStatusLabel = NSTextField(labelWithString: "○ App storage: preparing")
        reasoningStatusLabel = NSTextField(labelWithString: "○ Reasoning engine: waiting")
        voiceStatusLabel = NSTextField(labelWithString: "○ Voice engine: waiting")
        hostStatusLabel = NSTextField(labelWithString: "○ Local service: waiting")
        browserStatusLabel = NSTextField(labelWithString: "○ Browser UI / Android pairing: waiting")
        for label in [storageStatusLabel, reasoningStatusLabel, voiceStatusLabel, hostStatusLabel, browserStatusLabel] {
            label?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label?.textColor = .secondaryLabelColor
            label?.alignment = .left
            label?.translatesAutoresizingMaskIntoConstraints = false
        }
        serviceStatusStack = NSStackView(views: [
            storageStatusLabel,
            reasoningStatusLabel,
            voiceStatusLabel,
            hostStatusLabel,
            browserStatusLabel,
        ])
        serviceStatusStack.orientation = .vertical
        serviceStatusStack.alignment = .leading
        serviceStatusStack.distribution = .fill
        serviceStatusStack.spacing = 8
        serviceStatusStack.translatesAutoresizingMaskIntoConstraints = false

        retryButton = NSButton(title: "Retry setup", target: self, action: #selector(retryStartup))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        quitButton = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.isHidden = true
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        openBrowserButton = NSButton(title: "Open PlushBuddy in browser", target: self, action: #selector(openPlushPalInBrowser))
        openBrowserButton.bezelStyle = .rounded
        openBrowserButton.isHidden = true
        openBrowserButton.translatesAutoresizingMaskIntoConstraints = false

        pairAndroidButton = NSButton(title: "Show Android pairing QR", target: self, action: #selector(showAndroidPairingLink))
        pairAndroidButton.bezelStyle = .rounded
        pairAndroidButton.isHidden = true
        pairAndroidButton.translatesAutoresizingMaskIntoConstraints = false

        openInAppButton = NSButton(title: "Open PlushBuddy Mac app", target: self, action: #selector(openPlushPalInApp))
        openInAppButton.bezelStyle = .rounded
        openInAppButton.isHidden = true
        openInAppButton.translatesAutoresizingMaskIntoConstraints = false

        configureGeminiButton = NSButton(title: "Configure Gemini key", target: self, action: #selector(configureGeminiKey))
        configureGeminiButton.bezelStyle = .rounded
        configureGeminiButton.isHidden = true
        configureGeminiButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [
            openBrowserButton,
            pairAndroidButton,
            openInAppButton,
            configureGeminiButton,
            retryButton,
            quitButton,
        ])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        splashView.addSubview(titleLabel)
        splashView.addSubview(detailLabel)
        splashView.addSubview(progress)
        splashView.addSubview(serviceStatusStack)
        splashView.addSubview(buttonStack)

        let content = NSView()
        content.addSubview(webView)
        content.addSubview(splashView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            splashView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splashView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splashView.topAnchor.constraint(equalTo: content.topAnchor),
            splashView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            progress.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: splashView.centerYAnchor, constant: -52),
            titleLabel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -40),
            titleLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 24),
            detailLabel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 72),
            detailLabel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -72),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            serviceStatusStack.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            serviceStatusStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 28),
            buttonStack.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            buttonStack.topAnchor.constraint(equalTo: serviceStatusStack.bottomAnchor, constant: 28),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            openBrowserButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            pairAndroidButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            openInAppButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            configureGeminiButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PlushBuddy Station"
        window.minSize = NSSize(width: 900, height: 640)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func prepareAndStart() {
        appendLog("app-shell.log", "prepareAndStart")
        update(.preparingVoiceRuntime)
        setupOutput.removeAll()
        updateServiceStatuses(
            storage: "● App storage: ready in \(applicationSupportDirectory().path)",
            reasoning: "○ Reasoning engine: verifying local model or Gemini key",
            voice: "○ Voice engine: verifying LuxTTS",
            host: "○ Local service: waiting",
            browser: "○ Browser UI / Android pairing: waiting"
        )
        let voiceRuntime: VoiceRuntime?
        switch prepareVoiceRuntime() {
        case .success(let runtime):
            voiceRuntime = runtime
            updateServiceStatuses(
                storage: nil,
                reasoning: "○ Reasoning engine: waiting for host health",
                voice: runtime == nil ? "△ Voice engine: skipped for development" : "● Voice engine: \(runtime!.engine) ready",
                host: "○ Local service: waiting",
                browser: "○ Browser UI / Android pairing: waiting"
            )
        case .failure(let failure):
            updateServiceStatuses(
                storage: nil,
                reasoning: "○ Reasoning engine: waiting",
                voice: "✕ Voice engine: setup failed",
                host: "○ Local service: waiting",
                browser: "○ Browser UI / Android pairing: waiting"
            )
            update(.failed(failure.message))
            return
        }
        update(.startingHost)
        startHost(voiceRuntime: voiceRuntime)
    }

    private func prepareVoiceRuntime() -> Result<VoiceRuntime?, StartupFailure> {
        if let lux = prepareLuxTtsRuntime() {
            return lux
        }
        if ProcessInfo.processInfo.environment["PLUSHPAL_ENABLE_CHATTERBOX_FALLBACK"] == nil {
            return .failure(StartupFailure(message: "The local LuxTTS voice runtime is missing from the PlushBuddy Station app bundle."))
        }
        return prepareChatterboxRuntime()
    }

    private func prepareLuxTtsRuntime() -> Result<VoiceRuntime?, StartupFailure>? {
        let bundle = Bundle.main
        let script = bundle.resourceURL?
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent("luxtts_tts.py")
        let installer = bundle.resourceURL?
            .appendingPathComponent("install_luxtts_runtime.sh")

        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            return nil
        }

        let support = applicationSupportDirectory()
        let venv = support.appendingPathComponent("luxtts-venv", isDirectory: true)
        let python = venv.appendingPathComponent("bin/python")
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin/python3")

        if let bundledPython,
           FileManager.default.isExecutableFile(atPath: bundledPython.path),
           isLuxTtsRuntimeReady(python: bundledPython, script: script) {
            return .success(VoiceRuntime(engine: "luxtts", python: bundledPython, script: script))
        }

        if FileManager.default.isExecutableFile(atPath: python.path),
           isLuxTtsRuntimeReady(python: python, script: script) {
            return .success(VoiceRuntime(engine: "luxtts", python: python, script: script))
        }

        if ProcessInfo.processInfo.environment["PLUSHPAL_SKIP_LUXTTS_INSTALL"] != nil {
            return .success(nil)
        }

        guard let installer, FileManager.default.isExecutableFile(atPath: installer.path) else {
            return .failure(StartupFailure(message: "The local LuxTTS installer is missing from the PlushBuddy Station app bundle."))
        }

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.path, venv.path]
            process.environment = mergedEnvironment(extra: [
                "PLUSHPAL_LUXTTS_SCRIPT": script.path,
                "PLUSHPAL_BUNDLED_PYTHON": Bundle.main.resourceURL?
                    .appendingPathComponent("python", isDirectory: true)
                    .appendingPathComponent("bin/python3")
                    .path ?? "",
            ])

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            installProcess = process
            installPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.setupOutput.append(data)
                self?.appendLogData("setup.log", data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let line = text.split(separator: "\n").last.map(String.init) ?? text
                self?.updateDetail("Installing LuxTTS local voice support… \(line)")
            }
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            installProcess = nil
            installPipe = nil

            if process.terminationStatus == 0,
               FileManager.default.isExecutableFile(atPath: python.path),
               isLuxTtsRuntimeReady(python: python, script: script) {
                return .success(VoiceRuntime(engine: "luxtts", python: python, script: script))
            }
            return .failure(StartupFailure(message: "PlushPal could not finish installing LuxTTS voice support. \(setupDiagnosticTail())"))
        } catch {
            installProcess = nil
            installPipe = nil
            return .failure(StartupFailure(message: "PlushPal could not install LuxTTS voice support: \(error.localizedDescription)\n\n\(setupDiagnosticTail())"))
        }
    }

    private func prepareChatterboxRuntime() -> Result<VoiceRuntime?, StartupFailure> {
        let bundle = Bundle.main
        let script = bundle.resourceURL?
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent("chatterbox_tts.py")
        let installer = bundle.resourceURL?
            .appendingPathComponent("install_chatterbox_runtime.sh")

        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            return .failure(StartupFailure(message: "The local voice setup script is missing from the PlushBuddy Station app bundle."))
        }

        let support = applicationSupportDirectory()
        let venv = support.appendingPathComponent("chatterbox-venv", isDirectory: true)
        let python = venv.appendingPathComponent("bin/python")
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin/python3")

        if let bundledPython,
           FileManager.default.isExecutableFile(atPath: bundledPython.path),
           isChatterboxRuntimeImportReady(python: bundledPython) {
            return .success(VoiceRuntime(engine: "chatterbox", python: bundledPython, script: script))
        }

        if FileManager.default.isExecutableFile(atPath: python.path),
           isChatterboxRuntimeImportReady(python: python) {
            return .success(VoiceRuntime(engine: "chatterbox", python: python, script: script))
        }

        if ProcessInfo.processInfo.environment["PLUSHPAL_SKIP_CHATTERBOX_INSTALL"] != nil {
            return .success(nil)
        }

        guard let installer, FileManager.default.isExecutableFile(atPath: installer.path) else {
            return .failure(StartupFailure(message: "The local voice installer is missing from the PlushBuddy Station app bundle."))
        }

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.path, venv.path]
            process.environment = mergedEnvironment(extra: [
                "PLUSHPAL_CHATTERBOX_SCRIPT": script.path,
                "PLUSHPAL_BUNDLED_PYTHON": Bundle.main.resourceURL?
                    .appendingPathComponent("python", isDirectory: true)
                    .appendingPathComponent("bin/python3")
                    .path ?? "",
            ])

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            installProcess = process
            installPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.setupOutput.append(data)
                self?.appendLogData("setup.log", data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let line = text.split(separator: "\n").last.map(String.init) ?? text
                self?.updateDetail("Installing local voice support… \(line)")
            }
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            installProcess = nil
            installPipe = nil

            if process.terminationStatus == 0,
               FileManager.default.isExecutableFile(atPath: python.path),
               isChatterboxRuntimeImportReady(python: python) {
                return .success(VoiceRuntime(engine: "chatterbox", python: python, script: script))
            }
            return .failure(StartupFailure(message: "PlushPal could not finish installing local voice support. \(setupDiagnosticTail())"))
        } catch {
            installProcess = nil
            installPipe = nil
            return .failure(StartupFailure(message: "PlushPal could not install local voice support: \(error.localizedDescription)\n\n\(setupDiagnosticTail())"))
        }
    }

    private func isLuxTtsRuntimeReady(python: URL, script: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--healthcheck"]
        process.environment = mergedEnvironment(extra: [:])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isChatterboxRuntimeImportReady(python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-c",
            "import torch, torchaudio; from chatterbox.tts import ChatterboxTTS",
        ]
        process.environment = mergedEnvironment(extra: [:])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func startHost(voiceRuntime: VoiceRuntime?) {
        guard let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("plushpal-desktop-host", isDirectory: false) as URL?,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            update(.failed("The PlushPal local service is missing from the app bundle."))
            return
        }

        let process = Process()
        process.executableURL = helper
        process.currentDirectoryURL = Bundle.main.resourceURL
        var extra = [
            "PLUSHPAL_NO_BROWSER": "1",
            "PLUSHPAL_PRINT_BOOTSTRAP_URL": "1",
            "PLUSHPAL_PORT": "0",
        ]
        if let lanAddress = preferredLanIPv4Address() {
            extra["PLUSHPAL_ENABLE_LAN"] = "1"
            extra["PLUSHPAL_LAN_HOST"] = lanAddress
            appendLog("app-shell.log", "LAN pairing candidate \(lanAddress)")
        }
        if let voiceRuntime {
            extra["PLUSHPAL_VOICE_ENGINE"] = voiceRuntime.engine
            if voiceRuntime.engine == "luxtts" {
                extra["PLUSHPAL_LUXTTS_PYTHON"] = voiceRuntime.python.path
                extra["PLUSHPAL_LUXTTS_SCRIPT"] = voiceRuntime.script.path
                extra["PLUSHPAL_LUXTTS_NUM_STEPS"] = "8"
                extra["PLUSHPAL_LUXTTS_SPEED"] = "0.88"
                extra["PLUSHPAL_LUXTTS_SEED"] = "11"
                extra["PLUSHPAL_LUXTTS_REF_DURATION"] = "180"
            } else {
                extra["PLUSHPAL_CHATTERBOX_PYTHON"] = voiceRuntime.python.path
                extra["PLUSHPAL_CHATTERBOX_SCRIPT"] = voiceRuntime.script.path
                extra["PLUSHPAL_CHATTERBOX_ENGINE"] = "standard"
            }
        }
        process.environment = mergedEnvironment(extra: extra)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        hostProcess = process
        hostPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeHostOutput(data)
        }
        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.hostPipe?.fileHandleForReading.readabilityHandler = nil
                self.hostPipe = nil
                self.hostProcess = nil
                let diagnostic = self.hostDiagnosticTail()
                let suffix = diagnostic.isEmpty ? "" : "\n\n\(diagnostic)"
                self.appendLog("app-shell.log", "host terminated status=\(terminated.terminationStatus) reason=\(terminated.terminationReason.rawValue) didLoadHostUrl=\(self.didLoadHostUrl)")
                if self.didLoadHostUrl {
                    self.update(.failed("The local PlushPal service stopped unexpectedly. Exit code \(terminated.terminationStatus).\(suffix)"))
                } else {
                    self.update(.failed("The local PlushPal service stopped before the app was ready. Exit code \(terminated.terminationStatus).\(suffix)"))
                }
            }
        }

        do {
            try process.run()
        } catch {
            update(.failed("Could not start the local PlushPal service: \(error.localizedDescription)"))
        }
    }

    @objc private func retryStartup() {
        installProcess?.terminate()
        hostProcess?.terminate()
        installProcess = nil
        hostProcess = nil
        installPipe = nil
        hostPipe = nil
        hostOutput.removeAll()
        didLoadHostUrl = false
        hostUrl = nil
        parsedHostUrlText = nil
        lanPairingUrl = nil
        update(.preparingVoiceRuntime)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prepareAndStart()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openPlushPalInBrowser() {
        guard let hostUrl else { return }
        persistStationClientUrl(hostUrl)
        NSWorkspace.shared.open(hostUrl)
    }

    @objc private func showAndroidPairingLink() {
        guard let pairingUrl = lanPairingUrl ?? hostUrl else { return }
        let isLanUrl = lanPairingUrl != nil
        currentPairingUrlText = pairingUrl.absoluteString

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Android pairing"
        panel.isReleasedWhenClosed = false
        panel.center()

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let title = NSTextField(labelWithString: "Pair Android with PlushPal Station")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let instructions = NSTextField(wrappingLabelWithString: """
        \(isLanUrl ? "Keep this Mac awake and on the same Wi‑Fi as the Android phone." : "No LAN address was detected, so this fallback address only works on this Mac.")

        In the Android app, tap Pair Mac Station and scan this QR code.
        """)
        instructions.font = .systemFont(ofSize: 14)
        instructions.textColor = .secondaryLabelColor
        instructions.alignment = .center
        instructions.translatesAutoresizingMaskIntoConstraints = false

        let qrContainer = NSView()
        qrContainer.wantsLayer = true
        qrContainer.layer?.backgroundColor = NSColor.white.cgColor
        qrContainer.layer?.cornerRadius = 16
        qrContainer.translatesAutoresizingMaskIntoConstraints = false
        if let image = qrCodeImage(for: pairingUrl.absoluteString, size: 300) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            qrContainer.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: qrContainer.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: qrContainer.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 300),
                imageView.heightAnchor.constraint(equalToConstant: 300),
            ])
        }

        let closeButton = NSButton(title: "Done", target: self, action: #selector(closePairingWindow))
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, instructions, qrContainer, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            qrContainer.widthAnchor.constraint(equalToConstant: 340),
            qrContainer.heightAnchor.constraint(equalToConstant: 340),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        pairingWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func copyCurrentPairingUrl() {
        guard let currentPairingUrlText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPairingUrlText, forType: .string)
    }

    @objc private func closePairingWindow() {
        pairingWindow?.close()
        pairingWindow = nil
    }

    private func qrCodeImage(for text: String, size: CGFloat) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let colored = CIFilter(name: "CIFalseColor")
        colored?.setValue(output, forKey: kCIInputImageKey)
        colored?.setValue(CIColor(color: .black), forKey: "inputColor0")
        colored?.setValue(CIColor(color: .white), forKey: "inputColor1")
        let finalImage = colored?.outputImage ?? output
        let scale = size / max(output.extent.width, output.extent.height)
        let transformed = finalImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    @objc private func openPlushPalInApp() {
        guard let hostUrl else { return }
        persistStationClientUrl(hostUrl)
        guard let clientAppUrl = bundledClientAppUrl() else {
            appendLog("app-shell.log", "missing PlushBuddy Mac client app; falling back to browser \(hostUrl.absoluteString)")
            NSWorkspace.shared.open(hostUrl)
            return
        }

        appendLog("app-shell.log", "opening PlushBuddy Mac client \(clientAppUrl.path) url=\(hostUrl.absoluteString)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--station-url", hostUrl.absoluteString]
        NSWorkspace.shared.openApplication(at: clientAppUrl, configuration: configuration) { [weak self] _, error in
            if let error {
                self?.appendLog("app-shell.log", "failed to open PlushBuddy Mac client: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not open PlushBuddy"
                    alert.informativeText = "Station is healthy, but the Mac client app could not be opened. Opening the browser version instead."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    NSWorkspace.shared.open(hostUrl)
                }
            }
        }
    }

    private func bundledClientAppUrl() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("PlushBuddy.app", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PlushBuddy.app", isDirectory: true),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persistStationClientUrl(_ url: URL) {
        let directory = applicationSupportDirectory()
            .appendingPathComponent("Station", isDirectory: true)
        let file = directory.appendingPathComponent("latest-client-url.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            appendLog("app-shell.log", "could not persist latest client url: \(error.localizedDescription)")
        }
    }

    @objc private func configureGeminiKey() {
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 24))
        input.placeholderString = "Paste Gemini API key"
        let alert = NSAlert()
        alert.messageText = "Configure Gemini"
        alert.informativeText = "The key is stored only on this Mac in the macOS Keychain. The local service restarts after saving."
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try saveGeminiKeyToKeychain(key)
            removeLegacyGeminiKeyFile()
            appendLog("app-shell.log", "Gemini key saved to macOS Keychain")
            retryStartup()
        } catch {
            update(.failed("Could not save Gemini key: \(error.localizedDescription)"))
        }
    }

    private func saveGeminiKeyToKeychain(_ key: String) throws {
        let data = Data(key.utf8)
        guard data.count >= 16 else {
            throw NSError(
                domain: "PlushPalKeychain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API key looks too short."]
            )
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.plushpal.local",
            kSecAttrAccount as String: "plushpal-gemini-api-key-v1",
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain rejected the Gemini key."]
            )
        }
    }

    private func removeLegacyGeminiKeyFile() {
        let secretsDirectory = applicationSupportDirectory().appendingPathComponent("secrets", isDirectory: true)
        let file = secretsDirectory.appendingPathComponent("gemini_api_key", isDirectory: false)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: secretsDirectory)
    }

    private func consumeHostOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        hostOutput.append(data)
        appendLogData("host.log", data)
        guard let text = String(data: hostOutput, encoding: .utf8) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("PlushPal test bootstrap URL:") {
                let urlText = line.replacingOccurrences(of: "PlushPal test bootstrap URL:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard parsedHostUrlText != urlText else { continue }
                if let url = URL(string: urlText) {
                    parsedHostUrlText = urlText
                    didLoadHostUrl = true
                    hostUrl = url
                    appendLog("app-shell.log", "station host url \(urlText)")
                    DispatchQueue.main.async { [weak self] in
                        self?.updateServiceStatuses(
                            storage: nil,
                            reasoning: nil,
                            voice: nil,
                            host: "○ Local service: health check pending",
                            browser: "○ Browser UI / Android pairing: waiting for health"
                        )
                    }
                    waitForStationHealth(url)
                }
            } else if line.contains("PlushPal LAN bootstrap URL:") {
                let urlText = line.replacingOccurrences(of: "PlushPal LAN bootstrap URL:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: urlText), lanPairingUrl?.absoluteString != urlText {
                    lanPairingUrl = url
                    appendLog("app-shell.log", "station LAN pairing url \(urlText)")
                }
            }
        }
    }

    private func preferredLanIPv4Address() -> String? {
        let addresses = Host.current().addresses
        let privatePrefixes = ["10.", "172.", "192.168."]
        return addresses.first { candidate in
            guard candidate.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else {
                return false
            }
            guard !candidate.hasPrefix("127."), !candidate.hasPrefix("169.254.") else {
                return false
            }
            return privatePrefixes.contains { candidate.hasPrefix($0) }
        } ?? addresses.first { candidate in
            candidate.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil &&
                !candidate.hasPrefix("127.") &&
                !candidate.hasPrefix("169.254.")
        }
    }

    private func waitForStationHealth(_ hostUrl: URL) {
        guard let healthUrl = healthEndpoint(for: hostUrl) else {
            update(.failed("The local PlushPal service returned an invalid health-check URL."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for attempt in 1...120 {
                if self.isStationHealthReady(healthUrl) {
                    self.appendLog("app-shell.log", "station health ready \(healthUrl.absoluteString)")
                    DispatchQueue.main.async { [weak self] in
                        self?.updateServiceStatuses(
                            storage: nil,
                            reasoning: "● Reasoning engine: ready",
                            voice: "● Voice engine: ready",
                            host: "● Local service: healthy",
                            browser: "● Browser UI / Android pairing: ready"
                        )
                        self?.update(.stationReady(hostUrl))
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateServiceStatuses(
                        storage: nil,
                        reasoning: "○ Reasoning engine: waiting for health check",
                        voice: "○ Voice engine: waiting for health check",
                        host: "○ Local service: health check attempt \(attempt)/120",
                        browser: "○ Browser UI / Android pairing: waiting"
                    )
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            self.updateServiceStatuses(
                storage: nil,
                reasoning: "✕ Reasoning engine: health check did not pass",
                voice: "✕ Voice engine: health check did not pass",
                host: "✕ Local service: health check timed out",
                browser: "○ Browser UI / Android pairing: waiting"
            )
            self.update(.failed("PlushPal started the local service, but required health checks did not pass within 2 minutes. Click Retry setup to try again."))
        }
    }

    private func healthEndpoint(for hostUrl: URL) -> URL? {
        var components = URLComponents()
        components.scheme = hostUrl.scheme
        components.host = hostUrl.host
        components.port = hostUrl.port
        components.path = "/api/v1/health"
        return components.url
    }

    private func isStationHealthReady(_ healthUrl: URL) -> Bool {
        var request = URLRequest(url: healthUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var ready = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard
                let status = (response as? HTTPURLResponse)?.statusCode,
                status == 200,
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }
            ready =
                json["local_service_ready"] as? Bool == true &&
                json["conversation_engine_ready"] as? Bool == true &&
                json["voice_engine_ready"] as? Bool == true &&
                json["browser_ui_ready"] as? Bool == true
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return ready
    }

    private func hostDiagnosticTail() -> String {
        guard let text = String(data: hostOutput, encoding: .utf8) else { return "" }
        let lines = text
            .split(separator: "\n")
            .suffix(6)
            .map(String.init)
        return lines.joined(separator: "\n")
    }

    private func setupDiagnosticTail() -> String {
        guard let text = String(data: setupOutput, encoding: .utf8) else { return "Click Retry setup to try again." }
        let lines = text
            .split(separator: "\n")
            .suffix(8)
            .map(String.init)
        return lines.isEmpty ? "Click Retry setup to try again." : lines.joined(separator: "\n")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendLog("app-shell.log", "webView didFinish \(webView.url?.absoluteString ?? "unknown-url")")
        update(.ready)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        appendLog("app-shell.log", "webView didFail \(error.localizedDescription)")
        update(.failed("Could not load PlushPal: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        appendLog("app-shell.log", "webView didFailProvisional \(error.localizedDescription)")
        update(.failed("Could not load PlushPal: \(error.localizedDescription)"))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "plushpalLog" else { return }
        if let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "browser"
            let text = body["message"] as? String ?? ""
            let url = body["url"] as? String ?? ""
            appendLog("browser.log", "[\(level)] \(url) \(text)")
        } else {
            appendLog("browser.log", "\(message.body)")
        }
    }

    private func appendLogData(_ fileName: String, _ data: Data) {
        guard !data.isEmpty else { return }
        logQueue.async { [weak self] in
            guard let self else { return }
            let file = self.logFile(fileName)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    private func appendLog(_ fileName: String, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        appendLogData(fileName, Data("[\(timestamp)] \(message)\n".utf8))
    }

    private func logFile(_ fileName: String) -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose voice sample"
        panel.prompt = "Choose audio file"
        panel.message = "Choose a clean 15-second to 3-minute M4A, WAV, MP3, AAC, OGG, or WebM recording."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                .mpeg4Audio,
                .wav,
                .mp3,
                .audio,
                UTType(filenameExtension: "aac") ?? .audio,
                UTType(filenameExtension: "ogg") ?? .audio,
                UTType(filenameExtension: "webm") ?? .audio,
            ]
        } else {
            panel.allowedFileTypes = ["m4a", "mp4", "aac", "wav", "mp3", "ogg", "webm"]
        }
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    private func update(_ state: StartupState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .preparingVoiceRuntime:
                self.titleLabel.stringValue = "Preparing PlushPal"
                self.detailLabel.stringValue = "Checking app storage, local voice support, and cached downloads. First launch can take a few minutes; later launches reuse what is already installed."
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.configureGeminiButton.isHidden = true
            case .startingHost:
                self.titleLabel.stringValue = "Starting local service"
                self.detailLabel.stringValue = "Starting the local PlushPal service. Browser and Android pairing options will appear after health checks pass."
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.configureGeminiButton.isHidden = true
            case .loadingApp:
                self.titleLabel.stringValue = "Loading PlushPal"
                self.detailLabel.stringValue = "Almost ready…"
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.configureGeminiButton.isHidden = true
            case .stationReady(let url):
                self.progress.stopAnimation(nil)
                self.titleLabel.stringValue = "PlushBuddy Station is ready"
                self.detailLabel.stringValue = "All required local services are healthy. Open PlushBuddy on this Mac, in a browser, or scan the Android pairing QR."
                self.splashView.isHidden = false
                self.webView.isHidden = true
                self.retryButton.isHidden = false
                self.quitButton.isHidden = false
                self.openBrowserButton.isHidden = false
                self.pairAndroidButton.isHidden = false
                self.openInAppButton.isHidden = false
                self.configureGeminiButton.isHidden = true
                self.hostUrl = url
                self.persistStationClientUrl(url)
            case .ready:
                self.progress.stopAnimation(nil)
                self.splashView.isHidden = true
                self.webView.isHidden = false
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.configureGeminiButton.isHidden = true
            case .failed(let message):
                self.progress.stopAnimation(nil)
                self.titleLabel.stringValue = "PlushPal needs setup"
                self.detailLabel.stringValue = message
                self.splashView.isHidden = false
                self.webView.isHidden = true
                self.retryButton.isHidden = false
                self.quitButton.isHidden = false
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.configureGeminiButton.isHidden = true
            }
        }
    }

    private func updateServiceStatuses(
        storage: String?,
        reasoning: String?,
        voice: String?,
        host: String?,
        browser: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let storage { self.storageStatusLabel.stringValue = storage }
            if let reasoning { self.reasoningStatusLabel.stringValue = reasoning }
            if let voice { self.voiceStatusLabel.stringValue = voice }
            if let host { self.hostStatusLabel.stringValue = host }
            if let browser { self.browserStatusLabel.stringValue = browser }
        }
    }

    private func updateDetail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.detailLabel.stringValue = message
        }
    }

    private func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlushPal", isDirectory: true)
    }

    private func mergedEnvironment(extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let cache = applicationSupportDirectory().appendingPathComponent("cache", isDirectory: true)
        let applicationHuggingFaceCache = cache.appendingPathComponent("huggingface", isDirectory: true)
        let applicationHuggingFaceHubCache = applicationHuggingFaceCache.appendingPathComponent("hub", isDirectory: true)
        let bundledHuggingFaceCache = Bundle.main.resourceURL?
            .appendingPathComponent("model-cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        let numbaCache = cache.appendingPathComponent("numba", isDirectory: true)
        let matplotlibCache = cache.appendingPathComponent("matplotlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: applicationHuggingFaceCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: applicationHuggingFaceHubCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: numbaCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: matplotlibCache, withIntermediateDirectories: true)
        let huggingFaceCache: URL
        let effectiveHubCache: URL
        if let bundledHuggingFaceCache,
           FileManager.default.fileExists(atPath: bundledHuggingFaceCache.path) {
            huggingFaceCache = bundledHuggingFaceCache
            effectiveHubCache = bundledHuggingFaceCache.appendingPathComponent("hub", isDirectory: true)
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        } else {
            huggingFaceCache = applicationHuggingFaceCache
            effectiveHubCache = applicationHuggingFaceHubCache
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["XDG_CACHE_HOME"] = cache.path
        environment["HF_HOME"] = huggingFaceCache.path
        environment["HF_HUB_CACHE"] = effectiveHubCache.path
        environment["TRANSFORMERS_CACHE"] = effectiveHubCache.path
        environment["NUMBA_CACHE_DIR"] = numbaCache.path
        environment["MPLCONFIGDIR"] = matplotlibCache.path
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }
}

private struct VoiceRuntime {
    let engine: String
    let python: URL
    let script: URL
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
