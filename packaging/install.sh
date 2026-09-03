#!/usr/bin/env bash
# Installs Logician for people without Homebrew: clone (or update), build
# release, symlink the binary onto PATH. Safe to re-run - re-running only
# updates the checkout and rebuilds. No `sudo` unless nothing else works,
# and even then it asks first. Every step prints exactly one line so a
# failure is easy to point at.
#
#   curl -fsSL https://raw.githubusercontent.com/BanneBanning/logician-mcp/main/packaging/install.sh | bash
#
set -u

# `set -u` makes an unset $HOME a hard crash instead of a clean message; a
# `curl | bash` can run in a shell thin enough to have dropped it. Tilde
# expansion falls back to the password database regardless of $HOME, so
# this recovers the same directory `set -u` would otherwise choke on.
HOME="${HOME:-$(cd ~ 2>/dev/null && pwd)}"
if [ -z "$HOME" ]; then
    printf 'error: could not determine your home directory ($HOME is unset).\n' >&2
    printf 'fix:   run this script from a normal interactive shell.\n' >&2
    exit 1
fi

REPO_URL="${LOGICIAN_REPO_URL:-https://github.com/BanneBanning/logician-mcp.git}"
INSTALL_DIR="${LOGICIAN_INSTALL_DIR:-$HOME/.logician}"
BIN_NAME="logician"

say() { printf '==> %s\n' "$1"; }
fail() {
    printf 'error: %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf 'fix:   %s\n' "$2" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. macOS version - Logician links AppKit/ApplicationServices APIs that
#    require macOS 13 (Ventura) or later, the same floor Package.swift
#    declares.
# ---------------------------------------------------------------------------
say "checking macOS version"
if [ "$(uname -s)" != "Darwin" ]; then
    fail "Logician only runs on macOS (this is $(uname -s))." \
         "Logic Pro itself is macOS-only, so there is no other platform to support."
fi
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${macos_major:-0}" -lt 13 ]; then
    fail "macOS $(sw_vers -productVersion) is too old; Logician needs macOS 13 (Ventura) or later." \
         "Update macOS via System Settings > General > Software Update, then re-run this script."
fi
say "macOS $(sw_vers -productVersion) OK"

# ---------------------------------------------------------------------------
# 2. Swift toolchain - ships with Xcode's Command Line Tools, not the full
#    Xcode.app. `swift --version` succeeding is the only thing that matters.
# ---------------------------------------------------------------------------
say "checking for the Swift toolchain"
if ! swift --version >/dev/null 2>&1; then
    fail "the Swift toolchain was not found (\`swift --version\` failed)." \
         "Install Apple's Command Line Tools, then re-run this script: xcode-select --install"
fi
say "Swift toolchain OK ($(swift --version 2>&1 | head -n1))"

# ---------------------------------------------------------------------------
# 3. Clone into ~/.logician, or update it if it is already there. A fetch +
#    fast-forward keeps a local `git pull` habit from clashing with a dirty
#    tree; this is a source checkout the script owns, not one the user hand-
#    edits, so a hard reset onto the tracked branch is the honest update.
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    say "updating existing checkout at $INSTALL_DIR"
    if ! git -C "$INSTALL_DIR" fetch --quiet origin; then
        fail "could not fetch updates into $INSTALL_DIR." \
             "Check your network connection, or delete $INSTALL_DIR and re-run this script for a clean clone."
    fi
    default_branch="$(git -C "$INSTALL_DIR" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
    default_branch="${default_branch:-main}"
    if ! git -C "$INSTALL_DIR" reset --quiet --hard "origin/$default_branch"; then
        fail "could not update $INSTALL_DIR to the latest $default_branch." \
             "Delete $INSTALL_DIR and re-run this script for a clean clone."
    fi
    say "updated to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
elif [ -d "$INSTALL_DIR" ]; then
    fail "$INSTALL_DIR exists but is not a git checkout." \
         "Move it aside (mv \"$INSTALL_DIR\" \"$INSTALL_DIR.bak\") and re-run this script."
else
    say "cloning into $INSTALL_DIR"
    if ! git clone --quiet "$REPO_URL" "$INSTALL_DIR"; then
        fail "could not clone $REPO_URL." \
             "Check your network connection and that the repository is reachable, then re-run this script."
    fi
    say "cloned $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------------------
# 4. Build release. This is the step a musician actually waits through -
#    a clean cold build; a re-run after an update only recompiles what
#    changed.
# ---------------------------------------------------------------------------
say "building logician (release) - this takes a minute or two on a clean checkout"
if ! (cd "$INSTALL_DIR" && swift build -c release --product "$BIN_NAME"); then
    fail "the build failed (see the compiler output above)." \
         "Re-run this script after fixing the reported error, or open an issue at https://github.com/BanneBanning/logician-mcp/issues with the output."
fi
built_binary="$INSTALL_DIR/.build/release/$BIN_NAME"
if [ ! -x "$built_binary" ]; then
    fail "the build reported success but $built_binary is missing." \
         "Re-run this script; if it keeps happening, open an issue at https://github.com/BanneBanning/logician-mcp/issues."
fi
say "build complete"

# ---------------------------------------------------------------------------
# 5. Symlink onto PATH: prefer /usr/local/bin (the traditional spot, no
#    PATH edit needed for most shells), fall back to ~/.local/bin, and only
#    ask for sudo if genuinely nothing else is writable.
# ---------------------------------------------------------------------------
link_into() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null
    ln -sf "$built_binary" "$dir/$BIN_NAME"
}

