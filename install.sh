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

# Resolve "latest" to a concrete tag via the GitHub API.
# Uses awk rather than sed \s since BSD sed on macOS doesn't support \s.
if [ "$VERSION" = "latest" ]; then
  VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | awk -F '"' '/"tag_name":/ { sub(/^v/, "", $4); print $4; exit }')"
  if [ -z "$VERSION" ]; then
    echo "Could not resolve latest version from $REPO." >&2
    echo "Is the repo public? Does it have any releases?" >&2
    echo "  gh release list --repo $REPO" >&2
    exit 1
  fi
fi

ASSET="p_${VERSION}_${OS}_${ARCH}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/v${VERSION}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading p $VERSION ($OS/$ARCH)..."
curl -fsSL "$BASE_URL/$ASSET" -o "$TMP/$ASSET"

# Verify checksum if checksums.txt is published.
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
  fi
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP/p" "$INSTALL_DIR/p"
echo "Installed $INSTALL_DIR/p"

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

# Install the Claude Code skill if the release ships SKILL.md.
if curl -fsSL "$BASE_URL/SKILL.md" -o "$TMP/SKILL.md" 2>/dev/null; then
  mkdir -p "$SKILL_DIR"
  cp "$TMP/SKILL.md" "$SKILL_DIR/SKILL.md"
  echo "Installed Pathpoint skill to $SKILL_DIR/"
fi

# Configure the Claude Desktop MCP server entry.
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
else
  echo "Claude Desktop not detected; skipping MCP config."
fi

echo ""
echo "Done. Run: p login --endpoint demo"
