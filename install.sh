#!/usr/bin/env bash
# opencode-plugin-continuity — one-shot installer.
#
# One-liner (macOS & Linux) — clones this repo, then installs:
#   curl -fsSL https://raw.githubusercontent.com/sukitss/opencode-plugin-continuity/main/install.sh | bash
#
# Or from an existing clone:
#   ./install.sh [--from-git]
#
# Installs, idempotently and without overwriting unrelated content:
#   1. the plugin (registers the repo's absolute path in the global config,
#      or via `opencode plugin add <git-url>` with --from-git once pushed)
#   2. the autonomy system prompt (~/.config/opencode/AGENTS.md, wrapped in
#      managed markers so updates/removals never touch surrounding text)
#
# Every config mutation is preceded by a timestamped backup.
# Env: OPENCODE_CONTINUITY_DIR overrides the bootstrap clone destination.
set -euo pipefail

REPO_URL="https://github.com/sukitss/opencode-plugin-continuity.git"

# ---------- locate repo (bootstrap when run via curl | bash) ----------
# Guard against re-entry: after cloning we exec the cloned install.sh, which
# must NOT bootstrap again even if its own BASH_SOURCE looks unusual.
if [ -n "${_OPENCODE_CONTINUITY_BOOTSTRAP:-}" ]; then
  REPO_DIR="$_OPENCODE_CONTINUITY_BOOTSTRAP"
  [ -f "$REPO_DIR/index.ts" ] || { echo "ERROR: broken clone at $REPO_DIR (missing index.ts)" >&2; exit 1; }
else
  SCRIPT_PATH="${BASH_SOURCE[0]:-}"
  if [ -n "$SCRIPT_PATH" ] && [ -f "$(dirname "$SCRIPT_PATH")/index.ts" ]; then
    REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  else
    command -v git >/dev/null 2>&1 || { echo "ERROR: git is required for the one-liner install" >&2; exit 1; }
    TARGET="${OPENCODE_CONTINUITY_DIR:-$HOME/.local/share/opencode-plugin-continuity}"
    if [ -e "$TARGET" ] && [ ! -d "$TARGET/.git" ]; then
      echo "ERROR: $TARGET exists but is not a git clone of this repo." >&2
      echo "Remove it (or point OPENCODE_CONTINUITY_DIR elsewhere) and rerun." >&2
      exit 1
    fi
    if [ -d "$TARGET/.git" ]; then
      echo "==> updating existing clone at $TARGET"
      git -C "$TARGET" pull --ff-only </dev/null
    else
      echo "==> cloning into $TARGET"
      git clone --depth 1 "$REPO_URL" "$TARGET" </dev/null || {
        echo "ERROR: clone failed (private repo? clone manually, then run ./install.sh from it)" >&2
        exit 1
      }
    fi
    export _OPENCODE_CONTINUITY_BOOTSTRAP="$TARGET"
    exec bash "$TARGET/install.sh" ${1+"$@"} </dev/null
  fi
fi

NAME="continuity"
PLUGIN_PATH="$REPO_DIR"
BEGIN_MARK='<!-- opencode-plugin-continuity:autonomy begin (managed block — reinstall/update via install.sh) -->'
END_MARK='<!-- opencode-plugin-continuity:autonomy end -->'
BLOCK_FILE="$REPO_DIR/agents/autonomy.md"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$CONFIG_HOME/opencode"
AGENTS_FILE="$CONFIG_DIR/AGENTS.md"
CONFIG_FILE=""
for f in "$CONFIG_DIR/opencode.json" "$CONFIG_DIR/opencode.jsonc"; do
  [ -f "$f" ] && { CONFIG_FILE="$f"; break; }
done
[ -n "$CONFIG_FILE" ] || CONFIG_FILE="$CONFIG_DIR/opencode.json"

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[ -f "$BLOCK_FILE" ] || fail "missing $BLOCK_FILE"

# ---------- 1) plugin ----------
if [ "${1:-}" = "--from-git" ]; then
  command -v opencode >/dev/null 2>&1 || fail "opencode CLI not found in PATH"
  REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  [ -n "$REMOTE" ] || fail "--from-git requires an 'origin' remote (git remote add origin ...)"
  say "==> opencode plugin add $REMOTE"
  opencode plugin add "$REMOTE"
else
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$CONFIG_FILE"
    say "created $CONFIG_FILE"
  fi
  python3 - "$CONFIG_FILE" "$PLUGIN_PATH" <<'PY'
import json, shutil, sys, time, pathlib
cfg_path, plugin = pathlib.Path(sys.argv[1]), sys.argv[2]
text = cfg_path.read_text()
try:
    cfg = json.loads(text)
except Exception as exc:
    sys.exit(f"ERROR: {cfg_path} is not plain JSON ({exc}). "
             "Refusing to edit blindly — push this repo to a git remote and run "
             "./install.sh --from-git so the official `opencode plugin add` handles it.")
plugins = cfg.get("plugins")
if plugins is not None and not isinstance(plugins, list):
    sys.exit(f"ERROR: 'plugins' in {cfg_path} is not an array — refusing to edit.")
if any(e == plugin or (isinstance(e, dict) and e.get("package") == plugin) for e in plugins or []):
    print("plugin already registered — skip")
else:
    backup = cfg_path.with_name(cfg_path.name + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(cfg_path, backup)
    cfg["plugins"] = [*(plugins or []), plugin]
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    print(f"plugin registered in {cfg_path.name} (backup: {backup.name})")
PY
fi

# ---------- 2) autonomy system prompt ----------
mkdir -p "$CONFIG_DIR"
python3 - "$AGENTS_FILE" "$BLOCK_FILE" "$BEGIN_MARK" "$END_MARK" <<'PY'
import re, shutil, sys, time, pathlib
agents = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text().strip()
begin, end = sys.argv[3], sys.argv[4]
text = agents.read_text() if agents.exists() else None
stamp = time.strftime("%Y%m%d-%H%M%S")
if text is None:
    agents.parent.mkdir(parents=True, exist_ok=True)
    agents.write_text(block + "\n")
    print(f"created {agents}")
    sys.exit(0)
if begin in text and end in text:
    pattern = re.escape(begin) + r".*?" + re.escape(end)
    current = re.search(pattern, text, re.S)
    if current is None:
        sys.exit(f"ERROR: {agents.name} has markers but out of order (end before begin) — "
                 "fix manually; refusing to edit.")
    if current.group(0).strip() == block:
        print("system prompt already up to date — skip")
    else:
        backup = agents.with_name(agents.name + ".bak-" + stamp)
        shutil.copy2(agents, backup)
        agents.write_text(re.sub(pattern, lambda _m: block, text, count=1, flags=re.S))
        print(f"updated managed block in {agents.name} (backup: {backup.name})")
else:
    if begin in text or end in text:
        sys.exit(f"ERROR: {agents.name} has a half-present marker — fix manually; refusing to edit.")
    backup = agents.with_name(agents.name + ".bak-" + stamp)
    shutil.copy2(agents, backup)
    sep = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    agents.write_text(text + sep + block + "\n")
    print(f"appended managed block to existing {agents.name} (backup: {backup.name}); "
          "existing content was not modified")
PY

# ---------- 3) verify ----------
if command -v opencode >/dev/null 2>&1; then
  if opencode plugin list 2>/dev/null | grep -F "$NAME" >/dev/null; then
    say "verify: opencode plugin list shows '$NAME' — active"
  else
    say "verify: '$NAME' not listed yet (hot-load may take a few seconds; rerun 'opencode plugin list')"
  fi
fi
say "done. rollback anytime: bash $REPO_DIR/uninstall.sh"
