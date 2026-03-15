/**
 * @file event.h
 *
 * Key event representation and manipulation.
 */

#ifndef TERMPLEX_VT_KEY_EVENT_H
#define TERMPLEX_VT_KEY_EVENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <termplex/vt/result.h>
#include <termplex/vt/allocator.h>

/**
 * Opaque handle to a key event.
 * 
 * This handle represents a keyboard input event containing information about
 * the physical key pressed, modifiers, and generated text.
 *
 * @ingroup key
 */
typedef struct TermplexKeyEvent *TermplexKeyEvent;

/**
 * Keyboard input event types.
 *
 * @ingroup key
 */
typedef enum {
    /** Key was released */
    TERMPLEX_KEY_ACTION_RELEASE = 0,
    /** Key was pressed */
    TERMPLEX_KEY_ACTION_PRESS = 1,
    /** Key is being repeated (held down) */
    TERMPLEX_KEY_ACTION_REPEAT = 2,
} TermplexKeyAction;

/**
 * Keyboard modifier keys bitmask.
 *
 * A bitmask representing all keyboard modifiers. This tracks which modifier keys 
 * are pressed and, where supported by the platform, which side (left or right) 
 * of each modifier is active.
 *
 * Use the TERMPLEX_MODS_* constants to test and set individual modifiers.
 *
 * Modifier side bits are only meaningful when the corresponding modifier bit is set.
 * Not all platforms support distinguishing between left and right modifier 
 * keys and Termplex is built to expect that some platforms may not provide this
 * information.
 *
 * @ingroup key
 */
typedef uint16_t TermplexMods;

/** Shift key is pressed */
#define TERMPLEX_MODS_SHIFT (1 << 0)
/** Control key is pressed */
#define TERMPLEX_MODS_CTRL (1 << 1)
/** Alt/Option key is pressed */
#define TERMPLEX_MODS_ALT (1 << 2)
/** Super/Command/Windows key is pressed */
#define TERMPLEX_MODS_SUPER (1 << 3)
/** Caps Lock is active */
#define TERMPLEX_MODS_CAPS_LOCK (1 << 4)
/** Num Lock is active */
#define TERMPLEX_MODS_NUM_LOCK (1 << 5)

/**
 * Right shift is pressed (0 = left, 1 = right).
 * Only meaningful when TERMPLEX_MODS_SHIFT is set.
 */
#define TERMPLEX_MODS_SHIFT_SIDE (1 << 6)
/**
 * Right ctrl is pressed (0 = left, 1 = right).
 * Only meaningful when TERMPLEX_MODS_CTRL is set.
 */
#define TERMPLEX_MODS_CTRL_SIDE (1 << 7)
/**
 * Right alt is pressed (0 = left, 1 = right).
 * Only meaningful when TERMPLEX_MODS_ALT is set.
 */
#define TERMPLEX_MODS_ALT_SIDE (1 << 8)
/**
 * Right super is pressed (0 = left, 1 = right).
 * Only meaningful when TERMPLEX_MODS_SUPER is set.
 */
#define TERMPLEX_MODS_SUPER_SIDE (1 << 9)

/**
 * Physical key codes.
 *
 * The set of key codes that Termplex is aware of. These represent physical keys 
 * on the keyboard and are layout-independent. For example, the "a" key on a US 
 * keyboard is the same as the "ф" key on a Russian keyboard, but both will 
 * report the same key_a value.
 *
 * Layout-dependent strings are provided separately as UTF-8 text and are produced 
 * by the platform. These values are based on the W3C UI Events KeyboardEvent code 
 * standard. See: https://www.w3.org/TR/uievents-code
 *
 * @ingroup key
 */
