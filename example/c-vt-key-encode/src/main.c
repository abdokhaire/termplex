#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <termplex/vt.h>

int main() {
  TermplexKeyEncoder encoder;
  TermplexResult result = termplex_key_encoder_new(NULL, &encoder);
  assert(result == TERMPLEX_SUCCESS);

  // Set kitty flags with all features enabled
  termplex_key_encoder_setopt(encoder, TERMPLEX_KEY_ENCODER_OPT_KITTY_FLAGS, &(uint8_t){TERMPLEX_KITTY_KEY_ALL});

  // Create key event
  TermplexKeyEvent event;
  result = termplex_key_event_new(NULL, &event);
  assert(result == TERMPLEX_SUCCESS);
  termplex_key_event_set_action(event, TERMPLEX_KEY_ACTION_RELEASE);
  termplex_key_event_set_key(event, TERMPLEX_KEY_CONTROL_LEFT);
  termplex_key_event_set_mods(event, TERMPLEX_MODS_CTRL);
  printf("Encoding event: left ctrl release with all Kitty flags enabled\n");

  // Optionally, encode with null buffer to get required size. You can
  // skip this step and provide a sufficiently large buffer directly.
  // If there isn't enoug hspace, the function will return an out of memory
  // error.
  size_t required = 0;
  result = termplex_key_encoder_encode(encoder, event, NULL, 0, &required);
  assert(result == TERMPLEX_OUT_OF_MEMORY);
  printf("Required buffer size: %zu bytes\n", required);

  // Encode the key event. We don't use our required size above because
  // that was just an example; we know 128 bytes is enough.
  char buf[128];
  size_t written = 0;
  result = termplex_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
  assert(result == TERMPLEX_SUCCESS);
  printf("Encoded %zu bytes\n", written);

  // Print the encoded sequence (hex and string)
  printf("Hex: ");
  for (size_t i = 0; i < written; i++) printf("%02x ", (unsigned char)buf[i]);
  printf("\n");

  printf("String: ");
  for (size_t i = 0; i < written; i++) {
    if (buf[i] == 0x1b) {
      printf("\\x1b");
    } else {
      printf("%c", buf[i]);
    }
  }
  printf("\n");

  termplex_key_event_free(event);
  termplex_key_encoder_free(encoder);
  return 0;
}
