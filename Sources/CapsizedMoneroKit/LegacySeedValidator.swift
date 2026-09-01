// SPDX-License-Identifier: MIT
import Foundation

public enum LegacySeedValidationError: Equatable {
    case invalidWordCount
    case invalidWords(String)
    case checksumMismatch
}

public struct LegacySeedValidationResult {
    public let isValid: Bool
    public let errors: [LegacySeedValidationError]
    public let unrecognizedWords: Set<String>

    public var errorMessage: String? {
        guard !isValid else { return nil }
        return errors.map { error in
            switch error {
            case .invalidWordCount:
                return "Legacy seed must be exactly 25 words"
            case .invalidWords(let word):
                return "Unrecognized word: \"\(word)\""
            case .checksumMismatch:
                return "Checksum mismatch — please double-check your seed"
            }
        }.joined(separator: ". ")
    }
}

public struct LegacySeedValidator {

    // MARK: - Language Registry

    private struct Language {
        let name: String
        let uniquePrefixLength: Int
        let words: [String]
        let wordSet: Set<String>

        init(name: String, uniquePrefixLength: Int, words: [String]) {
            self.name = name
            self.uniquePrefixLength = uniquePrefixLength
            self.words = words
            self.wordSet = Set(words.map { $0.lowercased() })
        }
    }

    private static let supportedLanguages: [Language] = [
        Language(name: "English", uniquePrefixLength: 3, words: englishWords),
        Language(name: "French", uniquePrefixLength: 4, words: frenchWords),
        Language(name: "Spanish", uniquePrefixLength: 4, words: spanishWords),
        Language(name: "German", uniquePrefixLength: 4, words: germanWords),
        Language(name: "Italian", uniquePrefixLength: 4, words: italianWords),
        Language(name: "Dutch", uniquePrefixLength: 4, words: dutchWords),
        Language(name: "Portuguese", uniquePrefixLength: 4, words: portugueseWords),
        Language(name: "Russian", uniquePrefixLength: 4, words: russianWords),
        Language(name: "Japanese", uniquePrefixLength: 3, words: japaneseWords),
        Language(name: "Chinese Simplified", uniquePrefixLength: 1, words: chineseSimplifiedWords),
        Language(name: "Esperanto", uniquePrefixLength: 4, words: esperantoWords),
        Language(name: "Lojban", uniquePrefixLength: 4, words: lojbanWords),
    ]

    // MARK: - Validation

    public static func validate(_ phrase: String) -> LegacySeedValidationResult {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return LegacySeedValidationResult(isValid: false, errors: [.invalidWordCount], unrecognizedWords: [])
        }

        let words = trimmed.split(separator: " ").map(String.init)

        // Step 1: Check word count
        guard words.count == 25 else {
            return LegacySeedValidationResult(isValid: false, errors: [.invalidWordCount], unrecognizedWords: [])
        }

        // Step 2: Auto-detect language — all 25 words must be in one language's wordset
        let matchedLanguage = supportedLanguages.first { lang in
            words.allSatisfy { lang.wordSet.contains($0) }
        }

        guard let language = matchedLanguage else {
            // Collect all words not recognized by any language
            let badWords = Set(words.filter { word in
                !supportedLanguages.contains { $0.wordSet.contains(word) }
            })
            let firstBad = words.first { badWords.contains($0) }
            return LegacySeedValidationResult(isValid: false, errors: [.invalidWords(firstBad ?? words[0])], unrecognizedWords: badWords)
        }

        // Step 3: Verify CRC32 checksum using the matched language's prefix length
        let dataWords = Array(words.prefix(24))
        let prefixes = dataWords.map { word -> String in
            if word.count > language.uniquePrefixLength {
                return String(word.prefix(language.uniquePrefixLength))
            }
            return word
        }
        let joined = prefixes.joined()
        let bytes = Array(joined.utf8)
        let checksum = crc32(bytes)
        let checksumIndex = Int(checksum % 24)

        guard words[24] == dataWords[checksumIndex] else {
            return LegacySeedValidationResult(isValid: false, errors: [.checksumMismatch], unrecognizedWords: [])
        }

        return LegacySeedValidationResult(isValid: true, errors: [], unrecognizedWords: [])
    }

    // MARK: - CRC32

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
