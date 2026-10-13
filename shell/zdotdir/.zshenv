# Termisu's ZDOTDIR bootstrap.
#
# The app points ZDOTDIR here for the shells it spawns, so this file runs FIRST, loads
# the integration hooks, and immediately hands control back to the user's real zsh
# startup chain. zsh resolves each startup file when it reaches it, so restoring ZDOTDIR
# before sourcing the user's .zshenv makes .zprofile/.zshrc/.zlogin load from the user's
# own directory exactly as they would without Termisu in the picture.
#
# The hooks survive the user's .zshrc because they are registered via add-zsh-hook,
# which appends -- a user overwriting precmd_functions wholesale opts out, and that is
# their call.

[[ -n "$TERMISU_INTEGRATION" && -f "$TERMISU_INTEGRATION" ]] && builtin source "$TERMISU_INTEGRATION"

if [[ -n "$TERMISU_USER_ZDOTDIR" ]]; then
    ZDOTDIR="$TERMISU_USER_ZDOTDIR"
    unset TERMISU_USER_ZDOTDIR
else
    unset ZDOTDIR
fi
[[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
