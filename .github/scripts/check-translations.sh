#!/usr/bin/env bash

set -euxo pipefail

old_pot=$(mktemp)
cp po/com.mitchellh.termplex.pot "$old_pot"
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old_pot" po/com.mitchellh.termplex.pot --use-untranslated

# Compare all other POs to current POT
for f in po/*.po; do
  # Ignore untranslated entries
  msgcmp --use-untranslated "$f" po/com.mitchellh.termplex.pot;
done
