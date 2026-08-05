#!/usr/bin/env bash
# Install the Pathpoint `p` CLI on macOS or Linux.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/outline-insurance/mcp/main/install.sh | bash
#
# Env overrides:
#   P_REPO         Public release repo (default: outline-insurance/mcp)
#   P_VERSION      Version to install, e.g. "0.1.0" (default: latest)
#   P_INSTALL_DIR  Where to drop the `p` binary (default: $HOME/.local/bin)
#   P_SKILL_DIR    Claude Code skill dir (default: $HOME/.claude/skills/Pathpoint)

set -euo pipefail

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

ASSET="p_${VERSION}_${OS}_${ARCH}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/v${VERSION}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading p $VERSION ($OS/$ARCH)..."
curl -fsSL "$BASE_URL/$ASSET" -o "$TMP/$ASSET"

# Verify checksum if checksums.txt is published. CHECKSUM_VERIFIED records
# whether the comparison actually happened (as opposed to being skipped for a
# missing checksums.txt, a missing hasher, or an asset absent from the list) —
# the macOS quarantine decision below depends on knowing the difference.
CHECKSUM_VERIFIED=no
if curl -fsSL "$BASE_URL/checksums.txt" -o "$TMP/checksums.txt" 2>/dev/null; then
  if command -v shasum >/dev/null 2>&1; then HASHER="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"
  else HASHER=""; fi
  if [ -n "$HASHER" ]; then
    expected="$(grep " $ASSET$" "$TMP/checksums.txt" | awk '{print $1}')"
    actual="$($HASHER "$TMP/$ASSET" | awk '{print $1}')"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
      echo "Checksum mismatch for $ASSET (expected $expected, got $actual)" >&2
      exit 1
    fi
    if [ -n "$expected" ]; then
      CHECKSUM_VERIFIED=yes
    fi
  fi
fi
if [ "$CHECKSUM_VERIFIED" = "no" ]; then
  echo "Note: could not verify the download's checksum (no published checksum, no local hasher," >&2
  echo "  or this asset is absent from checksums.txt). Continuing." >&2
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP/p" "$INSTALL_DIR/p"
echo "Installed $INSTALL_DIR/p"

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

# PATH hint — don't edit shell rc files; tell the user.
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Note: $INSTALL_DIR is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc, ~/.bashrc, etc.):"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
    ;;
esac

# Claude Code integration. Preferred path: register the public repo as a
# plugin marketplace and install the versioned `pathpoint` plugin — skill
# plus the `p mcp-serve` MCP server — so `claude plugin update` (or
# re-running this installer) picks up new releases. Falls back to a plain
# skills-dir copy when the `claude` CLI isn't on PATH or its plugin
# commands fail (e.g. an older CLI). All of this is best-effort — it must
# never fail the binary install.
PLUGIN_INSTALLED="false"
PLUGIN_STATE="absent"
if command -v claude >/dev/null 2>&1; then
  # Explicit HTTPS git URL: the bare <owner>/<repo> shorthand clones over
  # SSH by default, which most users haven't set up for GitHub.
  MARKETPLACE_URL="https://github.com/$REPO.git"
  PLUGIN_CMDS_OK="false"

  plugin_fallback_note() {
    echo "Couldn't install the Claude Code plugin automatically; falling back to the plain skill."
    echo "To retry the plugin by hand:"
    echo "  claude plugin marketplace add $MARKETPLACE_URL"
    echo "  claude plugin install pathpoint@outline-insurance --scope user"
  }
  plugin_path_note() {
    # The plugin starts its MCP server as `p` from PATH; without the
    # install dir on PATH the skill loads but the tools never start.
    case ":$PATH:" in
      *":$INSTALL_DIR:"*) ;;
      *)
        echo "note: the plugin's MCP server runs \`p\` from your PATH. Add $INSTALL_DIR"
        echo "      to PATH (see above) or Claude Code won't be able to start it."
        ;;
    esac
  }

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

# Configure the Claude Desktop MCP server entry and stage the skill zip.
if [ -d "$(dirname "$CLAUDE_CFG")" ]; then
  if command -v jq >/dev/null 2>&1; then
    if [ -f "$CLAUDE_CFG" ]; then
      jq --arg cmd "$INSTALL_DIR/p" \
         '.mcpServers.pathpoint = {"command": $cmd, "args": ["mcp-serve"]}' \
         "$CLAUDE_CFG" > "$CLAUDE_CFG.tmp" && mv "$CLAUDE_CFG.tmp" "$CLAUDE_CFG"
    else
      mkdir -p "$(dirname "$CLAUDE_CFG")"
      jq -n --arg cmd "$INSTALL_DIR/p" \
         '{"mcpServers": {"pathpoint": {"command": $cmd, "args": ["mcp-serve"]}}}' \
         > "$CLAUDE_CFG"
    fi
    echo "Configured Claude Desktop MCP server. Restart Claude Desktop to load."
  else
    echo "jq not installed; skipping Claude Desktop config."
    echo "To configure manually, add this under \"mcpServers\" in $CLAUDE_CFG:"
    echo "  \"pathpoint\": { \"command\": \"$INSTALL_DIR/p\", \"args\": [\"mcp-serve\"] }"
  fi

  # Claude Desktop skills don't have a local install path — they're
  # uploaded to Anthropic's servers via the in-app Settings UI. Stage
  # the zip somewhere obvious so the user only has to drag-and-drop.
  SKILL_ZIP_DEST="$HOME/Downloads/pathpoint-skill.zip"
  [ -d "$HOME/Downloads" ] || SKILL_ZIP_DEST="$HOME/pathpoint-skill.zip"
  if curl -fsSL "$BASE_URL/pathpoint-skill.zip" -o "$SKILL_ZIP_DEST" 2>/dev/null; then
    echo ""
    echo "Pathpoint skill for Claude Desktop staged at:"
    echo "  $SKILL_ZIP_DEST"
    echo "To finish installing the skill in Claude Desktop:"
    echo "  1. Open Claude Desktop"
    echo "  2. Settings → Capabilities → Skills → Create skill"
    echo "  3. Upload the zip above"
  fi
else
  echo "Claude Desktop not detected; skipping MCP config and skill staging."
fi

echo ""
echo "Done. Run: p login"
echo "Upgrade later with: p update   Diagnose problems with: p doctor"
