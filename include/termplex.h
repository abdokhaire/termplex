// Termplex embedding API. The documentation for the embedding API is
// only within the Zig source files that define the implementations. This
// isn't meant to be a general purpose embedding API (yet) so there hasn't
// been documentation or example work beyond that.
//
// The only consumer of this API is the macOS app, but the API is built to
// be more general purpose.
#ifndef TERMPLEX_H
#define TERMPLEX_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

//-------------------------------------------------------------------
// Macros

#define TERMPLEX_SUCCESS 0

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* termplex_app_t;
typedef void* termplex_config_t;
typedef void* termplex_surface_t;
typedef void* termplex_inspector_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  TERMPLEX_PLATFORM_INVALID,
  TERMPLEX_PLATFORM_MACOS,
  TERMPLEX_PLATFORM_IOS,
} termplex_platform_e;

typedef enum {
  TERMPLEX_CLIPBOARD_STANDARD,
  TERMPLEX_CLIPBOARD_SELECTION,
} termplex_clipboard_e;

typedef struct {
  const char *mime;
  const char *data;
} termplex_clipboard_content_s;

typedef enum {
  TERMPLEX_CLIPBOARD_REQUEST_PASTE,
  TERMPLEX_CLIPBOARD_REQUEST_OSC_52_READ,
  TERMPLEX_CLIPBOARD_REQUEST_OSC_52_WRITE,
} termplex_clipboard_request_e;

typedef enum {
  TERMPLEX_MOUSE_RELEASE,
  TERMPLEX_MOUSE_PRESS,
} termplex_input_mouse_state_e;

typedef enum {
  TERMPLEX_MOUSE_UNKNOWN,
  TERMPLEX_MOUSE_LEFT,
  TERMPLEX_MOUSE_RIGHT,
  TERMPLEX_MOUSE_MIDDLE,
  TERMPLEX_MOUSE_FOUR,
  TERMPLEX_MOUSE_FIVE,
  TERMPLEX_MOUSE_SIX,
  TERMPLEX_MOUSE_SEVEN,
  TERMPLEX_MOUSE_EIGHT,
  TERMPLEX_MOUSE_NINE,
  TERMPLEX_MOUSE_TEN,
  TERMPLEX_MOUSE_ELEVEN,
} termplex_input_mouse_button_e;

typedef enum {
  TERMPLEX_MOUSE_MOMENTUM_NONE,
  TERMPLEX_MOUSE_MOMENTUM_BEGAN,
  TERMPLEX_MOUSE_MOMENTUM_STATIONARY,
  TERMPLEX_MOUSE_MOMENTUM_CHANGED,
  TERMPLEX_MOUSE_MOMENTUM_ENDED,
  TERMPLEX_MOUSE_MOMENTUM_CANCELLED,
  TERMPLEX_MOUSE_MOMENTUM_MAY_BEGIN,
} termplex_input_mouse_momentum_e;

typedef enum {
  TERMPLEX_COLOR_SCHEME_LIGHT = 0,
  TERMPLEX_COLOR_SCHEME_DARK = 1,
} termplex_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int termplex_input_scroll_mods_t;

typedef enum {
  TERMPLEX_MODS_NONE = 0,
  TERMPLEX_MODS_SHIFT = 1 << 0,
  TERMPLEX_MODS_CTRL = 1 << 1,
  TERMPLEX_MODS_ALT = 1 << 2,
  TERMPLEX_MODS_SUPER = 1 << 3,
  TERMPLEX_MODS_CAPS = 1 << 4,
  TERMPLEX_MODS_NUM = 1 << 5,
  TERMPLEX_MODS_SHIFT_RIGHT = 1 << 6,
  TERMPLEX_MODS_CTRL_RIGHT = 1 << 7,
  TERMPLEX_MODS_ALT_RIGHT = 1 << 8,
  TERMPLEX_MODS_SUPER_RIGHT = 1 << 9,
} termplex_input_mods_e;

typedef enum {
  TERMPLEX_BINDING_FLAGS_CONSUMED = 1 << 0,
  TERMPLEX_BINDING_FLAGS_ALL = 1 << 1,
  TERMPLEX_BINDING_FLAGS_GLOBAL = 1 << 2,
  TERMPLEX_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} termplex_binding_flags_e;

