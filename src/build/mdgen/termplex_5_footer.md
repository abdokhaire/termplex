# FILES

_\$XDG_CONFIG_HOME/termplex/config.termplex_

: Location of the default configuration file.

_\$HOME/Library/Application Support/com.termplex.app/config.termplex_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.

_\$LOCALAPPDATA/termplex/config.termplex_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.termplex.app**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See GitHub issues: <https://github.com/termplex-org/termplex/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Termplex contributors <https://github.com/termplex-org/termplex/graphs/contributors>

# SEE ALSO

**termplex(1)**
