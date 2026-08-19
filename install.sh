#!/usr/bin/env bash
# Install the Pathpoint `p` CLI on macOS or Linux.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/outline-insurance/mcp/main/install.sh | bash
#
# Env overrides:
#   P_REPO            Public release repo (default: outline-insurance/mcp)
#   P_VERSION         Version to install, e.g. "0.1.0" (default: latest)
#   P_INSTALL_DIR     Where to drop the `p` binary (default: $HOME/.local/bin)
#   P_SKILL_DIR       Claude Code skill dir (default: $HOME/.claude/skills/Pathpoint)
#   P_NO_MODIFY_PATH  Set to 1 to keep the installer out of your shell rc file;
#                     it prints the PATH line for you to add instead
#
# Structure: every step is a function, and main() only runs behind the
# BASH_SOURCE guard at the bottom, so install_test.sh can `source` this file
# and exercise each piece against a sandbox HOME without installing anything.

set -euo pipefail

# Shared state with top-level defaults so individual functions can be called
# from tests without running the whole pipeline. main() re-derives the
# environment-dependent values via init_globals.
PATH_MARK_BEGIN="# >>> pathpoint p installer >>>"
PATH_MARK_END="# <<< pathpoint p installer <<<"
PATH_RC_UPDATED=no
DESKTOP_CONFIG_RESULT=absent
CHECKSUM_VERIFIED=no

# Derive every install target from the environment. Kept in a function (not
# top-level code) so tests control HOME and the P_* overrides first.
init_globals() {
  REPO="${P_REPO:-outline-insurance/mcp}"
  VERSION="${P_VERSION:-latest}"
  PINNED_VERSION="${P_VERSION:-}"
  INSTALL_DIR="${P_INSTALL_DIR:-$HOME/.local/bin}"
  SKILL_DIR="${P_SKILL_DIR:-$HOME/.claude/skills/Pathpoint}"

  case "$(uname -s)" in
    Darwin) OS=darwin; CLAUDE_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
    Linux)  OS=linux;  CLAUDE_CFG="$HOME/.config/Claude/claude_desktop_config.json" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Prints the pathpoint plugin's actual state: "enabled", "disabled",
# "absent", or "unknown" when it can't be determined (no python3, or a
# claude CLI without `plugin list --json`). Callers treat the states
# asymmetrically: a disabled plugin must not suppress the plain-skill
# fallback (the user would be left with no active skill), while "unknown"
# must not override a successful install (every python3-less machine would
# get a duplicate skill instead).
pathpoint_plugin_state() {
  local out
  command -v python3 >/dev/null 2>&1 || { echo unknown; return; }
  out="$(claude plugin list --json 2>/dev/null)" || { echo unknown; return; }
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    plugins = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
# The plugin can be installed at several scopes at once; if any entry is
# enabled the skill will load, so that is the effective state.
entries = [p for p in plugins if p.get("id") == "pathpoint@outline-insurance"]
if not entries:
    print("absent")
elif any(p.get("enabled") for p in entries):
    print("enabled")
else:
    print("disabled")
' || echo unknown
}

# Prints which source the registered `outline-insurance` marketplace points
# at: "ours" (some field references this repo), "other" (the name is taken
# by a different source), "absent", or "unknown" when it can't be determined.
# Only "other" changes behavior — the installer must not refresh or trust a
# marketplace it didn't register, since `marketplace update` and
# `plugin install` address it by name alone.
pathpoint_marketplace_state() {
  local out
  command -v python3 >/dev/null 2>&1 || { echo unknown; return; }
  out="$(claude plugin marketplace list --json 2>/dev/null)" || { echo unknown; return; }
  printf '%s' "$out" | P_MP_REPO="$REPO" python3 -c '
import json, os, sys
try:
    mps = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
repo = os.environ["P_MP_REPO"].strip().lower()

# Strict equality against known source shapes — substring matching would let
# a hostile URL like https://evil.example/outline-insurance/mcp pass. A
# legitimate-but-unrecognized shape reads as "other", which only costs the
# plugin path (the plain skill still installs).
def norm(v):
    v = str(v).strip().lower().rstrip("/")
    return v[:-4] if v.endswith(".git") else v

expected = {
    repo,
    "https://github.com/" + repo,
    "http://github.com/" + repo,
    "git@github.com:" + repo,
    "ssh://git@github.com/" + repo,
}
for m in mps:
    if isinstance(m, dict) and m.get("name") == "outline-insurance":
        ours = (norm(m.get("source", "")) == "github" and norm(m.get("repo", "")) == repo) \
            or any(isinstance(v, str) and norm(v) in expected for v in m.values())
        print("ours" if ours else "other"); sys.exit(0)
print("absent")
' || echo unknown
}