typedef enum {
  TERMPLEX_ACTION_RELEASE,
  TERMPLEX_ACTION_PRESS,
  TERMPLEX_ACTION_REPEAT,
} termplex_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  TERMPLEX_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
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

  // "Functional Keys" § 3.1.2
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

  // "Control Pad Section" § 3.2
  TERMPLEX_KEY_DELETE,
  TERMPLEX_KEY_END,
  TERMPLEX_KEY_HELP,
  TERMPLEX_KEY_HOME,
  TERMPLEX_KEY_INSERT,
  TERMPLEX_KEY_PAGE_DOWN,
  TERMPLEX_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  TERMPLEX_KEY_ARROW_DOWN,
  TERMPLEX_KEY_ARROW_LEFT,
  TERMPLEX_KEY_ARROW_RIGHT,
  TERMPLEX_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
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

  // "Function Section" § 3.5
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

  // "Media Keys" § 3.6
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

  // "Legacy, Non-standard, and Special Keys" § 3.7
  TERMPLEX_KEY_COPY,
  TERMPLEX_KEY_CUT,
  TERMPLEX_KEY_PASTE,
} termplex_input_key_e;

typedef struct {
  termplex_input_action_e action;
  termplex_input_mods_e mods;
  termplex_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} termplex_input_key_s;

typedef enum {
  TERMPLEX_TRIGGER_PHYSICAL,
  TERMPLEX_TRIGGER_UNICODE,
  TERMPLEX_TRIGGER_CATCH_ALL,
} termplex_input_trigger_tag_e;

typedef union {
  termplex_input_key_e translated;
  termplex_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} termplex_input_trigger_key_u;

typedef struct {
  termplex_input_trigger_tag_e tag;
  termplex_input_trigger_key_u key;
  termplex_input_mods_e mods;
} termplex_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} termplex_command_s;

typedef enum {
  TERMPLEX_BUILD_MODE_DEBUG,
  TERMPLEX_BUILD_MODE_RELEASE_SAFE,
  TERMPLEX_BUILD_MODE_RELEASE_FAST,
  TERMPLEX_BUILD_MODE_RELEASE_SMALL,
} termplex_build_mode_e;

typedef struct {
  termplex_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} termplex_info_s;

typedef struct {
  const char* message;
} termplex_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} termplex_string_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} termplex_text_s;

typedef enum {
  TERMPLEX_POINT_ACTIVE,
  TERMPLEX_POINT_VIEWPORT,
  TERMPLEX_POINT_SCREEN,
  TERMPLEX_POINT_SURFACE,
} termplex_point_tag_e;

typedef enum {
  TERMPLEX_POINT_COORD_EXACT,
  TERMPLEX_POINT_COORD_TOP_LEFT,
  TERMPLEX_POINT_COORD_BOTTOM_RIGHT,
} termplex_point_coord_e;

typedef struct {
  termplex_point_tag_e tag;
  termplex_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} termplex_point_s;

typedef struct {
  termplex_point_s top_left;
  termplex_point_s bottom_right;
  bool rectangle;
} termplex_selection_s;

typedef struct {
  const char* key;
  const char* value;
} termplex_env_var_s;

typedef struct {
  void* nsview;
} termplex_platform_macos_s;

typedef struct {
  void* uiview;
} termplex_platform_ios_s;

typedef union {
  termplex_platform_macos_s macos;
  termplex_platform_ios_s ios;
} termplex_platform_u;

typedef enum {
  TERMPLEX_SURFACE_CONTEXT_WINDOW = 0,
  TERMPLEX_SURFACE_CONTEXT_TAB = 1,
  TERMPLEX_SURFACE_CONTEXT_SPLIT = 2,
} termplex_surface_context_e;

typedef struct {
  termplex_platform_e platform_tag;
  termplex_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  termplex_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  termplex_surface_context_e context;
} termplex_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} termplex_surface_size_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} termplex_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} termplex_config_color_s;

// config.ColorList
typedef struct {
  const termplex_config_color_s* colors;
  size_t len;
} termplex_config_color_list_s;

