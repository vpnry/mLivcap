//
//  TranslationManager.swift
//  Livcap
//
//  Created by Auto-Agent on 6/25/25.
//

import Foundation
import Translation
import SwiftUI
import os.log

/// Manages translation logic.
/// Note: The actual TranslationSession must be provided by the View via the `.translationTask` modifier.
@available(macOS 15.0, *)
final class TranslationManager: ObservableObject {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.livcap.translation", category: "TranslationManager")
    
    @Published var isTranslationEnabled: Bool = false
    @Published var targetLocale: Locale?
    
    // MARK: - Public Interface
    
    /// Translates a batch of text using the provided session
    func translate(_ text: String, using session: TranslationSession) async -> String? {
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            logger.error("Translation failed: \(error.localizedDescription)")
            return nil
        }
    }
}