typedef enum {
    TERMPLEX_KEY_UNIDENTIFIED = 0,

    // Writing System Keys (W3C § 3.1.1)
    TERMPLEX_KEY_BACKQUOTE,
    TERMPLEX_KEY_BACKSLASH,
    TERMPLEX_KEY_BRACKET_LEFT,
    TERMPLEX_KEY_BRACKET_RIGHT,
    TERMPLEX_KEY_COMMA,
    TERMPLEX_KEY_DIGIT_0,
    TERMPLEX_KEY_DIGIT_1,
    TERMPLEX_KEY_DIGIT_2,
    TERMPLEX_KEY_DIGIT_3,
    TERMPLEX_KEY_DIGIT_4,
    TERMPLEX_KEY_DIGIT_5,
    TERMPLEX_KEY_DIGIT_6,
    TERMPLEX_KEY_DIGIT_7,
    TERMPLEX_KEY_DIGIT_8,
    TERMPLEX_KEY_DIGIT_9,
    TERMPLEX_KEY_EQUAL,
    TERMPLEX_KEY_INTL_BACKSLASH,
    TERMPLEX_KEY_INTL_RO,
    TERMPLEX_KEY_INTL_YEN,
    TERMPLEX_KEY_A,
    TERMPLEX_KEY_B,
    TERMPLEX_KEY_C,
    TERMPLEX_KEY_D,
    TERMPLEX_KEY_E,
    TERMPLEX_KEY_F,
    TERMPLEX_KEY_G,
    TERMPLEX_KEY_H,
    TERMPLEX_KEY_I,
    TERMPLEX_KEY_J,
    TERMPLEX_KEY_K,
    TERMPLEX_KEY_L,
    TERMPLEX_KEY_M,
    TERMPLEX_KEY_N,
    TERMPLEX_KEY_O,
    TERMPLEX_KEY_P,
    TERMPLEX_KEY_Q,
    TERMPLEX_KEY_R,
    TERMPLEX_KEY_S,
    TERMPLEX_KEY_T,
    TERMPLEX_KEY_U,
    TERMPLEX_KEY_V,
    TERMPLEX_KEY_W,
    TERMPLEX_KEY_X,
    TERMPLEX_KEY_Y,
    TERMPLEX_KEY_Z,
    TERMPLEX_KEY_MINUS,
    TERMPLEX_KEY_PERIOD,
    TERMPLEX_KEY_QUOTE,
    TERMPLEX_KEY_SEMICOLON,
    TERMPLEX_KEY_SLASH,

    // Functional Keys (W3C § 3.1.2)
    TERMPLEX_KEY_ALT_LEFT,
    TERMPLEX_KEY_ALT_RIGHT,
    TERMPLEX_KEY_BACKSPACE,
    TERMPLEX_KEY_CAPS_LOCK,
    TERMPLEX_KEY_CONTEXT_MENU,
    TERMPLEX_KEY_CONTROL_LEFT,
    TERMPLEX_KEY_CONTROL_RIGHT,
    TERMPLEX_KEY_ENTER,
    TERMPLEX_KEY_META_LEFT,
    TERMPLEX_KEY_META_RIGHT,
    TERMPLEX_KEY_SHIFT_LEFT,
    TERMPLEX_KEY_SHIFT_RIGHT,
    TERMPLEX_KEY_SPACE,
    TERMPLEX_KEY_TAB,
    TERMPLEX_KEY_CONVERT,
    TERMPLEX_KEY_KANA_MODE,
    TERMPLEX_KEY_NON_CONVERT,

    // Control Pad Section (W3C § 3.2)
    TERMPLEX_KEY_DELETE,
    TERMPLEX_KEY_END,
    TERMPLEX_KEY_HELP,
    TERMPLEX_KEY_HOME,
    TERMPLEX_KEY_INSERT,
    TERMPLEX_KEY_PAGE_DOWN,
    TERMPLEX_KEY_PAGE_UP,

    // Arrow Pad Section (W3C § 3.3)
    TERMPLEX_KEY_ARROW_DOWN,
    TERMPLEX_KEY_ARROW_LEFT,
    TERMPLEX_KEY_ARROW_RIGHT,
    TERMPLEX_KEY_ARROW_UP,

    // Numpad Section (W3C § 3.4)
    TERMPLEX_KEY_NUM_LOCK,
    TERMPLEX_KEY_NUMPAD_0,
    TERMPLEX_KEY_NUMPAD_1,
    TERMPLEX_KEY_NUMPAD_2,
    TERMPLEX_KEY_NUMPAD_3,
    TERMPLEX_KEY_NUMPAD_4,
    TERMPLEX_KEY_NUMPAD_5,
    TERMPLEX_KEY_NUMPAD_6,
    TERMPLEX_KEY_NUMPAD_7,
    TERMPLEX_KEY_NUMPAD_8,
    TERMPLEX_KEY_NUMPAD_9,
    TERMPLEX_KEY_NUMPAD_ADD,
    TERMPLEX_KEY_NUMPAD_BACKSPACE,
    TERMPLEX_KEY_NUMPAD_CLEAR,
    TERMPLEX_KEY_NUMPAD_CLEAR_ENTRY,
    TERMPLEX_KEY_NUMPAD_COMMA,
    TERMPLEX_KEY_NUMPAD_DECIMAL,
    TERMPLEX_KEY_NUMPAD_DIVIDE,
    TERMPLEX_KEY_NUMPAD_ENTER,
    TERMPLEX_KEY_NUMPAD_EQUAL,
    TERMPLEX_KEY_NUMPAD_MEMORY_ADD,
    TERMPLEX_KEY_NUMPAD_MEMORY_CLEAR,
    TERMPLEX_KEY_NUMPAD_MEMORY_RECALL,
    TERMPLEX_KEY_NUMPAD_MEMORY_STORE,
    TERMPLEX_KEY_NUMPAD_MEMORY_SUBTRACT,
    TERMPLEX_KEY_NUMPAD_MULTIPLY,
    TERMPLEX_KEY_NUMPAD_PAREN_LEFT,
    TERMPLEX_KEY_NUMPAD_PAREN_RIGHT,
    TERMPLEX_KEY_NUMPAD_SUBTRACT,
    TERMPLEX_KEY_NUMPAD_SEPARATOR,
    TERMPLEX_KEY_NUMPAD_UP,
    TERMPLEX_KEY_NUMPAD_DOWN,
    TERMPLEX_KEY_NUMPAD_RIGHT,
    TERMPLEX_KEY_NUMPAD_LEFT,
    TERMPLEX_KEY_NUMPAD_BEGIN,
    TERMPLEX_KEY_NUMPAD_HOME,
    TERMPLEX_KEY_NUMPAD_END,
    TERMPLEX_KEY_NUMPAD_INSERT,
    TERMPLEX_KEY_NUMPAD_DELETE,
    TERMPLEX_KEY_NUMPAD_PAGE_UP,
    TERMPLEX_KEY_NUMPAD_PAGE_DOWN,

    // Function Section (W3C § 3.5)
    TERMPLEX_KEY_ESCAPE,
    TERMPLEX_KEY_F1,
    TERMPLEX_KEY_F2,
    TERMPLEX_KEY_F3,
    TERMPLEX_KEY_F4,
    TERMPLEX_KEY_F5,
    TERMPLEX_KEY_F6,
    TERMPLEX_KEY_F7,
    TERMPLEX_KEY_F8,
    TERMPLEX_KEY_F9,
    TERMPLEX_KEY_F10,
    TERMPLEX_KEY_F11,
    TERMPLEX_KEY_F12,
    TERMPLEX_KEY_F13,
    TERMPLEX_KEY_F14,
    TERMPLEX_KEY_F15,
    TERMPLEX_KEY_F16,
    TERMPLEX_KEY_F17,
    TERMPLEX_KEY_F18,
    TERMPLEX_KEY_F19,
    TERMPLEX_KEY_F20,
    TERMPLEX_KEY_F21,
    TERMPLEX_KEY_F22,
    TERMPLEX_KEY_F23,
    TERMPLEX_KEY_F24,
    TERMPLEX_KEY_F25,
    TERMPLEX_KEY_FN,
    TERMPLEX_KEY_FN_LOCK,
    TERMPLEX_KEY_PRINT_SCREEN,
    TERMPLEX_KEY_SCROLL_LOCK,
    TERMPLEX_KEY_PAUSE,

    // Media Keys (W3C § 3.6)
    TERMPLEX_KEY_BROWSER_BACK,
    TERMPLEX_KEY_BROWSER_FAVORITES,
    TERMPLEX_KEY_BROWSER_FORWARD,
    TERMPLEX_KEY_BROWSER_HOME,
    TERMPLEX_KEY_BROWSER_REFRESH,
    TERMPLEX_KEY_BROWSER_SEARCH,
    TERMPLEX_KEY_BROWSER_STOP,
    TERMPLEX_KEY_EJECT,
    TERMPLEX_KEY_LAUNCH_APP_1,
    TERMPLEX_KEY_LAUNCH_APP_2,
    TERMPLEX_KEY_LAUNCH_MAIL,
    TERMPLEX_KEY_MEDIA_PLAY_PAUSE,
    TERMPLEX_KEY_MEDIA_SELECT,
    TERMPLEX_KEY_MEDIA_STOP,
    TERMPLEX_KEY_MEDIA_TRACK_NEXT,
    TERMPLEX_KEY_MEDIA_TRACK_PREVIOUS,
    TERMPLEX_KEY_POWER,
    TERMPLEX_KEY_SLEEP,
    TERMPLEX_KEY_AUDIO_VOLUME_DOWN,
    TERMPLEX_KEY_AUDIO_VOLUME_MUTE,
    TERMPLEX_KEY_AUDIO_VOLUME_UP,
    TERMPLEX_KEY_WAKE_UP,

    // Legacy, Non-standard, and Special Keys (W3C § 3.7)
    TERMPLEX_KEY_COPY,
    TERMPLEX_KEY_CUT,
    TERMPLEX_KEY_PASTE,
} TermplexKey;