# Resolve "latest" to a concrete tag via the GitHub API.
# Uses awk rather than sed \s since BSD sed on macOS doesn't support \s.
# The `|| VERSION=""` matters: under `set -euo pipefail` a curl failure in the
# command substitution would abort the script before the explanation below
# ever printed — and a failed curl here is the NORMAL failure mode, because
# the unauthenticated GitHub API allows 60 requests/hour per IP (an office
# behind one NAT can exhaust that fast).
resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | awk -F '"' '/"tag_name":/ { sub(/^v/, "", $4); print $4; exit }')" || VERSION=""
    if [ -z "$VERSION" ]; then
      echo "Could not resolve the latest version of p from $REPO." >&2
      echo "This is usually a temporary network problem or the GitHub API rate limit" >&2
      echo "(60 requests/hour per IP address for unauthenticated calls)." >&2
      echo "" >&2
      echo "Retry in a few minutes, or pin a version to skip the lookup entirely:" >&2
      echo "  P_VERSION=<version> bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh)\"" >&2
      echo "Available versions: https://github.com/$REPO/releases" >&2
      exit 1
    fi
  fi
}

download_asset() {
  echo "Downloading p $VERSION ($OS/$ARCH)..."
  curl -fsSL "$BASE_URL/$ASSET" -o "$TMP/$ASSET"
}

# Verify checksum if checksums.txt is published. CHECKSUM_VERIFIED records
# whether the comparison actually happened (as opposed to being skipped for a
# missing checksums.txt, a missing hasher, or an asset absent from the list) —
# the macOS quarantine decision below depends on knowing the difference.
#
# Every degradation is a note-and-continue, never a silent stop: under
# `set -euo pipefail` an unguarded no-match grep here used to kill the whole
# script between "Downloading..." and "Installed" with no output at all. The
# asset lookup is an exact string comparison in awk, not a regex — the dots
# in the asset name must not match arbitrary characters (install.ps1 does the
# same with [regex]::Escape). A real MISMATCH is different: stopping then is
# the entire point of publishing checksums, so it stays a hard exit 1.
verify_checksum() {
  CHECKSUM_VERIFIED=no
  local skip_reason="" hasher="" expected="" actual=""
  if ! curl -fsSL "$BASE_URL/checksums.txt" -o "$TMP/checksums.txt" 2>/dev/null; then
    skip_reason="the release's checksums.txt could not be downloaded"
  else
    if command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
    fi
    if [ -z "$hasher" ]; then
      skip_reason="no SHA-256 tool (shasum or sha256sum) is installed locally"
    else
      expected="$(awk -v asset="$ASSET" '$2 == asset { print $1; exit }' "$TMP/checksums.txt" | tr 'A-F' 'a-f')"
      # An entry that isn't exactly 64 hex chars is corrupt (or tampered
      # with); treat it like a missing entry rather than echoing arbitrary
      # bytes from the download host into the terminal via the mismatch
      # message below. Parity with install.ps1's ^[0-9a-f]{64}$ check.
      case "$expected" in
        *[!0-9a-f]*) expected="" ;;
      esac
      if [ -n "$expected" ] && [ "${#expected}" -ne 64 ]; then
        expected=""
      fi
      if [ -z "$expected" ]; then
        skip_reason="$ASSET has no usable entry in the release's checksums.txt"
      else
        # shellcheck disable=SC2086 # $hasher is deliberately two words ("shasum -a 256")
        actual="$($hasher "$TMP/$ASSET" | awk '{print $1}')"
        if [ "$expected" != "$actual" ]; then
          echo "Checksum mismatch for $ASSET (expected $expected, got $actual)" >&2
          exit 1
        fi
        CHECKSUM_VERIFIED=yes
      fi
    fi
  fi
  if [ "$CHECKSUM_VERIFIED" = "no" ]; then
    echo "Note: could not verify the download's checksum ($skip_reason)." >&2
    echo "  Continuing." >&2
  fi
}

