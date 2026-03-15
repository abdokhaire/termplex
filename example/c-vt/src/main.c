#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <termplex/vt.h>

int main() {
  TermplexOscParser parser;
  if (termplex_osc_new(NULL, &parser) != TERMPLEX_SUCCESS) {
    return 1;
  }
  
  // Setup change window title command to change the title to "hello"
  termplex_osc_next(parser, '0');
  termplex_osc_next(parser, ';');
  const char *title = "hello";
  for (size_t i = 0; i < strlen(title); i++) {
    termplex_osc_next(parser, title[i]);
  }
  
  // End parsing and get command
  TermplexOscCommand command = termplex_osc_end(parser, 0);
  
  // Get and print command type
  TermplexOscCommandType type = termplex_osc_command_type(command);
  printf("Command type: %d\n", type);
  
  // Extract and print the title
  if (termplex_osc_command_data(command, TERMPLEX_OSC_DATA_CHANGE_WINDOW_TITLE_STR, &title)) {
    printf("Extracted title: %s\n", title);
  } else {
    printf("Failed to extract title\n");
  }
  
  termplex_osc_free(parser);
  return 0;
}
