/**
 * @file sgr.h
 *
 * SGR (Select Graphic Rendition) attribute parsing and handling.
 */

#ifndef TERMPLEX_VT_SGR_H
#define TERMPLEX_VT_SGR_H

/** @defgroup sgr SGR Parser
 *
 * SGR (Select Graphic Rendition) attribute parser.
 *
 * SGR sequences are the syntax used to set styling attributes such as
 * bold, italic, underline, and colors for text in terminal emulators.
 * For example, you may be familiar with sequences like `ESC[1;31m`. The
 * `1;31` is the SGR attribute list.
 *
 * The parser processes SGR parameters from CSI sequences (e.g., `ESC[1;31m`)
 * and returns individual text attributes like bold, italic, colors, etc.
 * It supports both semicolon (`;`) and colon (`:`) separators, possibly mixed,
 * and handles various color formats including 8-color, 16-color, 256-color,
 * X11 named colors, and RGB in multiple formats.
 *
 * ## Basic Usage
 *
 * 1. Create a parser instance with termplex_sgr_new()
 * 2. Set SGR parameters with termplex_sgr_set_params()
 * 3. Iterate through attributes using termplex_sgr_next()
 * 4. Free the parser with termplex_sgr_free() when done
 *
 * ## Example
 *
 * @code{.c}
 * #include <assert.h>
 * #include <stdio.h>
 * #include <termplex/vt.h>
 *
 * int main() {
 *   // Create parser
 *   TermplexSgrParser parser;
 *   TermplexResult result = termplex_sgr_new(NULL, &parser);
 *   assert(result == TERMPLEX_SUCCESS);
 *
 *   // Parse "bold, red foreground" sequence: ESC[1;31m
 *   uint16_t params[] = {1, 31};
 *   result = termplex_sgr_set_params(parser, params, NULL, 2);
 *   assert(result == TERMPLEX_SUCCESS);
 *
 *   // Iterate through attributes
 *   TermplexSgrAttribute attr;
 *   while (termplex_sgr_next(parser, &attr)) {
 *     switch (attr.tag) {
 *       case TERMPLEX_SGR_ATTR_BOLD:
 *         printf("Bold enabled\n");
 *         break;
 *       case TERMPLEX_SGR_ATTR_FG_8:
 *         printf("Foreground color: %d\n", attr.value.fg_8);
 *         break;
 *       default:
 *         break;
 *     }
 *   }
 *
 *   // Cleanup
 *   termplex_sgr_free(parser);
 *   return 0;
 * }
 * @endcode
 *
 * @{
 */

#include <termplex/vt/allocator.h>
#include <termplex/vt/color.h>
#include <termplex/vt/result.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque handle to an SGR parser instance.
 *
 * This handle represents an SGR (Select Graphic Rendition) parser that can
 * be used to parse SGR sequences and extract individual text attributes.
 *
 * @ingroup sgr
 */
typedef struct TermplexSgrParser* TermplexSgrParser;

/**
 * SGR attribute tags.
 *
 * These values identify the type of an SGR attribute in a tagged union.
 * Use the tag to determine which field in the attribute value union to access.
 *
 * @ingroup sgr
 */
typedef enum {
  TERMPLEX_SGR_ATTR_UNSET = 0,
  TERMPLEX_SGR_ATTR_UNKNOWN = 1,
  TERMPLEX_SGR_ATTR_BOLD = 2,
  TERMPLEX_SGR_ATTR_RESET_BOLD = 3,
  TERMPLEX_SGR_ATTR_ITALIC = 4,
  TERMPLEX_SGR_ATTR_RESET_ITALIC = 5,
  TERMPLEX_SGR_ATTR_FAINT = 6,
  TERMPLEX_SGR_ATTR_UNDERLINE = 7,
  TERMPLEX_SGR_ATTR_UNDERLINE_COLOR = 8,
  TERMPLEX_SGR_ATTR_UNDERLINE_COLOR_256 = 9,
  TERMPLEX_SGR_ATTR_RESET_UNDERLINE_COLOR = 10,
  TERMPLEX_SGR_ATTR_OVERLINE = 11,
  TERMPLEX_SGR_ATTR_RESET_OVERLINE = 12,
  TERMPLEX_SGR_ATTR_BLINK = 13,
  TERMPLEX_SGR_ATTR_RESET_BLINK = 14,
  TERMPLEX_SGR_ATTR_INVERSE = 15,
  TERMPLEX_SGR_ATTR_RESET_INVERSE = 16,
  TERMPLEX_SGR_ATTR_INVISIBLE = 17,
  TERMPLEX_SGR_ATTR_RESET_INVISIBLE = 18,
  TERMPLEX_SGR_ATTR_STRIKETHROUGH = 19,
  TERMPLEX_SGR_ATTR_RESET_STRIKETHROUGH = 20,
  TERMPLEX_SGR_ATTR_DIRECT_COLOR_FG = 21,
  TERMPLEX_SGR_ATTR_DIRECT_COLOR_BG = 22,
  TERMPLEX_SGR_ATTR_BG_8 = 23,
  TERMPLEX_SGR_ATTR_FG_8 = 24,
  TERMPLEX_SGR_ATTR_RESET_FG = 25,
  TERMPLEX_SGR_ATTR_RESET_BG = 26,
  TERMPLEX_SGR_ATTR_BRIGHT_BG_8 = 27,
  TERMPLEX_SGR_ATTR_BRIGHT_FG_8 = 28,
  TERMPLEX_SGR_ATTR_BG_256 = 29,
  TERMPLEX_SGR_ATTR_FG_256 = 30,
} TermplexSgrAttributeTag;