install_binary() {
  tar -xzf "$TMP/$ASSET" -C "$TMP"
  mkdir -p "$INSTALL_DIR"
  install -m 755 "$TMP/p" "$INSTALL_DIR/p"
  echo "Installed $INSTALL_DIR/p"
}

# The binary is unsigned, so on macOS a quarantine attribute makes Gatekeeper
# kill it on first run with "cannot be opened because the developer cannot be
# verified". Clear it, but only when it is actually set and only out loud:
# silently stripping an OS safeguard is not something an installer should do
# without saying so.
#
# What justifies clearing it at all is the SHA-256 check above, which is a
# stronger statement about this file than Gatekeeper can make about an
# unsigned binary — and the fact that the user is already running this script
# from curl, so the trust decision was made a step earlier. If the checksum
# could not be verified, leave the attribute alone and let Gatekeeper have the
# last word.
clear_quarantine() {
  if [ "$OS" = "darwin" ] && command -v xattr >/dev/null 2>&1; then
    if xattr -p com.apple.quarantine "$INSTALL_DIR/p" >/dev/null 2>&1; then
      if [ "${CHECKSUM_VERIFIED:-no}" = "yes" ]; then
        if xattr -d com.apple.quarantine "$INSTALL_DIR/p" 2>/dev/null; then
          echo "Cleared the macOS quarantine flag (the download's SHA-256 matched the published checksum)."
        else
          # Don't claim success we didn't achieve: if the removal failed, macOS
          # will still block p, so tell the user how to clear it themselves.
          echo "Note: could not clear the macOS quarantine flag automatically."
          echo "  macOS will refuse to run p until you allow it: System Settings → Privacy & Security → Open Anyway,"
          echo "  or clear it yourself with: xattr -d com.apple.quarantine \"$INSTALL_DIR/p\""
        fi
      else
        echo "Note: the download could not be checksum-verified, so the macOS quarantine flag was left in place."
        echo "  macOS will refuse to run p until you allow it: System Settings → Privacy & Security → Open Anyway,"
        echo "  or clear it yourself with: xattr -d com.apple.quarantine \"$INSTALL_DIR/p\""
      fi
    fi
  fi
}

print_path_hint() {
  echo ""
  echo "Note: $INSTALL_DIR is not on your PATH."
  echo "Add this to your shell rc (~/.zshrc, ~/.bashrc, etc.):"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
}

