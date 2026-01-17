//
//  CaptionViewModel.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/9/25.
//
// CaptionViewmodel is conductor role in the caption view for the main function
//

import Foundation
import Combine
import Speech
import AVFoundation
import AVFoundation
import Accelerate
import os.log
import Translation

protocol CaptionViewModelProtocol: ObservableObject {
    var captionHistory: [CaptionEntry] { get }
    var currentTranscription: String { get }
    var currentTranslation: String { get }
    var isLiveTranslationEnabled: Bool { get }
    func pauseRecording()
}

/// CaptionViewModel for real-time speech recognition using SFSpeechRecognizer
final class CaptionViewModel: ObservableObject, CaptionViewModelProtocol {
    
    // MARK: - Published Properties for UI
    
    @Published private(set) var isRecording = false
    @Published var statusText: String = "Ready to record"
    @Published var selectedLanguageIdentifier: String = Locale.current.identifier
    
    var supportedLanguages: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }
    
    // Direct boolean flags - simplified approach
    var isMicrophoneEnabled: Bool { audioCoordinator.isMicrophoneEnabled }
    var isSystemAudioEnabled: Bool { audioCoordinator.isSystemAudioEnabled }

    // Forwarded from SpeechProcessor
    var captionHistory: [CaptionEntry] { speechProcessor.captionHistory }
    var currentTranscription: String { speechProcessor.currentTranscription }
    
    // MARK: - Private Properties
    private let audioCoordinator: AudioCoordinator
    private let speechProcessor: SpeechProcessor
    private let permissionManager = PermissionManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    private var audioStreamTask: Task<Void, Never>?
    
    // MARK: - Logging
    private let logger = Logger(subsystem: "com.livcap.audio", category: "CaptionViewModel")
    
    // MARK: - Initialization
    
    init(audioCoordinator: AudioCoordinator = AudioCoordinator(), speechProcessor: SpeechProcessor = SpeechProcessor()) {
        self.audioCoordinator = audioCoordinator
        self.speechProcessor = speechProcessor
        
        // Subscribe to audio coordinator changes and manage recording state
        audioCoordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.manageRecordingState()
                self?.updateStatus()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        // Subscribe to changes from SpeechProcessor
        speechProcessor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        // Subscribe to speech events for translation
        speechProcessor.speechEventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSpeechEventForTranslation(event)
            }
            .store(in: &cancellables)
            
        // Load saved language preference
        if let savedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguageIdentifier") {
            self.selectedLanguageIdentifier = savedLanguage
            // Create a Locale from the identifier to update the processor
            let locale = Locale(identifier: savedLanguage)
            speechProcessor.updateLocale(locale)
        }
        
        // Load saved translation preference
        self.isLiveTranslationEnabled = UserDefaults.standard.bool(forKey: "IsLiveTranslationEnabled")
        self.targetLanguageIdentifier = UserDefaults.standard.string(forKey: "TargetLanguageIdentifier")
    }
    
    // MARK: - Audio Control Methods
    
    private func enableMicrophoneWithPermissionCheck() {
        // Check permissions before enabling microphone
        if permissionManager.hasEssentialPermissionsDenied() {
            logger.warning("🚫 Microphone enable cancelled - essential permissions denied")
            
            // Open system settings for denied permissions
            if permissionManager.isMicrophoneDenied() {
                permissionManager.openSystemSettingsForMicPermission()
            } else if permissionManager.isSpeechRecognitionDenied() {
                permissionManager.openSystemSettingsForSpeechPermission()
            }
            return
        }
        
        logger.info("🎤 Enabling microphone - permissions granted")
        audioCoordinator.enableMicrophone()
    }
    
    func toggleMicrophone() {
        if isMicrophoneEnabled {
            audioCoordinator.disableMicrophone()
        } else {
            enableMicrophoneWithPermissionCheck()
        }
    }
    
    func toggleSystemAudio() {
        if isSystemAudioEnabled {
            audioCoordinator.disableSystemAudio()
        } else {
            audioCoordinator.enableSystemAudio()
        }
    }
    
    // MARK: - Auto Speech Recognition Management
    
    private func manageRecordingState() {
        let shouldBeRecording = self.isMicrophoneEnabled || self.isSystemAudioEnabled
        
        logger.info("🔄 REACTIVE STATE CHECK: mic=\(self.isMicrophoneEnabled), sys=\(self.isSystemAudioEnabled), shouldRecord=\(shouldBeRecording), isRecording=\(self.isRecording)")
        
        if shouldBeRecording && !isRecording {
            startRecording()
        } else if !shouldBeRecording && isRecording {
            stopRecording()
        }
    }
    
    // MARK: - Recording Lifecycle
    
    private func startRecording() {
        guard !isRecording else { return }
        logger.info("🔴 STARTING RECORDING SESSION")
        isRecording = true
        
        // Start the speech processor
        speechProcessor.startProcessing()
        
        // Start consuming the audio stream
        audioStreamTask = Task {
            let stream = audioCoordinator.audioFrameStream()
            for await frame in stream {
                guard self.isRecording else { break }
                speechProcessor.processAudioFrame(frame)
            }
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        logger.info("🛑 STOPPING RECORDING SESSION")
        isRecording = false
        
        // Terminate the audio stream task
        audioStreamTask?.cancel()
        audioStreamTask = nil
        
        // Stop the speech processor
        speechProcessor.stopProcessing()
    }
    
    // Removed: Stream restart handling no longer needed
    
    // MARK: - Helper Functions
    
    func pauseRecording() {
        if isRecording {
            stopRecording()
            // Optional: update status text safely via private method or let observer handle it
            // The existing logic already updates status via audioCoordinator/speechProcessor changes
        }
    }
    
    private func updateStatus() {
        if !isRecording {
            self.statusText = "Ready"
        } else {
            switch (self.isMicrophoneEnabled, self.isSystemAudioEnabled) {
            case (false, false):
                self.statusText = "Ready"
            case (true, false):
                self.statusText = "MIC:ON"
            case (false, true):
                self.statusText = "SYS:ON"
            case (true, true):
                self.statusText = "MIC:ON | SYS:ON"
            }
        }
        logger.info("📊 STATUS UPDATE: \(self.statusText)")
    }

    // MARK: - Public Interface
    
    func clearCaptions() {
        speechProcessor.clearCaptions()
        currentTranslation = "" // Clear translation too
        logger.info("🗑️ CLEARED ALL CAPTIONS")
    }
    
    func selectLanguage(_ locale: Locale) {
        // Validation: If selected language == source language, disable translation
        // But here we are selecting the SOURCE language for recognition
        selectedLanguageIdentifier = locale.identifier
        speechProcessor.updateLocale(locale)
        
        // Save preference
        UserDefaults.standard.set(locale.identifier, forKey: "SelectedLanguageIdentifier")
        
        // If translation is enabled, check if we need to disable it (if source == target)
        if isLiveTranslationEnabled {
            // Logic handled in View or here? For now, keep simple.
        }
    }
    
    // MARK: - Translation Support
    
    @Published var isLiveTranslationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isLiveTranslationEnabled, forKey: "IsLiveTranslationEnabled")
        }
    }
    
    @Published var targetLanguageIdentifier: String? {
        didSet {
            UserDefaults.standard.set(targetLanguageIdentifier, forKey: "TargetLanguageIdentifier")
        }
    }
    
    @Published var currentTranslation: String = ""
    
    // Stream to feed the translation session
    private var translationStreamContinuation: AsyncStream<(String, Bool)>.Continuation?
    
    /// Called by CaptionView when a TranslationSession is available
    @available(macOS 15.0, *)
    func handleTranslationSession(_ session: TranslationSession) async {
        logger.info("🟢 LIVE TRANSLATION SESSION STARTED")
        
        // Create the stream if needed (or just use a new one for this session)
        let stream = AsyncStream<(String, Bool)> { continuation in
            self.translationStreamContinuation = continuation
        }
        
        for await (text, isFinal) in stream {
            guard !Task.isCancelled else { break }
            guard !text.isEmpty else {
                 if isFinal {
                     currentTranslation = ""
                 }
                 continue
            }
            
            do {
                let response = try await session.translate(text)
                await MainActor.run {
                    if isFinal {
                        // Update the history with the final translation
                        self.speechProcessor.updateLastEntryWithTranslation(response.targetText)
                        self.currentTranslation = ""
                    } else {
                        // Update live preview
                        self.currentTranslation = response.targetText
                    }
                }
            } catch {
                logger.error("⚠️ Translation error: \(error.localizedDescription)")
            }
        }
        
        
        logger.info("🔴 LIVE TRANSLATION SESSION ENDED")
    }
    
    private func handleSpeechEventForTranslation(_ event: SpeechEvent) {
        guard isLiveTranslationEnabled, let continuation = translationStreamContinuation else { return }
        
        switch event {
        case .transcriptionUpdate(let text):
            continuation.yield((text, false))
        case .sentenceFinalized(let text):
            continuation.yield((text, true))
        default: break
        }
    }
}
