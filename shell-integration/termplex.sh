#!/bin/bash
# Termplex shell integration
# Source this file from your .bashrc or .zshrc:
#   source /path/to/termplex/shell-integration/termplex.sh

# Only activate if running inside termplex
# (Check for TERMPLEX_SOCKET or the termplex binary)

_termplex_report_pwd() {
    command termplex report pwd "$PWD" 2>/dev/null &
}

# Bash integration
if [ -n "$BASH_VERSION" ]; then
    # Append to PROMPT_COMMAND (don't override existing)
    if [[ "$PROMPT_COMMAND" != *"_termplex_report_pwd"* ]]; then
        PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_termplex_report_pwd"
    fi
fi

# Zsh integration
if [ -n "$ZSH_VERSION" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null
    if typeset -f add-zsh-hook > /dev/null 2>&1; then
        add-zsh-hook chpwd _termplex_report_pwd
    fi
    # Also report initial pwd
    _termplex_report_pwd
fi
