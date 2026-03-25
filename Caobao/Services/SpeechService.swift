import Foundation
import Speech
import AVFoundation

// MARK: - Speech Service (ASR + TTS)
/// 语音服务：支持语音识别(ASR)和语音合成(TTS)
class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()
    
    // MARK: - Published Properties
    @Published var isRecording: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var recognizedText: String = ""
    @Published var error: String?
    
    // MARK: - Private Properties
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechSynthesizer: AVSpeechSynthesizer?
    
    // MARK: - Callbacks
    private var onRecordingEnd: ((String) -> Void)?
    
    // MARK: - Initialization
    private override init() {
        super.init()
        
        // 初始化语音识别器（中文）
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        
        // 初始化语音合成器
        speechSynthesizer = AVSpeechSynthesizer()
        speechSynthesizer?.delegate = self
        
        // 初始化音频引擎
        audioEngine = AVAudioEngine()
    }
    
    // MARK: - Permission Check
    /// 检查语音识别权限
    func checkAuthorization() -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .authorized
    }
    
    /// 请求语音识别权限
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    /// 检查麦克风权限
    func checkMicrophonePermission() -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission
        return status == .granted
    }
    
    /// 请求麦克风权限
    func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Speech Recognition (ASR)
    /// 开始录音识别
    func startRecording(onResult: @escaping (String) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "语音识别不可用"
            return
        }
        
        // 检查权限
        guard checkAuthorization() else {
            Task {
                let authorized = await requestAuthorization()
                if !authorized {
                    await MainActor.run {
                        self.error = "请授权语音识别权限"
                    }
                    return
                }
                // 授权成功后继续
                await MainActor.run {
                    self.startRecordingInternal(onResult: onResult)
                }
            }
            return
        }
        
        guard checkMicrophonePermission() else {
            Task {
                let authorized = await requestMicrophonePermission()
                if !authorized {
                    await MainActor.run {
                        self.error = "请授权麦克风权限"
                    }
                    return
                }
                await MainActor.run {
                    self.startRecordingInternal(onResult: onResult)
                }
            }
            return
        }
        
        startRecordingInternal(onResult: onResult)
    }
    
    private func startRecordingInternal(onResult: @escaping (String) -> Void) {
        // 停止之前的任务
        stopRecording()
        
        onRecordingEnd = onResult
        recognizedText = ""
        isRecording = true
        error = nil
        
        // 配置音频会话
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "音频配置失败: \(error.localizedDescription)"
            isRecording = false
            return
        }
        
        // 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            self.error = "无法创建识别请求"
            isRecording = false
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // 开始识别任务
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                DispatchQueue.main.async {
                    self.recognizedText = result.bestTranscription.formattedString
                }
                
                // 识别完成
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.stopRecording()
                        self.onRecordingEnd?(self.recognizedText)
                    }
                }
            }
            
            if error != nil {
                DispatchQueue.main.async {
                    self.stopRecording()
                    // 如果有识别到的文本，仍然返回
                    if !self.recognizedText.isEmpty {
                        self.onRecordingEnd?(self.recognizedText)
                    } else {
                        self.error = "识别失败"
                    }
                }
            }
        }
        
        // 配置音频输入
        let inputNode = audioEngine?.inputNode
        let recordingFormat = inputNode?.outputFormat(forBus: 0)
        
        inputNode?.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        // 启动音频引擎
        audioEngine?.prepare()
        do {
            try audioEngine?.start()
        } catch {
            self.error = "音频引擎启动失败"
            isRecording = false
        }
    }
    
    /// 停止录音
    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        
        // 恢复音频会话
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    // MARK: - Text to Speech (TTS)
    /// 朗读文本
    func speak(_ text: String, language: String = "zh-CN") {
        // 停止当前朗读
        stopSpeaking()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        speechSynthesizer?.speak(utterance)
        isSpeaking = true
    }
    
    /// 停止朗读
    func stopSpeaking() {
        speechSynthesizer?.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
    
    /// 暂停朗读
    func pauseSpeaking() {
        speechSynthesizer?.pauseSpeaking(at: .immediate)
        isSpeaking = false
    }
    
    /// 继续朗读
    func continueSpeaking() {
        speechSynthesizer?.continueSpeaking()
        isSpeaking = true
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension SpeechService {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
}