target_dir=""
if [ -w /usr/local/bin ] || { [ ! -e /usr/local/bin ] && [ -w /usr/local ]; }; then
    target_dir="/usr/local/bin"
elif mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; then
    target_dir="$HOME/.local/bin"
fi

if [ -n "$target_dir" ]; then
    link_into "$target_dir"
    say "linked $BIN_NAME into $target_dir (writable, no sudo needed)"
else
    say "no writable install directory found without sudo"
    printf 'Logician would like to symlink its binary into /usr/local/bin, which needs administrator rights.\n'
    printf 'Proceed with sudo? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES)
            if sudo mkdir -p /usr/local/bin && sudo ln -sf "$built_binary" /usr/local/bin/"$BIN_NAME"; then
                target_dir="/usr/local/bin"
                say "linked $BIN_NAME into /usr/local/bin (with sudo)"
            else
                fail "sudo install into /usr/local/bin failed." \
                     "Add $INSTALL_DIR/.build/release to your PATH by hand instead, e.g. in ~/.zshrc: export PATH=\"$INSTALL_DIR/.build/release:\$PATH\""
            fi
            ;;
        *)
            fail "declined sudo; no binary was linked onto PATH." \
                 "Add $INSTALL_DIR/.build/release to your PATH by hand instead, e.g. in ~/.zshrc: export PATH=\"$INSTALL_DIR/.build/release:\$PATH\""
            ;;
    esac
fi

case ":$PATH:" in
    *":$target_dir:"*) ;;
    *) say "note: $target_dir is not on your PATH yet - add it in your shell profile (e.g. ~/.zshrc), then open a new terminal" ;;
esac

# ---------------------------------------------------------------------------
# 6. Next steps - Homebrew cannot do any of these three either; they are the
#    same regardless of install method.
# ---------------------------------------------------------------------------
cat <<EOS

Logician is installed. Three one-time steps remain before it can drive Logic Pro:

  1. Register this binary with your MCP client (Claude, Gemini, Cursor, …).
     Run:
       logician setup

  2. Install the Mackie Control surface Logician talks to Logic through.
     \`logician setup\` prints the exact Control Surfaces > Setup steps and
     the port names to select (or drive it by hand - see the README).

  3. Grant Accessibility to your MCP client, for the tools that fall back
     to Logic's UI (macOS will prompt, or: System Settings > Privacy &
     Security > Accessibility).

Once all three are done, ask your agent to run "logic_health" - it verifies
every step above and names the exact fix for anything still missing.
EOS
