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

**TERM**

: Defaults to `xterm-termplex`. Can be configured with the `term` configuration option.

**TERMPLEX_RESOURCES_DIR**

: Where the Termplex resources can be found.

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.termplex.app**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

**TERMPLEX_LOG**

: The `TERMPLEX_LOG` environment variable can be used to control which
destinations receive logs. Termplex currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

: Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `TERMPLEX_LOG` to `true` will enable all
destinations. Setting `TERMPLEX_LOG` to `false` will disable all destinations.

# BUGS

See GitHub issues: <https://github.com/termplex-org/termplex/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Termplex contributors <https://github.com/termplex-org/termplex/graphs/contributors>

# SEE ALSO

**termplex(5)**
