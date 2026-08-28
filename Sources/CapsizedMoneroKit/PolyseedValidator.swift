// SPDX-License-Identifier: MIT
import Foundation
import CPolyseed

public enum PolyseedValidationError: Equatable {
    case invalidWordCount
    case invalidWords
    case checksumMismatch
    case unsupportedFeatures
    case otherError(String)
}

public struct PolyseedValidationResult {
    public let isValid: Bool
    public let errors: [PolyseedValidationError]
    public let unrecognizedWords: Set<String>

    public var errorMessage: String? {
        guard !isValid else { return nil }
        return errors.map { error in
            switch error {
            case .invalidWordCount:
                return "Polyseed must be exactly 16 words"
            case .invalidWords:
                return "One or more words are not recognized"
            case .checksumMismatch:
                return "Checksum mismatch — please double-check your seed"
            case .unsupportedFeatures:
                return "Unsupported seed features"
            case .otherError(let message):
                return message
            }
        }.joined(separator: ". ")
    }
}

public struct PolyseedValidator {

    public static func validate(_ phrase: String) -> PolyseedValidationResult {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return PolyseedValidationResult(isValid: false, errors: [.invalidWordCount], unrecognizedWords: [])
        }

        let status = polyseed_validate_phrase(trimmed)

        if status == POLYSEED_VALID {
            return PolyseedValidationResult(isValid: true, errors: [], unrecognizedWords: [])
        }

        let error: PolyseedValidationError
        var badWords: Set<String> = []

        switch status {
        case POLYSEED_INVALID_NUM_WORDS:
            error = .invalidWordCount
        case POLYSEED_INVALID_LANG:
            error = .invalidWords
            // Check each word individually against all polyseed languages
            let words = trimmed.split(separator: " ").map(String.init)
            for word in words {
                if polyseed_word_is_valid(word) == 0 {
                    badWords.insert(word)
                }
            }
        case POLYSEED_INVALID_CHECKSUM:
            error = .checksumMismatch
        case POLYSEED_INVALID_UNSUPPORTED:
            error = .unsupportedFeatures
        default:
            let msg = String(cString: polyseed_status_message(status))
            error = .otherError(msg)
        }

        return PolyseedValidationResult(isValid: false, errors: [error], unrecognizedWords: badWords)
    }
}