// config.RepeatableCommand
typedef struct {
  const termplex_command_s* commands;
  size_t len;
} termplex_config_command_list_s;

// config.Palette
typedef struct {
  termplex_config_color_s colors[256];
} termplex_config_palette_s;

// config.QuickTerminalSize
typedef enum {
  TERMPLEX_QUICK_TERMINAL_SIZE_NONE,
  TERMPLEX_QUICK_TERMINAL_SIZE_PERCENTAGE,
  TERMPLEX_QUICK_TERMINAL_SIZE_PIXELS,
} termplex_quick_terminal_size_tag_e;

typedef union {
  float percentage;
  uint32_t pixels;
} termplex_quick_terminal_size_value_u;

typedef struct {
  termplex_quick_terminal_size_tag_e tag;
  termplex_quick_terminal_size_value_u value;
} termplex_quick_terminal_size_s;

typedef struct {
  termplex_quick_terminal_size_s primary;
  termplex_quick_terminal_size_s secondary;
} termplex_config_quick_terminal_size_s;

// config.Fullscreen
typedef enum {
  TERMPLEX_CONFIG_FULLSCREEN_FALSE,
  TERMPLEX_CONFIG_FULLSCREEN_TRUE,
  TERMPLEX_CONFIG_FULLSCREEN_NON_NATIVE,
  TERMPLEX_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  TERMPLEX_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} termplex_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  TERMPLEX_TARGET_APP,
  TERMPLEX_TARGET_SURFACE,
} termplex_target_tag_e;

typedef union {
  termplex_surface_t surface;
} termplex_target_u;

typedef struct {
  termplex_target_tag_e tag;
  termplex_target_u target;
} termplex_target_s;

// apprt.action.SplitDirection
typedef enum {
  TERMPLEX_SPLIT_DIRECTION_RIGHT,
  TERMPLEX_SPLIT_DIRECTION_DOWN,
  TERMPLEX_SPLIT_DIRECTION_LEFT,
  TERMPLEX_SPLIT_DIRECTION_UP,
} termplex_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  TERMPLEX_GOTO_SPLIT_PREVIOUS,
  TERMPLEX_GOTO_SPLIT_NEXT,
  TERMPLEX_GOTO_SPLIT_UP,
  TERMPLEX_GOTO_SPLIT_LEFT,
  TERMPLEX_GOTO_SPLIT_DOWN,
  TERMPLEX_GOTO_SPLIT_RIGHT,
} termplex_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  TERMPLEX_GOTO_WINDOW_PREVIOUS,
  TERMPLEX_GOTO_WINDOW_NEXT,
} termplex_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  TERMPLEX_RESIZE_SPLIT_UP,
  TERMPLEX_RESIZE_SPLIT_DOWN,
  TERMPLEX_RESIZE_SPLIT_LEFT,
  TERMPLEX_RESIZE_SPLIT_RIGHT,
} termplex_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  termplex_action_resize_split_direction_e direction;
} termplex_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} termplex_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  TERMPLEX_GOTO_TAB_PREVIOUS = -1,
  TERMPLEX_GOTO_TAB_NEXT = -2,
  TERMPLEX_GOTO_TAB_LAST = -3,
} termplex_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  TERMPLEX_FULLSCREEN_NATIVE,
  TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE,
  TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} termplex_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  TERMPLEX_FLOAT_WINDOW_ON,
  TERMPLEX_FLOAT_WINDOW_OFF,
  TERMPLEX_FLOAT_WINDOW_TOGGLE,
} termplex_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  TERMPLEX_SECURE_INPUT_ON,
  TERMPLEX_SECURE_INPUT_OFF,
  TERMPLEX_SECURE_INPUT_TOGGLE,
} termplex_action_secure_input_e;

// apprt.action.Inspector
typedef enum {
  TERMPLEX_INSPECTOR_TOGGLE,
  TERMPLEX_INSPECTOR_SHOW,
  TERMPLEX_INSPECTOR_HIDE,
} termplex_action_inspector_e;

// apprt.action.QuitTimer
typedef enum {
  TERMPLEX_QUIT_TIMER_START,
  TERMPLEX_QUIT_TIMER_STOP,
} termplex_action_quit_timer_e;