/**
 * Underline style types.
 *
 * @ingroup sgr
 */
typedef enum {
  TERMPLEX_SGR_UNDERLINE_NONE = 0,
  TERMPLEX_SGR_UNDERLINE_SINGLE = 1,
  TERMPLEX_SGR_UNDERLINE_DOUBLE = 2,
  TERMPLEX_SGR_UNDERLINE_CURLY = 3,
  TERMPLEX_SGR_UNDERLINE_DOTTED = 4,
  TERMPLEX_SGR_UNDERLINE_DASHED = 5,
} TermplexSgrUnderline;

/**
 * Unknown SGR attribute data.
 *
 * Contains the full parameter list and the partial list where parsing
 * encountered an unknown or invalid sequence.
 *
 * @ingroup sgr
 */
typedef struct {
  const uint16_t* full_ptr;
  size_t full_len;
  const uint16_t* partial_ptr;
  size_t partial_len;
} TermplexSgrUnknown;

/**
 * SGR attribute value union.
 *
 * This union contains all possible attribute values. Use the tag field
 * to determine which union member is active. Attributes without associated
 * data (like bold, italic) don't use the union value.
 *
 * @ingroup sgr
 */
typedef union {
  TermplexSgrUnknown unknown;
  TermplexSgrUnderline underline;
  TermplexColorRgb underline_color;
  TermplexColorPaletteIndex underline_color_256;
  TermplexColorRgb direct_color_fg;
  TermplexColorRgb direct_color_bg;
  TermplexColorPaletteIndex bg_8;
  TermplexColorPaletteIndex fg_8;
  TermplexColorPaletteIndex bright_bg_8;
  TermplexColorPaletteIndex bright_fg_8;
  TermplexColorPaletteIndex bg_256;
  TermplexColorPaletteIndex fg_256;
  uint64_t _padding[8];
} TermplexSgrAttributeValue;

/**
 * SGR attribute (tagged union).
 *
 * A complete SGR attribute with both its type tag and associated value.
 * Always check the tag field to determine which value union member is valid.
 *
 * Attributes without associated data (e.g., TERMPLEX_SGR_ATTR_BOLD) can be
 * identified by tag alone; the value union is not used for these and
 * the memory in the value field is undefined.
 *
 * @ingroup sgr
 */
typedef struct {
  TermplexSgrAttributeTag tag;
  TermplexSgrAttributeValue value;
} TermplexSgrAttribute;

/**
 * Create a new SGR parser instance.
 *
 * Creates a new SGR (Select Graphic Rendition) parser using the provided
 * allocator. The parser must be freed using termplex_sgr_free() when
 * no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or
 * NULL to use the default allocator
 * @param parser Pointer to store the created parser handle
 * @return TERMPLEX_SUCCESS on success, or an error code on failure
 *
 * @ingroup sgr
 */
TermplexResult termplex_sgr_new(const TermplexAllocator* allocator,
                              TermplexSgrParser* parser);

/**
 * Free an SGR parser instance.
 *
 * Releases all resources associated with the SGR parser. After this call,
 * the parser handle becomes invalid and must not be used. This includes
 * any attributes previously returned by termplex_sgr_next().
 *
 * @param parser The parser handle to free (may be NULL)
 *
 * @ingroup sgr
 */
void termplex_sgr_free(TermplexSgrParser parser);

/**
 * Reset an SGR parser instance to the beginning of the parameter list.
 *
 * Resets the parser's iteration state without clearing the parameters.
 * After calling this, termplex_sgr_next() will start from the beginning
 * of the parameter list again.
 *
 * @param parser The parser handle to reset, must not be NULL
 *
 * @ingroup sgr
 */
void termplex_sgr_reset(TermplexSgrParser parser);