/**
 * Create a new key event instance.
 * 
 * Creates a new key event with default values. The event must be freed using
 * termplex_key_event_free() when no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param event Pointer to store the created key event handle
 * @return TERMPLEX_SUCCESS on success, or an error code on failure
 * 
 * @ingroup key
 */
TermplexResult termplex_key_event_new(const TermplexAllocator *allocator, TermplexKeyEvent *event);

/**
 * Free a key event instance.
 * 
 * Releases all resources associated with the key event. After this call,
 * the event handle becomes invalid and must not be used.
 * 
 * @param event The key event handle to free (may be NULL)
 * 
 * @ingroup key
 */
void termplex_key_event_free(TermplexKeyEvent event);

/**
 * Set the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @param action The action to set
 *
 * @ingroup key
 */
void termplex_key_event_set_action(TermplexKeyEvent event, TermplexKeyAction action);

/**
 * Get the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @return The key action
 *
 * @ingroup key
 */
TermplexKeyAction termplex_key_event_get_action(TermplexKeyEvent event);

/**
 * Set the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @param key The physical key code to set
 *
 * @ingroup key
 */
void termplex_key_event_set_key(TermplexKeyEvent event, TermplexKey key);

/**
 * Get the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @return The physical key code
 *
 * @ingroup key
 */
