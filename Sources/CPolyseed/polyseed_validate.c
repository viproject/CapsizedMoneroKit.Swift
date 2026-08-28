/* Thin wrapper around libpolyseed for seed phrase validation */

#include "polyseed_validate.h"
#include "polyseed.h"
#include "lang.h"

#include <string.h>
#include <stdbool.h>
#include <CommonCrypto/CommonKeyDerivation.h>

/* --- Dependency implementations ---
 *
 * IMPORTANT: _polyseed_deps is a common (tentative) symbol that gets merged
 * with the copy inside Monero.xcframework at link time -- there is only ONE
 * shared polyseed_deps global in the final binary.  Injecting a broken
 * implementation here overwrites the xcframework's real one, corrupting all
 * subsequent polyseed operations.  Every field must therefore be safe to
 * leave in polyseed_deps regardless of call order:
 *
 *   randbytes     — real: arc4random_buf (cryptographically secure)
 *                   stub would zero all entropy → same seed every time
 *
 *   pbkdf2_sha256 — real: CommonCrypto (correct spend-key derivation)
 *                   stub would corrupt createWalletFromPolyseed
 *
 *   memzero       — real: memset_s (guaranteed not dead-store-eliminated)
 *                   plain memset may be optimised away, leaving key material
 *                   in heap memory after polyseed_free
 *
 *   u8_nfc        — pass-through is safe: wordlists (lang_*.c) are already
 *                   stored as precomposed NFC u8"…" literals, so the encode
 *                   output is already in NFC before the compose step
 *
 *   u8_nfkd       — pass-through is safe: lang.c normalises both the input
 *                   word and the wordlist entry via UTF8_DECOMPOSE before
 *                   comparing, so neither side is normalised; iOS keyboard
 *                   input is always NFC which equals NFKD for all polyseed
 *                   characters
 */

static void real_randbytes(void* result, size_t n) {
    arc4random_buf(result, n);
}

/* Real PBKDF2-SHA256 via CommonCrypto. */
static void real_pbkdf2(const uint8_t* pw, size_t pwlen,
    const uint8_t* salt, size_t saltlen, uint64_t iterations,
    uint8_t* key, size_t keylen) {
    CCKeyDerivationPBKDF(
        kCCPBKDF2,
        (const char*)pw, pwlen,
        salt, saltlen,
        kCCPRFHmacAlgSHA256,
        (uint32_t)iterations,
        key, keylen
    );
}

/* memset_s is guaranteed not to be optimised away (C11 Annex K). */
static void real_memzero(void* const ptr, const size_t len) {
    memset_s(ptr, len, 0, len);
}

/* Pass-through NFC — safe, see comment above. */
static size_t pass_u8_nfc(const char* str, polyseed_str norm) {
    size_t len = strlen(str);
    if (len >= POLYSEED_STR_SIZE) len = POLYSEED_STR_SIZE - 1;
    memcpy(norm, str, len);
    norm[len] = '\0';
    return len;
}

/* Pass-through NFKD — safe, see comment above. */
static size_t pass_u8_nfkd(const char* str, polyseed_str norm) {
    size_t len = strlen(str);
    if (len >= POLYSEED_STR_SIZE) len = POLYSEED_STR_SIZE - 1;
    memcpy(norm, str, len);
    norm[len] = '\0';
    return len;
}

/* --- Initialization --- */

static bool deps_injected = false;

static void ensure_initialized(void) {
    if (deps_injected) return;

    polyseed_dependency deps;
    memset(&deps, 0, sizeof(deps));
    deps.randbytes = &real_randbytes;
    deps.pbkdf2_sha256 = &real_pbkdf2;
    deps.memzero = &real_memzero;
    deps.u8_nfc = &pass_u8_nfc;
    deps.u8_nfkd = &pass_u8_nfkd;
    /* time, alloc, free default to stdlib in polyseed_inject */

    polyseed_inject(&deps);
    deps_injected = true;
}

/* --- Public API --- */

int polyseed_validate_phrase(const char* phrase) {
    if (phrase == NULL) return POLYSEED_INVALID_FORMAT;

    ensure_initialized();

    const polyseed_lang* lang = NULL;
    polyseed_data* seed = NULL;

    polyseed_status status = polyseed_decode(phrase, POLYSEED_MONERO, &lang, &seed);

    if (status == POLYSEED_OK && seed != NULL) {
        polyseed_free(seed);
    }

    return (int)status;
}

const char* polyseed_status_message(int status) {
    switch (status) {
        case POLYSEED_VALID:             return "Valid";
        case POLYSEED_INVALID_NUM_WORDS: return "Polyseed must be exactly 16 words";
        case POLYSEED_INVALID_LANG:      return "One or more words are not recognized";
        case POLYSEED_INVALID_CHECKSUM:  return "Checksum mismatch — please double-check your seed";
        case POLYSEED_INVALID_UNSUPPORTED: return "Unsupported seed features";
        case POLYSEED_INVALID_FORMAT:    return "Invalid seed format";
        case POLYSEED_INVALID_MEMORY:    return "Memory allocation error";
        case POLYSEED_INVALID_MULT_LANG: return "Phrase matches multiple languages";
        default:                         return "Unknown error";
    }
}

int polyseed_word_is_valid(const char* word) {
    if (word == NULL) return 0;

    ensure_initialized();

    int num_langs = polyseed_get_num_langs();
    for (int i = 0; i < num_langs; ++i) {
        const polyseed_lang* lang = polyseed_get_lang(i);
        if (polyseed_lang_find_word(lang, word) >= 0) {
            return 1;
        }
    }
    return 0;
}