/**
 * Set SGR parameters for parsing.
 *
 * Sets the SGR parameter list to parse. Parameters are the numeric values
 * from a CSI SGR sequence (e.g., for `ESC[1;31m`, params would be {1, 31}).
 *
 * The separators array optionally specifies the separator type for each
 * parameter position. Each byte should be either ';' for semicolon or ':'
 * for colon. This is needed for certain color formats that use colon
 * separators (e.g., `ESC[4:3m` for curly underline). Any invalid separator
 * values are treated as semicolons. The separators array must have the same
 * length as the params array, if it is not NULL.
 *
 * If separators is NULL, all parameters are assumed to be semicolon-separated.
 *
 * This function makes an internal copy of the parameter and separator data,
 * so the caller can safely free or modify the input arrays after this call.
 *
 * After calling this function, the parser is automatically reset and ready
 * to iterate from the beginning.
 *
 * @param parser The parser handle, must not be NULL
 * @param params Array of SGR parameter values
 * @param separators Optional array of separator characters (';' or ':'), or
 * NULL
 * @param len Number of parameters (and separators if provided)
 * @return TERMPLEX_SUCCESS on success, or an error code on failure
 *
 * @ingroup sgr
 */
TermplexResult termplex_sgr_set_params(TermplexSgrParser parser,
                                     const uint16_t* params,
                                     const char* separators,
                                     size_t len);

/**
 * Get the next SGR attribute.
 *
 * Parses and returns the next attribute from the parameter list.
 * Call this function repeatedly until it returns false to process
 * all attributes in the sequence.
 *
 * @param parser The parser handle, must not be NULL
 * @param attr Pointer to store the next attribute
 * @return true if an attribute was returned, false if no more attributes
 *
 * @ingroup sgr
 */
bool termplex_sgr_next(TermplexSgrParser parser, TermplexSgrAttribute* attr);

/**
 * Get the full parameter list from an unknown SGR attribute.
 *
 * This function retrieves the full parameter list that was provided to the
 * parser when an unknown attribute was encountered. Primarily useful in
 * WebAssembly environments where accessing struct fields directly is difficult.
 *
 * @param unknown The unknown attribute data
 * @param ptr Pointer to store the pointer to the parameter array (may be NULL)
 * @return The length of the full parameter array
 *
 * @ingroup sgr
 */
size_t termplex_sgr_unknown_full(TermplexSgrUnknown unknown,
                                const uint16_t** ptr);

/**
 * Get the partial parameter list from an unknown SGR attribute.
 *
 * This function retrieves the partial parameter list where parsing stopped
 * when an unknown attribute was encountered. Primarily useful in WebAssembly
 * environments where accessing struct fields directly is difficult.
 *
 * @param unknown The unknown attribute data
 * @param ptr Pointer to store the pointer to the parameter array (may be NULL)
 * @return The length of the partial parameter array
 *
 * @ingroup sgr
 */
size_t termplex_sgr_unknown_partial(TermplexSgrUnknown unknown,
                                   const uint16_t** ptr);

/**
 * Get the tag from an SGR attribute.
 *
 * This function extracts the tag that identifies which type of attribute
 * this is. Primarily useful in WebAssembly environments where accessing
 * struct fields directly is difficult.
 *
 * @param attr The SGR attribute
 * @return The attribute tag
 *
 * @ingroup sgr
 */
TermplexSgrAttributeTag termplex_sgr_attribute_tag(TermplexSgrAttribute attr);

/**
 * Get the value from an SGR attribute.
 *
 * This function returns a pointer to the value union from an SGR attribute. Use
 * the tag to determine which field of the union is valid. Primarily useful in
 * WebAssembly environments where accessing struct fields directly is difficult.
 *
 * @param attr Pointer to the SGR attribute
 * @return Pointer to the attribute value union
 *
 * @ingroup sgr
 */
TermplexSgrAttributeValue* termplex_sgr_attribute_value(
    TermplexSgrAttribute* attr);

#ifdef __wasm__
/**
 * Allocate memory for an SGR attribute (WebAssembly only).
 *
 * This is a convenience function for WebAssembly environments to allocate
 * memory for an SGR attribute structure that can be passed to termplex_sgr_next.
 *
 * @return Pointer to the allocated attribute structure
 *
 * @ingroup wasm
 */
TermplexSgrAttribute* termplex_wasm_alloc_sgr_attribute(void);

/**
 * Free memory for an SGR attribute (WebAssembly only).
 *
 * Frees memory allocated by termplex_wasm_alloc_sgr_attribute.
 *
 * @param attr Pointer to the attribute structure to free
 *
 * @ingroup wasm
 */
void termplex_wasm_free_sgr_attribute(TermplexSgrAttribute* attr);
#endif

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* TERMPLEX_VT_SGR_H */