TermplexKey termplex_key_event_get_key(TermplexKeyEvent event);

/**
 * Set the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param mods The modifier keys bitmask to set
 *
 * @ingroup key
 */
void termplex_key_event_set_mods(TermplexKeyEvent event, TermplexMods mods);

/**
 * Get the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The modifier keys bitmask
 *
 * @ingroup key
 */
TermplexMods termplex_key_event_get_mods(TermplexKeyEvent event);

/**
 * Set the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param consumed_mods The consumed modifiers bitmask to set
 *
 * @ingroup key
 */
void termplex_key_event_set_consumed_mods(TermplexKeyEvent event, TermplexMods consumed_mods);

/**
 * Get the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The consumed modifiers bitmask
 *
 * @ingroup key
 */
TermplexMods termplex_key_event_get_consumed_mods(TermplexKeyEvent event);

/**
 * Set whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @param composing Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
void termplex_key_event_set_composing(TermplexKeyEvent event, bool composing);

/**
 * Get whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @return Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
bool termplex_key_event_get_composing(TermplexKeyEvent event);

/**
 * Set the UTF-8 text generated by the key event.
 *
 * The key event does NOT take ownership of the text pointer. The caller
 * must ensure the string remains valid for the lifetime needed by the event.
 *
 * @param event The key event handle, must not be NULL
 * @param utf8 The UTF-8 text to set (or NULL for empty)
 * @param len Length of the UTF-8 text in bytes
 *
 * @ingroup key
 */
void termplex_key_event_set_utf8(TermplexKeyEvent event, const char *utf8, size_t len);

/**
 * Get the UTF-8 text generated by the key event.
 *
 * The returned pointer is valid until the event is freed or the UTF-8 text is modified.
 *
 * @param event The key event handle, must not be NULL
 * @param len Pointer to store the length of the UTF-8 text in bytes (may be NULL)
 * @return The UTF-8 text (or NULL for empty)
 *
 * @ingroup key
 */
const char *termplex_key_event_get_utf8(TermplexKeyEvent event, size_t *len);

/**
 * Set the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @param codepoint The unshifted Unicode codepoint to set
 *
 * @ingroup key
 */
void termplex_key_event_set_unshifted_codepoint(TermplexKeyEvent event, uint32_t codepoint);

/**
 * Get the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @return The unshifted Unicode codepoint
 *
 * @ingroup key
 */
uint32_t termplex_key_event_get_unshifted_codepoint(TermplexKeyEvent event);

#endif /* TERMPLEX_VT_KEY_EVENT_H */
