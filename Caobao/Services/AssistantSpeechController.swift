#if os(iOS)
import Foundation
import Combine
import UIKit
import AVFoundation
import Speech

/// Native, user-initiated dictation and read-aloud. No permission requests or
/// audio-session activation occur when the singleton is constructed.
@MainActor
final class AssistantSpeechController: NSObject, ObservableObject {
    static let shared = AssistantSpeechController()

    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript = ""

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var audioSessionActive = false
    private var generation: UInt64 = 0
    private var dictationOwnerId: String?
    private var onTranscript: ((String) -> Void)?
    private var maximumDurationTask: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var speakingOwnerId: String?
    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            guard rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.handleInterruption() }
        })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInterruption() }
        })
        for name in ["logoutSuccess", "loginSuccess"] {
            notificationObservers.append(center.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancel() }
            })
        }
    }

    func startDictation(
        localeIdentifier: String,
        ownerId: String,
        onTranscript: @escaping (String) -> Void
    ) async {
        cancel()
        guard !ownerId.isEmpty, ownerId == currentOwnerId else {
            errorMessage = AssistantLocalization.string("账号已切换，请重新开始语音输入")
            return
        }
        let operation = generation
        dictationOwnerId = ownerId
        isRequestingPermission = true
        defer {
            if operation == generation { isRequestingPermission = false }
        }

        let speechStatus = await requestSpeechAuthorization()
        guard isCurrent(operation, ownerId: ownerId) else { return }
        guard speechStatus == .authorized else {
            failDictation(AssistantLocalization.string("请在系统设置中允许语音识别权限"))
            return
        }
        let microphoneAllowed = await requestMicrophoneAuthorization()
        guard isCurrent(operation, ownerId: ownerId) else { return }
        guard microphoneAllowed else {
            failDictation(AssistantLocalization.string("请在系统设置中允许麦克风权限"))
            return
        }

        let locale = Locale(identifier: localeIdentifier.isEmpty ? Locale.current.identifier : localeIdentifier)
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale), speechRecognizer.isAvailable else {
            failDictation(AssistantLocalization.string("当前语言的语音识别暂不可用，请稍后重试"))
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
            audioSessionActive = true
            guard session.isInputAvailable else {
                failDictation(AssistantLocalization.string("未找到可用的麦克风"))
                return
            }

            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                failDictation(AssistantLocalization.string("麦克风音频格式不可用，请重试"))
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if speechRecognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            recognitionRequest = request
            recognizer = speechRecognizer
            speechRecognizer.delegate = self
            self.onTranscript = onTranscript

            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRequestingPermission = false
            isRecording = true

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                let recognizedText = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                    if let recognizedText, !recognizedText.isEmpty, recognizedText != self.transcript {
                        self.transcript = recognizedText
                        self.onTranscript?(recognizedText)
                    }
                    // Client code may synchronously cancel from onTranscript.
                    guard self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                    if isFinal {
                        self.stopDictation()
                    } else if failed {
                        self.failDictation(AssistantLocalization.string("语音识别已中断，已保留识别到的内容"))
                    }
                }
            }
            maximumDurationTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self, self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                self.stopDictation()
                self.errorMessage = AssistantLocalization.string("语音输入已达到 60 秒，已保留识别到的内容")
            }
        } catch {
            guard isCurrent(operation, ownerId: ownerId) else { return }
            failDictation(AssistantLocalization.string("无法启动麦克风，请检查音频设备并重试"))
        }
    }

    /// Ends the recording while retaining the last real partial transcription.
    func stopDictation() {
        generation &+= 1
        isRequestingPermission = false
        isRecording = false
        dictationOwnerId = nil
        onTranscript = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.reset()
        }
        tapInstalled = false
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer?.delegate = nil
        recognizer = nil
        audioEngine = nil
        deactivateSessionIfIdle()
    }

    /// Invalidate permission continuations, recognition callbacks and speech.
    /// Unlike stopDictation, cancellation discards the controller's transient text.
    func cancel() {
        stopDictation()
        stopSpeaking()
        transcript = ""
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func speak(text: String, localeIdentifier: String) {
        guard !isRecording, !isRequestingPermission else {
            errorMessage = AssistantLocalization.string("请先停止语音输入再朗读")
            return
        }
        stopSpeaking()
        errorMessage = nil
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard content.count <= 8_000 else {
            errorMessage = AssistantLocalization.string("朗读最多支持 8000 字，请选取较短内容")
            return
        }
        let language = (localeIdentifier.isEmpty ? Locale.current.identifier : localeIdentifier)
            .replacingOccurrences(of: "_", with: "-")
        let languagePrefix = language.split(separator: "-").first.map(String.init) ?? language
        guard let voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.language.lowercased().split(separator: "-").first.map(String.init) == languagePrefix.lowercased()
            }) else {
            errorMessage = AssistantLocalization.string("当前语言没有可用的系统朗读声音")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true, options: [])
            audioSessionActive = true
            let utterance = AVSpeechUtterance(string: content)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            currentUtterance = utterance
            speakingOwnerId = currentOwnerId
            isSpeaking = true
            synthesizer.speak(utterance)
        } catch {
            currentUtterance = nil
            speakingOwnerId = nil
            isSpeaking = false
            deactivateSessionIfIdle()
            errorMessage = AssistantLocalization.string("无法启动系统朗读，请稍后重试")
        }
    }

    func stopSpeaking() {
        currentUtterance = nil
        speakingOwnerId = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSessionIfIdle()
    }

    private var currentOwnerId: String { AuthService.shared.user?.id ?? "local-device" }

    private func isCurrent(_ operation: UInt64, ownerId: String) -> Bool {
        operation == generation && dictationOwnerId == ownerId && currentOwnerId == ownerId
    }

    private func failDictation(_ message: String) {
        stopDictation()
        errorMessage = message
    }

    private func handleInterruption() {
        let wasDictating = isRecording || isRequestingPermission
        stopDictation()
        stopSpeaking()
        if wasDictating { errorMessage = AssistantLocalization.string("语音输入已被系统中断，已保留识别到的内容") }
    }

    private func deactivateSessionIfIdle() {
        guard audioSessionActive, !isRecording, !isSpeaking else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        } catch {
            if errorMessage == nil { errorMessage = AssistantLocalization.string("无法结束音频会话，请重试") }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

extension AssistantSpeechController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        Task { @MainActor [weak self, weak speechRecognizer] in
            guard let self, let speechRecognizer, self.recognizer === speechRecognizer, self.isRecording else { return }
            self.failDictation(AssistantLocalization.string("语音识别服务暂不可用，已保留识别到的内容"))
        }
    }
}

