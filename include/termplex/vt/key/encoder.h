/**
 * @file encoder.h
 *
 * Key event encoding to terminal escape sequences.
 */

#ifndef TERMPLEX_VT_KEY_ENCODER_H
#define TERMPLEX_VT_KEY_ENCODER_H

#include <stddef.h>
#include <stdint.h>
#include <termplex/vt/result.h>
#include <termplex/vt/allocator.h>
#include <termplex/vt/key/event.h>

/**
 * Opaque handle to a key encoder instance.
 *
 * This handle represents a key encoder that converts key events into terminal
 * escape sequences.
 *
 * @ingroup key
 */
typedef struct TermplexKeyEncoder *TermplexKeyEncoder;

/**
 * Kitty keyboard protocol flags.
 *
 * Bitflags representing the various modes of the Kitty keyboard protocol.
 * These can be combined using bitwise OR operations. Valid values all
 * start with `TERMPLEX_KITTY_KEY_`.
 *
 * @ingroup key
 */
typedef uint8_t TermplexKittyKeyFlags;

/** Kitty keyboard protocol disabled (all flags off) */
#define TERMPLEX_KITTY_KEY_DISABLED 0

/** Disambiguate escape codes */
#define TERMPLEX_KITTY_KEY_DISAMBIGUATE (1 << 0)

/** Report key press and release events */
#define TERMPLEX_KITTY_KEY_REPORT_EVENTS (1 << 1)

/** Report alternate key codes */
#define TERMPLEX_KITTY_KEY_REPORT_ALTERNATES (1 << 2)

/** Report all key events including those normally handled by the terminal */
#define TERMPLEX_KITTY_KEY_REPORT_ALL (1 << 3)

/** Report associated text with key events */
#define TERMPLEX_KITTY_KEY_REPORT_ASSOCIATED (1 << 4)

/** All Kitty keyboard protocol flags enabled */
#define TERMPLEX_KITTY_KEY_ALL (TERMPLEX_KITTY_KEY_DISAMBIGUATE | TERMPLEX_KITTY_KEY_REPORT_EVENTS | TERMPLEX_KITTY_KEY_REPORT_ALTERNATES | TERMPLEX_KITTY_KEY_REPORT_ALL | TERMPLEX_KITTY_KEY_REPORT_ASSOCIATED)

/**
 * macOS option key behavior.
 *
 * Determines whether the "option" key on macOS is treated as "alt" or not.
 * See the Termplex `macos-option-as-alt` configuration option for more details.
 *
 * @ingroup key
 */
typedef enum {
    /** Option key is not treated as alt */
    TERMPLEX_OPTION_AS_ALT_FALSE = 0,
    /** Option key is treated as alt */
    TERMPLEX_OPTION_AS_ALT_TRUE = 1,
    /** Only left option key is treated as alt */
    TERMPLEX_OPTION_AS_ALT_LEFT = 2,
    /** Only right option key is treated as alt */
    TERMPLEX_OPTION_AS_ALT_RIGHT = 3,
} TermplexOptionAsAlt;

/**
 * Key encoder option identifiers.
 *
 * These values are used with termplex_key_encoder_setopt() to configure
 * the behavior of the key encoder.
 *
 * @ingroup key
 */
typedef enum {
    /** Terminal DEC mode 1: cursor key application mode (value: bool) */
    TERMPLEX_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION = 0,
    
    /** Terminal DEC mode 66: keypad key application mode (value: bool) */
    TERMPLEX_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION = 1,
    
    /** Terminal DEC mode 1035: ignore keypad with numlock (value: bool) */
    TERMPLEX_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK = 2,
    
    /** Terminal DEC mode 1036: alt sends escape prefix (value: bool) */
    TERMPLEX_KEY_ENCODER_OPT_ALT_ESC_PREFIX = 3,
    
    /** xterm modifyOtherKeys mode 2 (value: bool) */
    TERMPLEX_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 = 4,
    
    /** Kitty keyboard protocol flags (value: TermplexKittyKeyFlags bitmask) */
    TERMPLEX_KEY_ENCODER_OPT_KITTY_FLAGS = 5,
    
    /** macOS option-as-alt setting (value: TermplexOptionAsAlt) */
    TERMPLEX_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT = 6,
} TermplexKeyEncoderOption;