// apprt.action.Readonly
typedef enum {
  TERMPLEX_READONLY_OFF,
  TERMPLEX_READONLY_ON,
} termplex_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} termplex_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} termplex_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  TERMPLEX_PROMPT_TITLE_SURFACE,
  TERMPLEX_PROMPT_TITLE_TAB,
} termplex_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} termplex_action_pwd_s;

// terminal.MouseShape
typedef enum {
  TERMPLEX_MOUSE_SHAPE_DEFAULT,
  TERMPLEX_MOUSE_SHAPE_CONTEXT_MENU,
  TERMPLEX_MOUSE_SHAPE_HELP,
  TERMPLEX_MOUSE_SHAPE_POINTER,
  TERMPLEX_MOUSE_SHAPE_PROGRESS,
  TERMPLEX_MOUSE_SHAPE_WAIT,
  TERMPLEX_MOUSE_SHAPE_CELL,
  TERMPLEX_MOUSE_SHAPE_CROSSHAIR,
  TERMPLEX_MOUSE_SHAPE_TEXT,
  TERMPLEX_MOUSE_SHAPE_VERTICAL_TEXT,
  TERMPLEX_MOUSE_SHAPE_ALIAS,
  TERMPLEX_MOUSE_SHAPE_COPY,
  TERMPLEX_MOUSE_SHAPE_MOVE,
  TERMPLEX_MOUSE_SHAPE_NO_DROP,
  TERMPLEX_MOUSE_SHAPE_NOT_ALLOWED,
  TERMPLEX_MOUSE_SHAPE_GRAB,
  TERMPLEX_MOUSE_SHAPE_GRABBING,
  TERMPLEX_MOUSE_SHAPE_ALL_SCROLL,
  TERMPLEX_MOUSE_SHAPE_COL_RESIZE,
  TERMPLEX_MOUSE_SHAPE_ROW_RESIZE,
  TERMPLEX_MOUSE_SHAPE_N_RESIZE,
  TERMPLEX_MOUSE_SHAPE_E_RESIZE,
  TERMPLEX_MOUSE_SHAPE_S_RESIZE,
  TERMPLEX_MOUSE_SHAPE_W_RESIZE,
  TERMPLEX_MOUSE_SHAPE_NE_RESIZE,
  TERMPLEX_MOUSE_SHAPE_NW_RESIZE,
  TERMPLEX_MOUSE_SHAPE_SE_RESIZE,
  TERMPLEX_MOUSE_SHAPE_SW_RESIZE,
  TERMPLEX_MOUSE_SHAPE_EW_RESIZE,
  TERMPLEX_MOUSE_SHAPE_NS_RESIZE,
  TERMPLEX_MOUSE_SHAPE_NESW_RESIZE,
  TERMPLEX_MOUSE_SHAPE_NWSE_RESIZE,
  TERMPLEX_MOUSE_SHAPE_ZOOM_IN,
  TERMPLEX_MOUSE_SHAPE_ZOOM_OUT,
} termplex_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  TERMPLEX_MOUSE_VISIBLE,
  TERMPLEX_MOUSE_HIDDEN,
} termplex_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} termplex_action_mouse_over_link_s;

// apprt.action.SizeLimit
typedef struct {
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
} termplex_action_size_limit_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} termplex_action_initial_size_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} termplex_action_cell_size_s;

// renderer.Health
typedef enum {
  TERMPLEX_RENDERER_HEALTH_HEALTHY,
  TERMPLEX_RENDERER_HEALTH_UNHEALTHY,
} termplex_action_renderer_health_e;