extension AssistantSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }

    private func finishSpeaking(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        guard speakingOwnerId == currentOwnerId else { cancel(); return }
        currentUtterance = nil
        speakingOwnerId = nil
        isSpeaking = false
        deactivateSessionIfIdle()
    }
}
#else
import Foundation
import Combine
import AppKit
import AVFoundation
import Speech

/// Native, user-initiated macOS dictation and read-aloud. macOS does not use
/// AVAudioSession; AVAudioEngine owns the input graph and privacy prompts are
/// requested only after the user taps the microphone button.
@MainActor
final class AssistantSpeechController: NSObject, ObservableObject {
    static let shared = AssistantSpeechController()

    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript = ""

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var generation: UInt64 = 0
    private var dictationOwnerId: String?
    private var onTranscript: ((String) -> Void)?
    private var maximumDurationTask: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var speakingOwnerId: String?
    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        for name in ["logoutSuccess", "loginSuccess"] {
            notificationObservers.append(center.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancel() }
            })
        }
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInterruption() }
        })
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        maximumDurationTask?.cancel()
    }

    func cancel() {
        stopDictation()
        stopSpeaking()
        transcript = ""
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func stopDictation() {
        generation &+= 1
        isRequestingPermission = false
        isRecording = false
        dictationOwnerId = nil
        onTranscript = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.reset()
        }
        tapInstalled = false
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer?.delegate = nil
        recognizer = nil
        audioEngine = nil
    }

    func stopSpeaking() {
        currentUtterance = nil
        speakingOwnerId = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speak(text: String, localeIdentifier: String) {
        guard !isRecording, !isRequestingPermission else {
            errorMessage = AssistantLocalization.string("请先停止语音输入再朗读")
            return
        }
        stopSpeaking()
        errorMessage = nil
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard content.count <= 8_000 else {
            errorMessage = AssistantLocalization.string("朗读最多支持 8000 字，请选取较短内容")
            return
        }
        let language = (localeIdentifier.isEmpty ? Locale.current.identifier : localeIdentifier)
            .replacingOccurrences(of: "_", with: "-")
        let languagePrefix = language.split(separator: "-").first.map(String.init) ?? language
        guard let voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.language.lowercased().split(separator: "-").first.map(String.init) == languagePrefix.lowercased()
            }) else {
            errorMessage = AssistantLocalization.string("当前语言没有可用的系统朗读声音")
            return
        }
        let utterance = AVSpeechUtterance(string: content)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        speakingOwnerId = currentOwnerId
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func startDictation(
        localeIdentifier: String,
        ownerId: String,
        onTranscript: @escaping (String) -> Void
    ) async {
        cancel()
        guard !ownerId.isEmpty, ownerId == currentOwnerId else {
            errorMessage = AssistantLocalization.string("账号已切换，请重新开始语音输入")
            return
        }
        let operation = generation
        dictationOwnerId = ownerId
        isRequestingPermission = true
        defer {
            if operation == generation { isRequestingPermission = false }
        }

        let speechStatus = await requestSpeechAuthorization()
        guard isCurrent(operation, ownerId: ownerId) else { return }
        guard speechStatus == .authorized else {
            failDictation(AssistantLocalization.string("请在系统设置中允许语音识别权限"))
            return
        }
        let microphoneAllowed = await requestMicrophoneAuthorization()
        guard isCurrent(operation, ownerId: ownerId) else { return }
        guard microphoneAllowed else {
            failDictation(AssistantLocalization.string("请在系统设置中允许麦克风权限"))
            return
        }

        let locale = Locale(identifier: localeIdentifier.isEmpty ? Locale.current.identifier : localeIdentifier)
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale), speechRecognizer.isAvailable else {
            failDictation(AssistantLocalization.string("当前语言的语音识别暂不可用，请稍后重试"))
            return
        }

        do {
            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                failDictation(AssistantLocalization.string("麦克风音频格式不可用，请重试"))
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if speechRecognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            recognitionRequest = request
            recognizer = speechRecognizer
            speechRecognizer.delegate = self
            self.onTranscript = onTranscript
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRequestingPermission = false
            isRecording = true
            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                let recognizedText = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                    if let recognizedText, !recognizedText.isEmpty, recognizedText != self.transcript {
                        self.transcript = recognizedText
                        self.onTranscript?(recognizedText)
                    }
                    guard self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                    if isFinal {
                        self.stopDictation()
                    } else if failed {
                        self.failDictation(AssistantLocalization.string("语音识别已中断，已保留识别到的内容"))
                    }
                }
            }
            maximumDurationTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self, self.isCurrent(operation, ownerId: ownerId), self.isRecording else { return }
                self.stopDictation()
                self.errorMessage = AssistantLocalization.string("语音输入已达到 60 秒，已保留识别到的内容")
            }
        } catch {
            guard isCurrent(operation, ownerId: ownerId) else { return }
            failDictation(AssistantLocalization.string("无法启动麦克风，请检查音频设备并重试"))
        }
    }

    private var currentOwnerId: String { AuthService.shared.user?.id ?? "local-device" }

    private func isCurrent(_ operation: UInt64, ownerId: String) -> Bool {
        operation == generation && dictationOwnerId == ownerId && currentOwnerId == ownerId
    }

    private func failDictation(_ message: String) {
        stopDictation()
        errorMessage = message
    }

    private func handleInterruption() {
        let wasDictating = isRecording || isRequestingPermission
        stopDictation()
        stopSpeaking()
        if wasDictating { errorMessage = AssistantLocalization.string("语音输入已被系统中断，已保留识别到的内容") }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

extension AssistantSpeechController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        Task { @MainActor [weak self, weak speechRecognizer] in
            guard let self, let speechRecognizer, self.recognizer === speechRecognizer, self.isRecording else { return }
            self.failDictation(AssistantLocalization.string("语音识别服务暂不可用，已保留识别到的内容"))
        }
    }
}

extension AssistantSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking(utterance) }
    }

    private func finishSpeaking(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        guard speakingOwnerId == currentOwnerId else { cancel(); return }
        currentUtterance = nil
        speakingOwnerId = nil
        isSpeaking = false
    }
}
#endif