# Build the exact PATH line each shell arm writes, with the install dir
# escaped for that shell. Shared by the writer and the stale-marker check in
# configure_path so the two can never drift: the check greps for precisely
# the line the writer would emit. In both shells the dir is single-quoted
# (with that shell's own escape for an embedded quote) so that $(...) or
# backticks planted in an exotic P_INSTALL_DIR can never execute at shell
# startup.
posix_path_line() { # dir
  # $PATH stays double-quoted so it expands when sourced.
  printf "export PATH='%s':\"\$PATH\"" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

fish_path_line() { # dir
  # fish doesn't read POSIX `export`; fish_add_path prepends to
  # $fish_user_paths and is itself idempotent. fish's single-quote escapes:
  # backslash first, then quote.
  printf "fish_add_path --global '%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"
}

# Make `p` reachable by name. Policy note: this installer used to refuse to
# touch shell rc files and only printed a hint — which in practice left
# first-time users staring at "command not found" right after "Done." The
# stance is now reversed: when $INSTALL_DIR isn't on PATH, append a clearly
# marked block to the current shell's rc file. The markers make the change
# easy to audit and remove, the exact-begin-marker guard keeps re-runs from
# stacking duplicates (`p update` re-invokes this script on every upgrade),
# and P_NO_MODIFY_PATH=1 restores the old hint-only behavior. An unrecognized
# login shell also falls back to the hint — guessing the wrong rc file is
# worse than not writing one.
configure_path() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) return 0 ;; # already reachable — no write, no noise
  esac

  if [ "${P_NO_MODIFY_PATH:-}" = "1" ]; then
    print_path_hint
    return 0
  fi

  local shell_name rc_file
  shell_name="$(basename "${SHELL:-sh}")"
  case "$shell_name" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash)
      # macOS terminals start bash as a LOGIN shell, which reads
      # ~/.bash_profile and never ~/.bashrc; Linux terminals do the opposite.
      if [ "$OS" = "darwin" ]; then
        rc_file="$HOME/.bash_profile"
      else
        rc_file="$HOME/.bashrc"
      fi
      ;;
    fish) rc_file="$HOME/.config/fish/conf.d/pathpoint.fish" ;;
    *)
      print_path_hint
      return 0
      ;;
  esac

  local path_line
  if [ "$shell_name" = "fish" ]; then
    path_line="$(fish_path_line "$INSTALL_DIR")"
  else
    path_line="$(posix_path_line "$INSTALL_DIR")"
  fi

  if [ -f "$rc_file" ] && grep -qxF "$PATH_MARK_BEGIN" "$rc_file"; then
    # Our block is already there. Never claim it covers the CURRENT install
    # dir unless it actually names it — a re-run with a changed P_INSTALL_DIR
    # keeps the old block (we don't rewrite user rc files), so say so. Match
    # the exact line this run would write: a loose substring grep for the dir
    # would be satisfied by a prefix of some other path or by an unrelated
    # comment, and then claim coverage the block doesn't provide.
    if grep -qxF "$path_line" "$rc_file"; then
      PATH_RC_UPDATED=yes
      echo "Note: $INSTALL_DIR is already configured in $rc_file but isn't active in"
      echo "this shell. Open a new shell (or source that file) to run p by name."
    else
      echo "warning: $rc_file has a pathpoint PATH block, but for a different directory" >&2
      echo "         than $INSTALL_DIR. Edit the block between the pathpoint markers" >&2
      echo "         yourself — this installer never rewrites existing rc content." >&2
    fi
    return 0
  fi

  # Every write below degrades instead of aborting: an unwritable rc target
  # (a directory squatting on the rc path, an unwritable parent dir) would
  # otherwise kill the whole install under `set -e` mid-run — final report
  # and all — and a PATH nicety is never worth losing the install over.
  # Each append is one `printf` SIMPLE command on purpose: when a redirection
  # fails on a compound command, bash aborts the surrounding statement
  # instead of returning nonzero, so an `if ! { ...; } >> file` guard never
  # fires. `2>/dev/null` sits before `>>` because redirections apply left to
  # right — after a failed `>>` the "Is a directory" noise would otherwise
  # land on the real stderr.
  local write_failed=no
  if ! mkdir -p "$(dirname "$rc_file")" 2>/dev/null; then
    write_failed=yes
  elif [ "$shell_name" = "fish" ]; then
    # The markers double as valid fish comments, and conf.d files load on
    # every fish startup.
    if ! printf '%s\n%s\n%s\n' "$PATH_MARK_BEGIN" "$path_line" "$PATH_MARK_END" \
        2>/dev/null >> "$rc_file"; then
      write_failed=yes
    fi
  else
    # Leading blank line so the block lands on its own lines even when the
    # rc file doesn't end with a newline.
    if ! printf '\n%s\n%s\n%s\n' "$PATH_MARK_BEGIN" "$path_line" "$PATH_MARK_END" \
        2>/dev/null >> "$rc_file"; then
      write_failed=yes
    fi
  fi
  if [ "$write_failed" = "yes" ]; then
    echo "warning: could not write the PATH block to $rc_file (the target or its" >&2
    echo "         parent directory isn't writable). Add the line yourself instead:" >&2
    print_path_hint
    return 0
  fi
  PATH_RC_UPDATED=yes
  echo "Added $INSTALL_DIR to your PATH via a marked block in $rc_file"
  echo "(set P_NO_MODIFY_PATH=1 to keep this installer out of shell rc files)."
  echo "Open a new shell (or: source $rc_file) for it to take effect."
}