// apprt.action.KeySequence
typedef struct {
  bool active;
  termplex_input_trigger_s trigger;
} termplex_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  TERMPLEX_KEY_TABLE_ACTIVATE,
  TERMPLEX_KEY_TABLE_DEACTIVATE,
  TERMPLEX_KEY_TABLE_DEACTIVATE_ALL,
} termplex_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} termplex_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  termplex_action_key_table_tag_e tag;
  termplex_action_key_table_u value;
} termplex_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  TERMPLEX_ACTION_COLOR_KIND_FOREGROUND = -1,
  TERMPLEX_ACTION_COLOR_KIND_BACKGROUND = -2,
  TERMPLEX_ACTION_COLOR_KIND_CURSOR = -3,
} termplex_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  termplex_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} termplex_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  termplex_config_t config;
} termplex_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} termplex_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  TERMPLEX_ACTION_OPEN_URL_KIND_UNKNOWN,
  TERMPLEX_ACTION_OPEN_URL_KIND_TEXT,
  TERMPLEX_ACTION_OPEN_URL_KIND_HTML,
} termplex_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  termplex_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} termplex_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  TERMPLEX_ACTION_CLOSE_TAB_MODE_THIS,
  TERMPLEX_ACTION_CLOSE_TAB_MODE_OTHER,
  TERMPLEX_ACTION_CLOSE_TAB_MODE_RIGHT,
} termplex_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} termplex_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  TERMPLEX_PROGRESS_STATE_REMOVE,
  TERMPLEX_PROGRESS_STATE_SET,
  TERMPLEX_PROGRESS_STATE_ERROR,
  TERMPLEX_PROGRESS_STATE_INDETERMINATE,
  TERMPLEX_PROGRESS_STATE_PAUSE,
} termplex_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  termplex_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} termplex_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} termplex_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} termplex_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} termplex_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} termplex_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} termplex_action_scrollbar_s;

// apprt.Action.Key
typedef enum {
  TERMPLEX_ACTION_QUIT,
  TERMPLEX_ACTION_NEW_WINDOW,
  TERMPLEX_ACTION_NEW_TAB,
  TERMPLEX_ACTION_CLOSE_TAB,
  TERMPLEX_ACTION_NEW_SPLIT,
  TERMPLEX_ACTION_CLOSE_ALL_WINDOWS,
  TERMPLEX_ACTION_TOGGLE_MAXIMIZE,
  TERMPLEX_ACTION_TOGGLE_FULLSCREEN,
  TERMPLEX_ACTION_TOGGLE_TAB_OVERVIEW,
  TERMPLEX_ACTION_TOGGLE_WINDOW_DECORATIONS,
  TERMPLEX_ACTION_TOGGLE_QUICK_TERMINAL,
  TERMPLEX_ACTION_TOGGLE_COMMAND_PALETTE,
  TERMPLEX_ACTION_TOGGLE_VISIBILITY,
  TERMPLEX_ACTION_TOGGLE_BACKGROUND_OPACITY,
  TERMPLEX_ACTION_MOVE_TAB,
  TERMPLEX_ACTION_GOTO_TAB,
  TERMPLEX_ACTION_GOTO_SPLIT,
  TERMPLEX_ACTION_GOTO_WINDOW,
  TERMPLEX_ACTION_RESIZE_SPLIT,
  TERMPLEX_ACTION_EQUALIZE_SPLITS,
  TERMPLEX_ACTION_TOGGLE_SPLIT_ZOOM,
  TERMPLEX_ACTION_PRESENT_TERMINAL,
  TERMPLEX_ACTION_SIZE_LIMIT,
  TERMPLEX_ACTION_RESET_WINDOW_SIZE,
  TERMPLEX_ACTION_INITIAL_SIZE,
  TERMPLEX_ACTION_CELL_SIZE,
  TERMPLEX_ACTION_SCROLLBAR,
  TERMPLEX_ACTION_RENDER,
  TERMPLEX_ACTION_INSPECTOR,
  TERMPLEX_ACTION_SHOW_GTK_INSPECTOR,
  TERMPLEX_ACTION_RENDER_INSPECTOR,
  TERMPLEX_ACTION_DESKTOP_NOTIFICATION,
  TERMPLEX_ACTION_SET_TITLE,
  TERMPLEX_ACTION_SET_TAB_TITLE,
  TERMPLEX_ACTION_PROMPT_TITLE,
  TERMPLEX_ACTION_PWD,
  TERMPLEX_ACTION_MOUSE_SHAPE,
  TERMPLEX_ACTION_MOUSE_VISIBILITY,
  TERMPLEX_ACTION_MOUSE_OVER_LINK,
  TERMPLEX_ACTION_RENDERER_HEALTH,
  TERMPLEX_ACTION_OPEN_CONFIG,
  TERMPLEX_ACTION_QUIT_TIMER,
  TERMPLEX_ACTION_FLOAT_WINDOW,
  TERMPLEX_ACTION_SECURE_INPUT,
  TERMPLEX_ACTION_KEY_SEQUENCE,
  TERMPLEX_ACTION_KEY_TABLE,
  TERMPLEX_ACTION_COLOR_CHANGE,
  TERMPLEX_ACTION_RELOAD_CONFIG,
  TERMPLEX_ACTION_CONFIG_CHANGE,
  TERMPLEX_ACTION_CLOSE_WINDOW,
  TERMPLEX_ACTION_RING_BELL,
  TERMPLEX_ACTION_UNDO,
  TERMPLEX_ACTION_REDO,
  TERMPLEX_ACTION_CHECK_FOR_UPDATES,
  TERMPLEX_ACTION_OPEN_URL,
  TERMPLEX_ACTION_SHOW_CHILD_EXITED,
  TERMPLEX_ACTION_PROGRESS_REPORT,
  TERMPLEX_ACTION_SHOW_ON_SCREEN_KEYBOARD,
  TERMPLEX_ACTION_COMMAND_FINISHED,
  TERMPLEX_ACTION_START_SEARCH,
  TERMPLEX_ACTION_END_SEARCH,
  TERMPLEX_ACTION_SEARCH_TOTAL,
  TERMPLEX_ACTION_SEARCH_SELECTED,
  TERMPLEX_ACTION_READONLY,
  TERMPLEX_ACTION_COPY_TITLE_TO_CLIPBOARD,
} termplex_action_tag_e;

