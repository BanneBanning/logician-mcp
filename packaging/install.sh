#!/usr/bin/env bash
# Installs Logician for people without Homebrew: clone (or update), check out
# a RELEASE TAG, build release, symlink the binary onto PATH. Safe to re-run -
# re-running only moves the checkout to the pinned tag and rebuilds, and it
# refuses rather than discard work if you have edited the checkout. No `sudo`
# unless nothing else works, and even then it asks first. Every step prints
# exactly one line so a failure is easy to point at.
#
#   curl -fsSL https://raw.githubusercontent.com/BanneBanning/logician-mcp/main/packaging/install.sh | bash
#
# What you get is the tag in DEFAULT_REF below - a fixed, citable commit that
# was built and tested by CI, not whatever `main` happens to be this hour.
# Override it with LOGICIAN_REF (a tag, a branch, or a commit SHA) when you
# specifically want something else:
#
#   curl -fsSL .../install.sh | LOGICIAN_REF=main bash
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

# The release this script installs. Bumped with `serverVersion` at every
# release (packaging/README.md step 1); PackagingSyncTests fails the suite if
# the two ever disagree, the same drift guard the Homebrew formula has.
DEFAULT_REF="v1.0.0-beta.1"
REF="${LOGICIAN_REF:-$DEFAULT_REF}"
# Set LOGICIAN_FORCE=1 to let the script discard local modifications in the
# checkout. Off by default: an update that silently ate someone's edits would
# be a worse failure than refusing to update.
FORCE="${LOGICIAN_FORCE:-0}"

say() { printf '==> %s\n' "$1"; }
fail() {
    printf 'error: %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf 'fix:   %s\n' "$2" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. macOS version. The BUILT binary deploys to macOS 13 (Ventura), which is
#    what Package.swift declares - but this script BUILDS, and building needs
#    the Swift 6 toolchain that Package.swift's `swift-tools-version: 6.0`
#    demands. Swift 6 ships in Xcode 16, and Apple installs Xcode 16 only on
#    macOS 14.5 or later, so 14.5 is the real floor for anyone compiling from
#    source - which is everyone, here and via Homebrew alike.
# ---------------------------------------------------------------------------
say "checking macOS version"
if [ "$(uname -s)" != "Darwin" ]; then
    fail "Logician only runs on macOS (this is $(uname -s))." \
         "Logic Pro itself is macOS-only, so there is no other platform to support."
fi
macos_version="$(sw_vers -productVersion)"
macos_major="$(printf '%s' "$macos_version" | cut -d. -f1)"
macos_minor="$(printf '%s' "$macos_version" | cut -d. -f2)"
if [ "${macos_major:-0}" -lt 14 ] ||
   { [ "${macos_major:-0}" -eq 14 ] && [ "${macos_minor:-0}" -lt 5 ]; }; then
    fail "macOS $macos_version cannot build Logician; building needs macOS 14.5 (Sonoma) or later." \
         "Logician compiles from source with Swift 6, which ships in Xcode 16, which Apple installs only on macOS 14.5+. Update macOS via System Settings > General > Software Update, then re-run this script."
fi
say "macOS $macos_version OK"

# ---------------------------------------------------------------------------
# 2. Swift toolchain - ships with Xcode's Command Line Tools, not the full
#    Xcode.app. `swift --version` succeeding is the only thing that matters.
# ---------------------------------------------------------------------------
say "checking for the Swift toolchain"
if ! swift --version >/dev/null 2>&1; then
    fail "the Swift toolchain was not found (\`swift --version\` failed)." \
         "Install Apple's Command Line Tools, then re-run this script: xcode-select --install"
fi
swift_banner="$(swift --version 2>&1 | head -n1)"
swift_major="$(printf '%s' "$swift_banner" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p')"
if [ "${swift_major:-0}" -lt 6 ]; then
    fail "this Mac has Swift ${swift_major:-an unrecognised version} ($swift_banner); Logician needs Swift 6." \
         "Update Apple's Command Line Tools (Swift 6 ships with Xcode 16, macOS 14.5+): xcode-select --install, or install Xcode 16 or later from the App Store."
fi
say "Swift toolchain OK ($swift_banner)"

# ---------------------------------------------------------------------------
# 3. Clone into ~/.logician, or update it if it is already there, and put it
#    on $REF - a release TAG by default, not whatever `main` holds right now.
#    Two rules make a re-run safe. Nothing is discarded unless you say so:
#    the update refuses on a modified checkout and names the ways out, and
#    LOGICIAN_FORCE=1 is the only path that resets over your changes (and it
#    announces itself). And the move onto the tag is a detached checkout, so
#    local commits on a branch stay reachable instead of being reset away.
# ---------------------------------------------------------------------------

# Which object $REF names, once the fetch has brought it in: a tag first (the
# release case), then a remote branch, then anything git can resolve, which
# covers a raw commit SHA.
resolve_ref() {
    for candidate in "refs/tags/$REF" "refs/remotes/origin/$REF" "$REF"; do
        if git -C "$INSTALL_DIR" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

check_out_ref() {
    resolved="$(resolve_ref)" || fail \
        "$REF does not exist in $REPO_URL." \
        "If you meant the development branch, re-run with LOGICIAN_REF=main; otherwise check the tag name at https://github.com/BanneBanning/logician-mcp/tags."
    if ! git -C "$INSTALL_DIR" checkout --quiet --detach "$resolved"; then
        fail "could not check out $REF in $INSTALL_DIR." \
             "Move it aside (mv \"$INSTALL_DIR\" \"$INSTALL_DIR.bak\") and re-run this script for a clean clone."
    fi
    say "checked out $REF ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"
}

if [ -d "$INSTALL_DIR/.git" ]; then
    say "updating existing checkout at $INSTALL_DIR"
    if ! git -C "$INSTALL_DIR" fetch --quiet --tags origin; then
        fail "could not fetch updates into $INSTALL_DIR." \
             "Check your network connection, or delete $INSTALL_DIR and re-run this script for a clean clone."
    fi
    # Tracked files the user has changed. Untracked files (.build above all)
    # are none of this script's business and are left alone either way.
    local_changes="$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ -n "$local_changes" ]; then
        if [ "$FORCE" = "1" ]; then
            say "LOGICIAN_FORCE=1: DISCARDING your local changes in $INSTALL_DIR"
            printf '%s\n' "$local_changes" >&2
            if ! git -C "$INSTALL_DIR" reset --quiet --hard HEAD; then
                fail "could not discard local changes in $INSTALL_DIR." \
                     "Move it aside (mv \"$INSTALL_DIR\" \"$INSTALL_DIR.bak\") and re-run this script for a clean clone."
            fi
        else
            printf '%s\n' "$local_changes" >&2
            fail "$INSTALL_DIR has local modifications (listed above); refusing to overwrite them." \
                 "Commit or stash them, or move the checkout aside (mv \"$INSTALL_DIR\" \"$INSTALL_DIR.bak\"), or re-run with LOGICIAN_FORCE=1 to DISCARD them."
        fi
    fi
    check_out_ref
elif [ -d "$INSTALL_DIR" ]; then
    fail "$INSTALL_DIR exists but is not a git checkout." \
         "Move it aside (mv \"$INSTALL_DIR\" \"$INSTALL_DIR.bak\") and re-run this script."
else
    say "cloning into $INSTALL_DIR"
    if ! git clone --quiet "$REPO_URL" "$INSTALL_DIR"; then
        fail "could not clone $REPO_URL." \
             "Check your network connection and that the repository is reachable, then re-run this script."
    fi
    check_out_ref
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
