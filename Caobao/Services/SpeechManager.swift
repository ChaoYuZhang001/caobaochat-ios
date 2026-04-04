import Foundation
import Speech
import AVFoundation

#if os(iOS)
// MARK: - Speech Manager
class SpeechManager: NSObject {
    static let shared = SpeechManager()
    
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    
    private override init() {
        super.init()
    }
    
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                print("✅ 语音识别授权成功")
            case .denied:
                print("❌ 语音识别授权被拒绝")
            case .restricted:
                print("❌ 语音识别受限")
            case .notDetermined:
                print("❓ 语音识别授权未确定")
            @unknown default:
                break
            }
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print(granted ? "✅ 麦克风授权成功" : "❌ 麦克风授权被拒绝")
        }
    }
    
    func startRecording(completion: @escaping (Result<String, Error>) -> Void) {
        // 检查授权
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            SFSpeechRecognizer.requestAuthorization { _ in }
            completion(.failure(SpeechError.notAuthorized))
            return
        }
        
        // 停止之前的任务
        stopRecording()
        
        // 创建音频引擎
        audioEngine = AVAudioEngine()
        
        // 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let audioEngine = audioEngine,
              let recognitionRequest = recognitionRequest else {
            completion(.failure(SpeechError.setupFailed))
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // 配置音频会话
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        
        // 开始识别任务
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                if result.isFinal {
                    completion(.success(transcript))
                }
            }
            
            if let error = error {
                completion(.failure(error))
            }
        }
        
        // 配置音频输入
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        // 启动音频引擎
        do {
            try audioEngine.start()
        } catch {
            completion(.failure(error))
        }
        
        // 5秒后自动停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.stopRecording()
        }
    }
    
    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Speech Error
enum SpeechError: Error, LocalizedError {
    case notAuthorized
    case setupFailed
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "语音识别未授权"
        case .setupFailed:
            return "语音识别初始化失败"
        }
    }
}
#endif