typedef union {
  termplex_action_split_direction_e new_split;
  termplex_action_fullscreen_e toggle_fullscreen;
  termplex_action_move_tab_s move_tab;
  termplex_action_goto_tab_e goto_tab;
  termplex_action_goto_split_e goto_split;
  termplex_action_goto_window_e goto_window;
  termplex_action_resize_split_s resize_split;
  termplex_action_size_limit_s size_limit;
  termplex_action_initial_size_s initial_size;
  termplex_action_cell_size_s cell_size;
  termplex_action_scrollbar_s scrollbar;
  termplex_action_inspector_e inspector;
  termplex_action_desktop_notification_s desktop_notification;
  termplex_action_set_title_s set_title;
  termplex_action_set_title_s set_tab_title;
  termplex_action_prompt_title_e prompt_title;
  termplex_action_pwd_s pwd;
  termplex_action_mouse_shape_e mouse_shape;
  termplex_action_mouse_visibility_e mouse_visibility;
  termplex_action_mouse_over_link_s mouse_over_link;
  termplex_action_renderer_health_e renderer_health;
  termplex_action_quit_timer_e quit_timer;
  termplex_action_float_window_e float_window;
  termplex_action_secure_input_e secure_input;
  termplex_action_key_sequence_s key_sequence;
  termplex_action_key_table_s key_table;
  termplex_action_color_change_s color_change;
  termplex_action_reload_config_s reload_config;
  termplex_action_config_change_s config_change;
  termplex_action_open_url_s open_url;
  termplex_action_close_tab_mode_e close_tab_mode;
  termplex_surface_message_childexited_s child_exited;
  termplex_action_progress_report_s progress_report;
  termplex_action_command_finished_s command_finished;
  termplex_action_start_search_s start_search;
  termplex_action_search_total_s search_total;
  termplex_action_search_selected_s search_selected;
  termplex_action_readonly_e readonly;
} termplex_action_u;

typedef struct {
  termplex_action_tag_e tag;
  termplex_action_u action;
} termplex_action_s;

typedef void (*termplex_runtime_wakeup_cb)(void*);
typedef bool (*termplex_runtime_read_clipboard_cb)(void*,
                                                  termplex_clipboard_e,
                                                  void*);
typedef void (*termplex_runtime_confirm_read_clipboard_cb)(
    void*,
    const char*,
    void*,
    termplex_clipboard_request_e);
typedef void (*termplex_runtime_write_clipboard_cb)(void*,
                                                   termplex_clipboard_e,
                                                   const termplex_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*termplex_runtime_close_surface_cb)(void*, bool);