plugin_fallback_note() {
  echo "Couldn't install the Claude Code plugin automatically; falling back to the plain skill."
  echo "To retry the plugin by hand:"
  echo "  claude plugin marketplace add $MARKETPLACE_URL"
  echo "  claude plugin install pathpoint@outline-insurance --scope user"
}

plugin_path_note() {
  # The plugin starts its MCP server as `p` from PATH; without the install
  # dir on PATH the skill loads but the tools never start. When
  # configure_path already wrote (or found) the rc block, the missing piece
  # is a shell restart, not another edit — say the right one.
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) return 0 ;;
  esac
  if [ "$PATH_RC_UPDATED" = "yes" ]; then
    echo "note: the plugin's MCP server runs \`p\` from your PATH. The PATH change written"
    echo "      above only applies to new shells — start Claude Code from a new shell."
  else
    echo "note: the plugin's MCP server runs \`p\` from your PATH. Add $INSTALL_DIR"
    echo "      to PATH (see above) or Claude Code won't be able to start it."
  fi
}

# Claude Code integration. Preferred path: register the public repo as a
# plugin marketplace and install the versioned `pathpoint` plugin — skill
# plus the `p mcp-serve` MCP server — so `claude plugin update` (or
# re-running this installer) picks up new releases. Falls back to a plain
# skills-dir copy when the `claude` CLI isn't on PATH or its plugin
# commands fail (e.g. an older CLI). All of this is best-effort — it must
# never fail the binary install.
configure_claude_code() {
  PLUGIN_INSTALLED="false"
  PLUGIN_STATE="absent"
  if command -v claude >/dev/null 2>&1; then
    # Explicit HTTPS git URL: the bare <owner>/<repo> shorthand clones over
    # SSH by default, which most users haven't set up for GitHub.
    MARKETPLACE_URL="https://github.com/$REPO.git"
    PLUGIN_CMDS_OK="false"

    # A marketplace named `outline-insurance` that points somewhere else means
    # the name has been claimed by another source — every plugin command below
    # addresses the marketplace by name, so running them would install from
    # the impostor. Refuse the whole plugin path and use the plain skill.
    MP_STATE="$(pathpoint_marketplace_state)"
    if [ "$MP_STATE" = "other" ]; then
      echo "warning: a plugin marketplace named 'outline-insurance' is already registered but" >&2
      echo "         points at a different source than $MARKETPLACE_URL." >&2
      echo "         Refusing to install or trust the plugin through it; using the plain" >&2
      echo "         skill instead. If that marketplace isn't something you set up on" >&2
      echo "         purpose, replace it and re-run this installer:" >&2
      echo "           claude plugin marketplace remove outline-insurance" >&2
    elif [ -n "$PINNED_VERSION" ]; then
      # A pinned install must be fully pinned. The plugin tracks the repo's
      # main branch (i.e. the latest release), so use the pinned release's own
      # SKILL.md below instead.
      echo "P_VERSION is set; skipping the Claude Code plugin (it tracks the latest release)."
    else
      echo "Claude Code detected; installing the Pathpoint plugin..."
      # `update` first: on re-runs it refreshes the already-registered catalog
      # (a stale catalog would pin the old plugin version); on first runs it
      # fails fast and `add` registers the marketplace.
      if claude plugin marketplace update outline-insurance >/dev/null 2>&1 \
         || claude plugin marketplace add "$MARKETPLACE_URL" >/dev/null 2>&1; then
        if claude plugin install pathpoint@outline-insurance --scope user >/dev/null 2>&1 \
           || claude plugin update pathpoint@outline-insurance >/dev/null 2>&1; then
          PLUGIN_CMDS_OK="true"
        fi
      fi
    fi

    # Exit codes above aren't the full story: `plugin install` on an
    # already-installed-but-disabled plugin succeeds without enabling it (the
    # user's disable persists by design). Probe the actual state and treat it
    # per pathpoint_plugin_state's contract. Skipped entirely when the
    # marketplace name is claimed by another source — a plugin from there must
    # not suppress the plain skill, whatever state it's in.
    [ "$MP_STATE" = "other" ] || PLUGIN_STATE="$(pathpoint_plugin_state)"
    case "$PLUGIN_STATE" in
      enabled)
        PLUGIN_INSTALLED="true"
        if [ -n "$PINNED_VERSION" ]; then
          echo "note: the pathpoint Claude Code plugin is already installed and tracks the latest"
          echo "      release — P_VERSION pins the binary only. To pin fully, remove it first:"
          echo "        claude plugin uninstall pathpoint@outline-insurance"
        elif [ "$PLUGIN_CMDS_OK" = "true" ]; then
          echo "Installed the Pathpoint plugin for Claude Code (pathpoint@outline-insurance)."
          plugin_path_note
        else
          echo "Plugin refresh failed; keeping the already-installed pathpoint plugin."
        fi
        ;;
      disabled)
        echo "note: the pathpoint Claude Code plugin is installed but disabled; leaving it"
        echo "      alone and using the plain skill instead. To switch to the plugin:"
        echo "        claude plugin enable pathpoint@outline-insurance"
        echo "        rm \"$SKILL_DIR/SKILL.md\"   # then drop the plain copy so it isn't loaded twice"
        ;;
      unknown)
        if [ "$PLUGIN_CMDS_OK" = "true" ]; then
          PLUGIN_INSTALLED="true"
          echo "Installed the Pathpoint plugin for Claude Code (pathpoint@outline-insurance)."
          plugin_path_note
        elif [ -z "$PINNED_VERSION" ]; then
          plugin_fallback_note
        fi
        ;;
      *) # absent
        if [ "$MP_STATE" != "other" ] && [ -z "$PINNED_VERSION" ]; then
          plugin_fallback_note
        fi
        ;;
    esac
  fi

  if [ "$PLUGIN_INSTALLED" = "true" ]; then
    # Move aside — not delete, in case the user customized it — the plain
    # skill copy earlier installers left behind. Alongside the plugin it would
    # load as a duplicate Pathpoint skill; as SKILL.md.bak it loads as nothing.
    # Only when the plugin is CONFIRMED enabled: with the state unknown (no
    # python3), a duplicate skill is benign but removing what might be the
    # only active copy is not.
    if [ "$PLUGIN_STATE" = "enabled" ] && [ -f "$SKILL_DIR/SKILL.md" ]; then
      # Never clobber an earlier backup — it may hold user-customized content
      # while today's SKILL.md is just a pristine installer copy.
      SKILL_BAK="$SKILL_DIR/SKILL.md.bak"
      [ -e "$SKILL_BAK" ] && SKILL_BAK="$SKILL_DIR/SKILL.md.bak.$(date +%s)"
      if mv "$SKILL_DIR/SKILL.md" "$SKILL_BAK" 2>/dev/null; then
        echo "Moved legacy skill copy aside to $SKILL_BAK (superseded by the plugin)."
      else
        echo "warning: couldn't move $SKILL_DIR/SKILL.md aside; move or delete it by hand" >&2
        echo "         so the skill isn't loaded twice alongside the plugin." >&2
      fi
    fi
  # Plain-skill fallback: install SKILL.md from the release into the Claude
  # Code skills dir.
  elif curl -fsSL "$BASE_URL/SKILL.md" -o "$TMP/SKILL.md" 2>/dev/null; then
    mkdir -p "$SKILL_DIR"
    cp "$TMP/SKILL.md" "$SKILL_DIR/SKILL.md"
    echo "Installed Pathpoint skill to $SKILL_DIR/"
  fi
}