/**
 * Create a new key encoder instance.
 *
 * Creates a new key encoder with default options. The encoder can be configured
 * using termplex_key_encoder_setopt() and must be freed using
 * termplex_key_encoder_free() when no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param encoder Pointer to store the created encoder handle
 * @return TERMPLEX_SUCCESS on success, or an error code on failure
 *
 * @ingroup key
 */
TermplexResult termplex_key_encoder_new(const TermplexAllocator *allocator, TermplexKeyEncoder *encoder);

/**
 * Free a key encoder instance.
 *
 * Releases all resources associated with the key encoder. After this call,
 * the encoder handle becomes invalid and must not be used.
 *
 * @param encoder The encoder handle to free (may be NULL)
 *
 * @ingroup key
 */
void termplex_key_encoder_free(TermplexKeyEncoder encoder);

/**
 * Set an option on the key encoder.
 *
 * Configures the behavior of the key encoder. Options control various aspects
 * of encoding such as terminal modes (cursor key application mode, keypad mode),
 * protocol selection (Kitty keyboard protocol flags), and platform-specific
 * behaviors (macOS option-as-alt).
 *
 * A null pointer value does nothing. It does not reset the value to the
 * default. The setopt call will do nothing.
 *
 * @param encoder The encoder handle, must not be NULL
 * @param option The option to set
 * @param value Pointer to the value to set (type depends on the option)
 *
 * @ingroup key
 */
void termplex_key_encoder_setopt(TermplexKeyEncoder encoder, TermplexKeyEncoderOption option, const void *value);

/**
 * Encode a key event into a terminal escape sequence.
 *
 * Converts a key event into the appropriate terminal escape sequence based on
 * the encoder's current options. The sequence is written to the provided buffer.
 *
 * Not all key events produce output. For example, unmodified modifier keys
 * typically don't generate escape sequences. Check the out_len parameter to
 * determine if any data was written.
 *
 * If the output buffer is too small, this function returns TERMPLEX_OUT_OF_MEMORY
 * and out_len will contain the required buffer size. The caller can then
 * allocate a larger buffer and call the function again.
 *
 * @param encoder The encoder handle, must not be NULL
 * @param event The key event to encode, must not be NULL
 * @param out_buf Buffer to write the encoded sequence to
 * @param out_buf_size Size of the output buffer in bytes
 * @param out_len Pointer to store the number of bytes written (may be NULL)
 * @return TERMPLEX_SUCCESS on success, TERMPLEX_OUT_OF_MEMORY if buffer too small, or other error code
 *
 * ## Example: Calculate required buffer size
 *
 * @code{.c}
 * // Query the required size with a NULL buffer (always returns OUT_OF_MEMORY)
 * size_t required = 0;
 * TermplexResult result = termplex_key_encoder_encode(encoder, event, NULL, 0, &required);
 * assert(result == TERMPLEX_OUT_OF_MEMORY);
 * 
 * // Allocate buffer of required size
 * char *buf = malloc(required);
 * 
 * // Encode with properly sized buffer
 * size_t written = 0;
 * result = termplex_key_encoder_encode(encoder, event, buf, required, &written);
 * assert(result == TERMPLEX_SUCCESS);
 * 
 * // Use the encoded sequence...
 * 
 * free(buf);
 * @endcode
 *
 * ## Example: Direct encoding with static buffer
 *
 * @code{.c}
 * // Most escape sequences are short, so a static buffer often suffices
 * char buf[128];
 * size_t written = 0;
 * TermplexResult result = termplex_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 * 
 * if (result == TERMPLEX_SUCCESS) {
 *   // Write the encoded sequence to the terminal
 *   write(pty_fd, buf, written);
 * } else if (result == TERMPLEX_OUT_OF_MEMORY) {
 *   // Buffer too small, written contains required size
 *   char *dynamic_buf = malloc(written);
 *   result = termplex_key_encoder_encode(encoder, event, dynamic_buf, written, &written);
 *   assert(result == TERMPLEX_SUCCESS);
 *   write(pty_fd, dynamic_buf, written);
 *   free(dynamic_buf);
 * }
 * @endcode
 *
 * @ingroup key
 */
TermplexResult termplex_key_encoder_encode(TermplexKeyEncoder encoder, TermplexKeyEvent event, char *out_buf, size_t out_buf_size, size_t *out_len);

#endif /* TERMPLEX_VT_KEY_ENCODER_H */
