/* Thin C wrapper around libpolyseed for seed phrase validation */

#ifndef POLYSEED_VALIDATE_H
#define POLYSEED_VALIDATE_H

/* Validation status codes (mirrors polyseed_status) */
#define POLYSEED_VALID 0
#define POLYSEED_INVALID_NUM_WORDS 1
#define POLYSEED_INVALID_LANG 2
#define POLYSEED_INVALID_CHECKSUM 3
#define POLYSEED_INVALID_UNSUPPORTED 4
#define POLYSEED_INVALID_FORMAT 5
#define POLYSEED_INVALID_MEMORY 6
#define POLYSEED_INVALID_MULT_LANG 7

/**
 * Validates a polyseed mnemonic phrase for Monero.
 * Checks word count, wordlist membership across all 10 languages,
 * and the Reed-Solomon checksum.
 *
 * @param phrase the mnemonic phrase as a C string.
 * @return 0 if valid, or one of the POLYSEED_INVALID_* error codes.
 */
int polyseed_validate_phrase(const char* phrase);

/**
 * Returns a human-readable error message for a validation status code.
 *
 * @param status the status code returned by polyseed_validate_phrase.
 * @return a static string describing the error, or "Valid" for status 0.
 */
const char* polyseed_status_message(int status);

/**
 * Checks if a word exists in any of the 10 polyseed language wordlists.
 *
 * @param word the word to check as a C string.
 * @return 1 if the word is found in at least one language, 0 otherwise.
 */
int polyseed_word_is_valid(const char* word);

#endif