typedef bool (*termplex_runtime_action_cb)(termplex_app_t,
                                          termplex_target_s,
                                          termplex_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  termplex_runtime_wakeup_cb wakeup_cb;
  termplex_runtime_action_cb action_cb;
  termplex_runtime_read_clipboard_cb read_clipboard_cb;
  termplex_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  termplex_runtime_write_clipboard_cb write_clipboard_cb;
  termplex_runtime_close_surface_cb close_surface_cb;
} termplex_runtime_config_s;

// apprt.ipc.Target.Key
typedef enum {
  TERMPLEX_IPC_TARGET_CLASS,
  TERMPLEX_IPC_TARGET_DETECT,
} termplex_ipc_target_tag_e;

typedef union {
  char *klass;
} termplex_ipc_target_u;

typedef struct {
  termplex_ipc_target_tag_e tag;
  termplex_ipc_target_u target;
} chostty_ipc_target_s;

// apprt.ipc.Action.NewWindow
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} termplex_ipc_action_new_window_s;

typedef union {
  termplex_ipc_action_new_window_s new_window;
} termplex_ipc_action_u;

// apprt.ipc.Action.Key
typedef enum {
  TERMPLEX_IPC_ACTION_NEW_WINDOW,
} termplex_ipc_action_tag_e;

//-------------------------------------------------------------------
// Published API

int termplex_init(uintptr_t, char**);
void termplex_cli_try_action(void);
termplex_info_s termplex_info(void);
const char* termplex_translate(const char*);
void termplex_string_free(termplex_string_s);

termplex_config_t termplex_config_new();
void termplex_config_free(termplex_config_t);
termplex_config_t termplex_config_clone(termplex_config_t);
void termplex_config_load_cli_args(termplex_config_t);
void termplex_config_load_file(termplex_config_t, const char*);
void termplex_config_load_default_files(termplex_config_t);
void termplex_config_load_recursive_files(termplex_config_t);
void termplex_config_finalize(termplex_config_t);
bool termplex_config_get(termplex_config_t, void*, const char*, uintptr_t);
termplex_input_trigger_s termplex_config_trigger(termplex_config_t,
                                               const char*,
                                               uintptr_t);
uint32_t termplex_config_diagnostics_count(termplex_config_t);
termplex_diagnostic_s termplex_config_get_diagnostic(termplex_config_t, uint32_t);
termplex_string_s termplex_config_open_path(void);

termplex_app_t termplex_app_new(const termplex_runtime_config_s*,
                              termplex_config_t);
void termplex_app_free(termplex_app_t);
void termplex_app_tick(termplex_app_t);
void* termplex_app_userdata(termplex_app_t);
void termplex_app_set_focus(termplex_app_t, bool);
bool termplex_app_key(termplex_app_t, termplex_input_key_s);
bool termplex_app_key_is_binding(termplex_app_t, termplex_input_key_s);
void termplex_app_keyboard_changed(termplex_app_t);
void termplex_app_open_config(termplex_app_t);
void termplex_app_update_config(termplex_app_t, termplex_config_t);
bool termplex_app_needs_confirm_quit(termplex_app_t);
bool termplex_app_has_global_keybinds(termplex_app_t);
void termplex_app_set_color_scheme(termplex_app_t, termplex_color_scheme_e);

termplex_surface_config_s termplex_surface_config_new();

termplex_surface_t termplex_surface_new(termplex_app_t,
                                      const termplex_surface_config_s*);
void termplex_surface_free(termplex_surface_t);
void* termplex_surface_userdata(termplex_surface_t);
termplex_app_t termplex_surface_app(termplex_surface_t);
termplex_surface_config_s termplex_surface_inherited_config(termplex_surface_t, termplex_surface_context_e);
void termplex_surface_update_config(termplex_surface_t, termplex_config_t);
bool termplex_surface_needs_confirm_quit(termplex_surface_t);
bool termplex_surface_process_exited(termplex_surface_t);
void termplex_surface_refresh(termplex_surface_t);
void termplex_surface_draw(termplex_surface_t);
void termplex_surface_set_content_scale(termplex_surface_t, double, double);
void termplex_surface_set_focus(termplex_surface_t, bool);
void termplex_surface_set_occlusion(termplex_surface_t, bool);
void termplex_surface_set_size(termplex_surface_t, uint32_t, uint32_t);
termplex_surface_size_s termplex_surface_size(termplex_surface_t);
void termplex_surface_set_color_scheme(termplex_surface_t,
                                      termplex_color_scheme_e);
