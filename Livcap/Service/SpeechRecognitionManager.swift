//
//  SpeechRecognitionManager.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/24/25.
//

import Foundation
import Speech
import AVFoundation
import Combine
import os.log

// MARK: - Speech Events

enum SpeechEvent: Sendable {
    case transcriptionUpdate(String)
    case sentenceFinalized(String)
    case statusChanged(String)
    case error(Error)
}

// MARK: - SpeechRecognitionManager

final class SpeechRecognitionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isRecording = false
    @Published var currentTranscription: String = ""
    @Published var captionHistory: [CaptionEntry] = []
    @Published var statusText: String = "Ready to record"
    @Published var selectedLocale: Locale = Locale.current
    
    // MARK: - Private Properties
    
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    // Text processing state
    private var processedTextLength: Int = 0
    private var fullTranscriptionText: String = ""
    private var currentSpeechRecognizer: SFSpeechRecognizer?
    
    // Frame-based silence detection
    private var consecutiveSilenceFrames: Int = 0
    private let silenceFrameThreshold: Int = 8  // ~1.0s (8 frames × 128ms roughly, depends on VAD config, but adjusted down from 10)
    private var currentSpeechState: Bool = false
    
    // AsyncStream for events
    private var speechEventsContinuation: AsyncStream<SpeechEvent>.Continuation?
    private var speechEventsStream: AsyncStream<SpeechEvent>?
    
    // Logging
    private var isLoggerOn: Bool = false // change to true for debugging
    private let logger = Logger(subsystem: "com.livcap.speech", category: "SpeechRecognitionManager")

    // Session rotation
    private var sessionStartTime: Date?
    private var sessionRotationTask: Task<Void, Never>?
    private let maxTaskDuration: TimeInterval = 300 // seconds (5 minutes)
    
    // MARK: - Initialization
    
    init() {
        setupSpeechRecognition()
    }
    
    deinit {
        stopRecording()
        speechEventsContinuation?.finish()
    }
    
    // MARK: - AsyncStream Interface
    
    func speechEvents() -> AsyncStream<SpeechEvent> {
        if let stream = speechEventsStream {
            return stream
        }
        
        speechEventsStream = AsyncStream { continuation in
            self.speechEventsContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.logger.info("🛑 Speech events stream terminated")
            }
        }
        
        return speechEventsStream!
    }
    
    // MARK: - Setup
    
    private func setupSpeechRecognition() {
        // Request authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            
            Task { @MainActor in
                let status: String
                switch authStatus {
                case .authorized:
                    status = "Ready to record"
                case .denied:
                    status = "Speech recognition permission denied"
                case .restricted:
                    status = "Speech recognition restricted"
                case .notDetermined:
                    status = "Speech recognition not determined"
                @unknown default:
                    status = "Speech recognition authorization unknown"
                }
                
                self.statusText = status
                self.speechEventsContinuation?.yield(.statusChanged(status))
            }
        }
    }
    
    // MARK: - Public Interface
    
    func startRecording() async throws {
        guard let recognizer = SFSpeechRecognizer(locale: selectedLocale), recognizer.isAvailable else {
            let error = SpeechRecognitionError.recognizerNotAvailable
            await updateStatus("Speech recognizer not available")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let error = SpeechRecognitionError.notAuthorized
            await updateStatus("Speech recognition not authorized")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        logger.info("🔴 STARTING SPEECH RECOGNITION ENGINE")
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create initial recognition session
        await MainActor.run {
            self.startNewSession()
        }
        
        await MainActor.run {
            self.isRecording = true
            self.currentTranscription = ""
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        currentSpeechState = false
        consecutiveSilenceFrames = 0
        
        // Start session rotation watchdog
        startRotationWatchdog()
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STARTED with locale: \(self.selectedLocale.identifier)")
    }
    
    func updateLocale(_ locale: Locale) {
        Task { @MainActor in
            guard self.selectedLocale != locale else { return }
            self.selectedLocale = locale
            self.logger.info("🌐 Locale updated to: \(locale.identifier)")
            
            if self.isRecording {
                self.rotateSession(reason: "locale-change", finalizeCurrent: true)
            }
        }
    }
    
    func stopRecording() {
        logger.info("⏹️ STOPPING SPEECH RECOGNITION ENGINE")
        
        guard isRecording else { return }
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Stop rotation timer
        sessionRotationTask?.cancel()
        sessionRotationTask = nil
        sessionStartTime = nil
        
        Task { @MainActor in
            self.isRecording = false
            
            // Add final transcription to history if not empty
            if !self.currentTranscription.isEmpty {
                self.addToHistory(self.currentTranscription)
                self.speechEventsContinuation?.yield(.sentenceFinalized(self.currentTranscription))
                self.currentTranscription = ""
            }
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        consecutiveSilenceFrames = 0
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STOPPED")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.append(buffer)
    }

    func appendAudioBufferWithVAD(_ audioFrame: AudioFrameWithVAD) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }

        // Log frame info before appending buffer
        if isLoggerOn {
            
            let sourceString = audioFrame.source.rawValue.uppercased()
            let vadValue = audioFrame.vadResult.rmsEnergy
            let isSpeechString = audioFrame.isSpeech ? "SPEECH" : "SILENCE"
            logger.info("(\(sourceString) Frame \(audioFrame.frameIndex) - VAD RMS: \(vadValue), State: \(isSpeechString)")
        }
        recognitionRequest.append(audioFrame.buffer)
        
        // Frame-based silence detection
        if audioFrame.isSpeech {
            consecutiveSilenceFrames = 0
            onSpeechStart()
        } else {
            consecutiveSilenceFrames += 1
            
            if consecutiveSilenceFrames == 1 {
                onSpeechEnd()
            } else if consecutiveSilenceFrames == silenceFrameThreshold {
                // ~1 second of silence - create new line!
                logger.info("⏰ Silence threshold reached - Creating new caption line")
                Task {
                    await finalizeSentence()
                }
                consecutiveSilenceFrames = 0  // Reset counter
            }
        }
    }
    
    func onSpeechStart() {
        currentSpeechState = true
    }
    
    func onSpeechEnd() {
        currentSpeechState = false
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func updateStatus(_ status: String) {
        statusText = status
        speechEventsContinuation?.yield(.statusChanged(status))
    }
    
    @MainActor
    private func processTranscriptionResult(_ transcription: String) {
        // Store the full transcription from SFSpeechRecognizer
        let previousFullLength = fullTranscriptionText.count
        fullTranscriptionText = transcription
        
        // Extract only the NEW part that hasn't been processed yet
        let newPart = extractNewTranscriptionPart(from: transcription)
        currentTranscription = newPart
        
        // Notify via AsyncStream
        speechEventsContinuation?.yield(.transcriptionUpdate(newPart))
        
        // Reset silence counter if new text was added during silence
        if transcription.count > previousFullLength && !currentSpeechState {
            consecutiveSilenceFrames = 0
        }

        // Emergency break for very long sentences without silence
        if currentTranscription.count > 250 {
            logger.info("📏 Max sentence length reached - Finalizing")
            finalizeSentence()
        }
    }
    
    // MARK: - Session Management (Concise)
    
    @MainActor
    private func startNewSession() {
        let recognizer = SFSpeechRecognizer(locale: selectedLocale)
        guard let speechRecognizer = recognizer, speechRecognizer.isAvailable else {
            logger.error("❌ Cannot start session: recognizer unavailable for \(self.selectedLocale.identifier)")
            return
        }
        self.currentSpeechRecognizer = speechRecognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        // Enable auto-punctuation if available (iOS 13+/macOS 10.15+)
        if #available(macOS 14.0, iOS 13.0, *) {
            request.addsPunctuation = true
        }
        
        recognitionRequest = request
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let error = error {
                    self.updateStatus("Recognition error: \(error.localizedDescription)")
                    self.speechEventsContinuation?.yield(.error(error))
                    return
                }
                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    self.processTranscriptionResult(transcription)
                }
            }
        }
        sessionStartTime = Date()
        logger.info("♻️ Session started")
    }
    
    @MainActor
    private func stopCurrentSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        sessionStartTime = nil
    }
    
    private func rotateSession(reason: String, finalizeCurrent: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.logger.info("♻️ Rotate session (reason=\(reason))")
            if finalizeCurrent { self.finalizeSentence() }
            self.stopCurrentSession()
            self.processedTextLength = 0
            self.fullTranscriptionText = ""
            self.currentTranscription = ""
            self.startNewSession()
        }
    }
    
    private func startRotationWatchdog() {
        sessionRotationTask?.cancel()
        sessionRotationTask = Task { [weak self] in
            let checkIntervalNs: UInt64 = 5_000_000_000
            while let self = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkIntervalNs)
                guard self.isRecording, let start = self.sessionStartTime else { continue }
                if Date().timeIntervalSince(start) >= self.maxTaskDuration {
                    self.rotateSession(reason: "max-duration", finalizeCurrent: false)
                }
            }
        }
    }

    private func extractNewTranscriptionPart(from fullText: String) -> String {
        // Extract only the part that hasn't been processed yet
        if fullText.count > processedTextLength {
            let startIndex = fullText.index(fullText.startIndex, offsetBy: processedTextLength)
            var newPart = String(fullText[startIndex...])
            
            // Clean up leading punctuation or spaces that might be artifacts of splicing
            newPart = newPart.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // If the first char is a comma or period and we have no current text, it might belong to previous
            // But usually SFSpeech handles this well.
            
            return newPart
        }
        return ""
    }
    
    @MainActor
    private func finalizeSentence() {
        if !currentTranscription.isEmpty {
            var textToFinalize = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Ensure sentence ends with punctuation
            let lastChar = textToFinalize.last
            let punctuationSet: Set<Character> = [".", "?", "!", ",", ";", ":"]
            if let last = lastChar, !punctuationSet.contains(last) {
                textToFinalize.append(".")
            }
            
            logger.info("📝 FINALIZING SENTENCE: \(textToFinalize)")
            
            // Add the current sentence part to history
            addToHistory(textToFinalize)
            
            // Notify via AsyncStream - this triggers UI to create new line!
            speechEventsContinuation?.yield(.sentenceFinalized(textToFinalize))
            
            // Update processed length to include what we just added
            processedTextLength = fullTranscriptionText.count
            
            // Clear current transcription for next sentence
            currentTranscription = ""
            
            // Rotate session after a silence-based finalization to bound internal state
            rotateSession(reason: "silence-window", finalizeCurrent: false)
        }
    }
    
    @MainActor
    private func addToHistory(_ text: String) {
        let entry = CaptionEntry(
            id: UUID(),
            text: text,
            confidence: 1.0 // SFSpeechRecognizer doesn't provide confidence scores
        )
        captionHistory.append(entry)
        
        // Keep only last 50 entries to prevent memory issues
        if captionHistory.count > 50 {
            captionHistory.removeFirst()
        }
        
        logger.info("📝 Added to history: \(text)")
    }
    
    // MARK: - Public Utility Methods
    
    func clearCaptions() {
        Task { @MainActor in
            // Treat everything recognized so far as processed so it doesn't resurface
            let clearedLength = self.fullTranscriptionText.count
            self.processedTextLength = clearedLength
            self.fullTranscriptionText = ""

            self.captionHistory.removeAll()
            self.currentTranscription = ""
            self.consecutiveSilenceFrames = 0

            // Restart the recognition session when actively recording to drop
            // any buffered text from the current SFSpeech task.
            if self.isRecording {
                self.rotateSession(reason: "manual-clear", finalizeCurrent: false)
            }

            self.logger.info("🗑️ CLEARED ALL CAPTIONS (clearedLength=\(clearedLength))")
        }
    }
    func  updateLastEntryWithTranslation(_ translation: String) {
        Task { @MainActor in
            guard !captionHistory.isEmpty else { return }
            let lastIndex = captionHistory.count - 1
            let entry = captionHistory[lastIndex]
            
            // Create new entry with translation
            let newEntry = CaptionEntry(
                id: entry.id,
                text: entry.text,
                translation: translation,
                confidence: entry.confidence
            )
            
            captionHistory[lastIndex] = newEntry
            logger.info("📝 Updated last entry with translation")
        }
    }
}

// MARK: - Error Types

enum SpeechRecognitionError: Error, LocalizedError {
    case recognizerNotAvailable
    case notAuthorized
    case requestCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .recognizerNotAvailable:
            return "Speech recognizer is not available"
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .requestCreationFailed:
            return "Failed to create speech recognition request"
        }
    }
}