# The manual-paste fallback. A full document rather than a bare entry so the
# no-config-yet case is copy-paste-done; users with an existing config are
# told to merge just the "pathpoint" entry (pasting a whole document into a
# populated file is invalid JSON, and replacing the file loses the app's own
# preferences alongside any other MCP servers — same reasoning as install.ps1).
manual_config_snippet() {
  # The install dir is interpolated into displayed JSON, so it has to be
  # JSON-escaped: a directory containing a double quote or backslash would
  # otherwise render a snippet the app rejects as invalid JSON. Backslash
  # first, then quote — the other order would double-escape the quotes'
  # own backslashes. (install.ps1 gets this for free via ConvertTo-Json.)
  local dir_json
  dir_json=$(printf '%s' "$INSTALL_DIR" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  cat <<EOF
{
  "mcpServers": {
    "pathpoint": {
      "command": "$dir_json/p",
      "args": ["mcp-serve"]
    }
  }
}
EOF
}

# Configure the Claude Desktop MCP server entry and stage the skill zip.
#
# The config write is delegated to the binary we just installed
# (`p install-desktop-config`) instead of the old jq edit, for two reasons:
# jq was a dependency many machines didn't have (the config was silently
# skipped), and the jq pipeline had a false-success bug — on malformed user
# JSON the merge failed, but the script printed "Configured" anyway and left
# a stray .tmp file behind. The binary owns a single merge implementation
# shared with Windows and reports its own outcome; its exit code is the only
# signal trusted here. A binary older than the subcommand (a pinned
# P_VERSION) exits non-zero and lands in the same manual fallback as a
# genuine failure — no success message either way.
configure_claude_desktop() {
  if [ -d "$(dirname "$CLAUDE_CFG")" ]; then
    if "$INSTALL_DIR/p" install-desktop-config; then
      DESKTOP_CONFIG_RESULT=ok
    else
      DESKTOP_CONFIG_RESULT=failed
      echo "warning: the Claude Desktop MCP server was NOT configured — \`p install-desktop-config\`" >&2
      echo "         exited with an error (details above, if any; a P_VERSION-pinned older p" >&2
      echo "         predates that command). Claude Desktop can't see the Pathpoint tools" >&2
      echo "         until this is fixed — try again later with: p install-desktop-config" >&2
      echo "To wire it up by hand instead, save this as $CLAUDE_CFG —"
      echo "or if that file already exists, merge the \"pathpoint\" entry into its \"mcpServers\" object:"
      manual_config_snippet
    fi
    stage_skill_zip
  else
    DESKTOP_CONFIG_RESULT=absent
    # Same report as install.ps1's not-detected branch: name the exact path
    # probed instead of a bare "not detected", and say how to make detection
    # succeed — Claude Desktop creates its config directory on first launch,
    # so launching it once is usually the whole fix.
    echo "Claude Desktop not detected — no config directory for:"
    echo "  $CLAUDE_CFG"
    echo "If it is installed, launch it once and re-run this installer (or run:"
    echo "p install-desktop-config) — it creates its config directory on first run."
    echo ""
    echo "To wire it up by hand, save this as that file — or if it already exists,"
    echo "merge the \"pathpoint\" entry into its \"mcpServers\" object:"
    manual_config_snippet
  fi
}

# Claude Desktop skills and plugins don't have a local install path — they're
# uploaded to Anthropic's servers via the in-app Settings UI. Stage
# the zip somewhere obvious so the user only has to drag-and-drop.
#
# pathpoint-plugin.zip is preferred: the current dialog is "Upload local
# plugin", whose validator wants a .claude-plugin/plugin.json manifest and
# rejects the bare SKILL.md that pathpoint-skill.zip contains. Releases before
# 0.0.30 publish only the skill zip, so P_VERSION-pinned installs fall back to
# it — and the failed fetch is cleaned up, because curl -o truncates the
# destination before it gives up and an empty zip is worse than none.
stage_skill_zip() {
  ZIP_DIR="$HOME/Downloads"
  [ -d "$ZIP_DIR" ] || ZIP_DIR="$HOME"
  PLUGIN_ZIP_DEST="$ZIP_DIR/pathpoint-plugin.zip"
  SKILL_ZIP_DEST="$ZIP_DIR/pathpoint-skill.zip"
  if curl -fsSL "$BASE_URL/pathpoint-plugin.zip" -o "$PLUGIN_ZIP_DEST" 2>/dev/null; then
    echo ""
    echo "Pathpoint plugin for Claude Desktop staged at:"
    echo "  $PLUGIN_ZIP_DEST"
    echo "To finish installing it in Claude Desktop:"
    echo "  1. Open Claude Desktop"
    echo "  2. Settings → Capabilities → Plugins → Upload local plugin"
    echo "  3. Upload the zip above"
    return 0
  fi
  rm -f "$PLUGIN_ZIP_DEST"
  if curl -fsSL "$BASE_URL/pathpoint-skill.zip" -o "$SKILL_ZIP_DEST" 2>/dev/null; then
    echo ""
    echo "Pathpoint skill for Claude Desktop staged at:"
    echo "  $SKILL_ZIP_DEST"
    echo "To finish installing the skill in Claude Desktop:"
    echo "  1. Open Claude Desktop"
    echo "  2. Settings → Capabilities → Skills → Create skill"
    echo "  3. Upload the zip above"
  else
    rm -f "$SKILL_ZIP_DEST"
  fi
}

# Closing report. Mirrors install.ps1's reasoning: a Claude Desktop config
# failure must not fail the install (p itself works, and `p update` surfaces
# a non-zero exit from this script as an update failure), but the closing
# line must not read as a plain "Done." unless everything that could be
# configured actually was.
final_message() {
  echo ""
  if [ "$DESKTOP_CONFIG_RESULT" = "absent" ] && ! command -v claude >/dev/null 2>&1; then
    # No Claude Desktop and no Claude Code: nothing on this machine can start
    # the MCP server. Say so now, or the user's next stop is claude.ai in a
    # browser — and the Pathpoint tools run locally over stdio, so a browser
    # tab can never reach them; a skill uploaded there adds guidance, not tools.
    echo "Note: neither Claude Desktop nor the Claude Code CLI was found. The Pathpoint"
    echo "tools run locally on this machine (p mcp-serve, over stdio), so claude.ai in a"
    echo "browser cannot reach them — risk work needs Claude Desktop or Claude Code."
    echo "Install one, then re-run this installer (or run: p install-desktop-config)."
    echo ""
  fi
  case "$DESKTOP_CONFIG_RESULT" in
    ok)
      echo "Done. Run: p login"
      ;;
    failed)
      echo "Done installing p, but the Claude Desktop MCP server was NOT configured"
      echo "(see above). Run: p login"
      ;;
    *)
      echo "Done installing p. Claude Desktop wasn't found, so its MCP server and skill"
      echo "were not set up (see above); nothing else is outstanding. Run: p login"
      ;;
  esac
  echo "Upgrade later with: p update   Diagnose problems with: p doctor"
}

main() {
  init_globals
  resolve_version

  ASSET="p_${VERSION}_${OS}_${ARCH}.tar.gz"
  BASE_URL="https://github.com/$REPO/releases/download/v${VERSION}"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  download_asset
  verify_checksum
  install_binary
  clear_quarantine
  configure_path
  configure_claude_code
  configure_claude_desktop
  final_message
}

# Run main unless this file is being sourced (install_test.sh does that to
# test the functions above). The -z arm matters: with `curl ... | bash` —
# the documented install path — bash reads the script from stdin and
# BASH_SOURCE is empty, and main must still run.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