termplex_input_mods_e termplex_surface_key_translation_mods(termplex_surface_t,
                                                          termplex_input_mods_e);
bool termplex_surface_key(termplex_surface_t, termplex_input_key_s);
bool termplex_surface_key_is_binding(termplex_surface_t,
                                    termplex_input_key_s,
                                    termplex_binding_flags_e*);
void termplex_surface_text(termplex_surface_t, const char*, uintptr_t);
void termplex_surface_preedit(termplex_surface_t, const char*, uintptr_t);
bool termplex_surface_mouse_captured(termplex_surface_t);
bool termplex_surface_mouse_button(termplex_surface_t,
                                  termplex_input_mouse_state_e,
                                  termplex_input_mouse_button_e,
                                  termplex_input_mods_e);
void termplex_surface_mouse_pos(termplex_surface_t,
                               double,
                               double,
                               termplex_input_mods_e);
void termplex_surface_mouse_scroll(termplex_surface_t,
                                  double,
                                  double,
                                  termplex_input_scroll_mods_t);
void termplex_surface_mouse_pressure(termplex_surface_t, uint32_t, double);
void termplex_surface_ime_point(termplex_surface_t, double*, double*, double*, double*);
void termplex_surface_request_close(termplex_surface_t);
void termplex_surface_split(termplex_surface_t, termplex_action_split_direction_e);
void termplex_surface_split_focus(termplex_surface_t,
                                 termplex_action_goto_split_e);
void termplex_surface_split_resize(termplex_surface_t,
                                  termplex_action_resize_split_direction_e,
                                  uint16_t);
void termplex_surface_split_equalize(termplex_surface_t);
bool termplex_surface_binding_action(termplex_surface_t, const char*, uintptr_t);
void termplex_surface_complete_clipboard_request(termplex_surface_t,
                                                const char*,
                                                void*,
                                                bool);
bool termplex_surface_has_selection(termplex_surface_t);
bool termplex_surface_read_selection(termplex_surface_t, termplex_text_s*);
bool termplex_surface_read_text(termplex_surface_t,
                               termplex_selection_s,
                               termplex_text_s*);
void termplex_surface_free_text(termplex_surface_t, termplex_text_s*);

#ifdef __APPLE__
void termplex_surface_set_display_id(termplex_surface_t, uint32_t);
void* termplex_surface_quicklook_font(termplex_surface_t);
bool termplex_surface_quicklook_word(termplex_surface_t, termplex_text_s*);
#endif

termplex_inspector_t termplex_surface_inspector(termplex_surface_t);
void termplex_inspector_free(termplex_surface_t);
void termplex_inspector_set_focus(termplex_inspector_t, bool);
void termplex_inspector_set_content_scale(termplex_inspector_t, double, double);
void termplex_inspector_set_size(termplex_inspector_t, uint32_t, uint32_t);
void termplex_inspector_mouse_button(termplex_inspector_t,
                                    termplex_input_mouse_state_e,
                                    termplex_input_mouse_button_e,
                                    termplex_input_mods_e);
void termplex_inspector_mouse_pos(termplex_inspector_t, double, double);
void termplex_inspector_mouse_scroll(termplex_inspector_t,
                                    double,
                                    double,
                                    termplex_input_scroll_mods_t);
void termplex_inspector_key(termplex_inspector_t,
                           termplex_input_action_e,
                           termplex_input_key_e,
                           termplex_input_mods_e);
void termplex_inspector_text(termplex_inspector_t, const char*);

#ifdef __APPLE__
bool termplex_inspector_metal_init(termplex_inspector_t, void*);
void termplex_inspector_metal_render(termplex_inspector_t, void*, void*);
bool termplex_inspector_metal_shutdown(termplex_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
void termplex_set_window_background_blur(termplex_app_t, void*);

// Benchmark API, if available.
bool termplex_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* TERMPLEX_H */
