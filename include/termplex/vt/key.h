/**
 * @file key.h
 *
 * Key encoding module - encode key events into terminal escape sequences.
 */

#ifndef TERMPLEX_VT_KEY_H
#define TERMPLEX_VT_KEY_H

/** @defgroup key Key Encoding
 *
 * Utilities for encoding key events into terminal escape sequences,
 * supporting both legacy encoding as well as Kitty Keyboard Protocol.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with termplex_key_encoder_new()
 * 2. Configure encoder options with termplex_key_encoder_setopt().
 * 3. For each key event:
 *    - Create a key event with termplex_key_event_new()
 *    - Set event properties (action, key, modifiers, etc.)
 *    - Encode with termplex_key_encoder_encode()
 *    - Free the event with termplex_key_event_free()
 *    - Note: You can also reuse the same key event multiple times by
 *      changing its properties.
 * 4. Free the encoder with termplex_key_encoder_free() when done
 *
 * ## Example
 *
 * @code{.c}
 * #include <assert.h>
 * #include <stdio.h>
 * #include <termplex/vt.h>
 * 
 * int main() {
 *   // Create encoder
 *   TermplexKeyEncoder encoder;
 *   TermplexResult result = termplex_key_encoder_new(NULL, &encoder);
 *   assert(result == TERMPLEX_SUCCESS);
 * 
 *   // Enable Kitty keyboard protocol with all features
 *   termplex_key_encoder_setopt(encoder, TERMPLEX_KEY_ENCODER_OPT_KITTY_FLAGS, 
 *                              &(uint8_t){TERMPLEX_KITTY_KEY_ALL});
 * 
 *   // Create and configure key event for Ctrl+C press
 *   TermplexKeyEvent event;
 *   result = termplex_key_event_new(NULL, &event);
 *   assert(result == TERMPLEX_SUCCESS);
 *   termplex_key_event_set_action(event, TERMPLEX_KEY_ACTION_PRESS);
 *   termplex_key_event_set_key(event, TERMPLEX_KEY_C);
 *   termplex_key_event_set_mods(event, TERMPLEX_MODS_CTRL);
 * 
 *   // Encode the key event
 *   char buf[128];
 *   size_t written = 0;
 *   result = termplex_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *   assert(result == TERMPLEX_SUCCESS);
 * 
 *   // Use the encoded sequence (e.g., write to terminal)
 *   fwrite(buf, 1, written, stdout);
 * 
 *   // Cleanup
 *   termplex_key_event_free(event);
 *   termplex_key_encoder_free(encoder);
 *   return 0;
 * }
 * @endcode
 *
 * For a complete working example, see example/c-vt-key-encode in the
 * repository.
 *
 * @{
 */

#include <termplex/vt/key/event.h>
#include <termplex/vt/key/encoder.h>

/** @} */

#endif /* TERMPLEX_VT_KEY_H */
