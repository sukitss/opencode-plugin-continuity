#!/usr/bin/env bash
# opencode-plugin-continuity — uninstaller (mirror of install.sh).
# Removes the plugin entry from the global config and strips the managed
# autonomy block from AGENTS.md. Everything else in those files is untouched;
# a timestamped backup is taken before each modification.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_PATH="$REPO_DIR"
BEGIN_MARK='<!-- opencode-plugin-continuity:autonomy begin (managed block — reinstall/update via install.sh) -->'
END_MARK='<!-- opencode-plugin-continuity:autonomy end -->'

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$CONFIG_HOME/opencode"
AGENTS_FILE="$CONFIG_DIR/AGENTS.md"
CONFIG_FILE=""
for f in "$CONFIG_DIR/opencode.json" "$CONFIG_DIR/opencode.jsonc"; do
  [ -f "$f" ] && { CONFIG_FILE="$f"; break; }
done

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  python3 - "$CONFIG_FILE" "$PLUGIN_PATH" <<'PY'
import json, shutil, sys, time, pathlib
cfg_path, plugin = pathlib.Path(sys.argv[1]), sys.argv[2]
text = cfg_path.read_text()
try:
    cfg = json.loads(text)
except Exception as exc:
    sys.exit(f"ERROR: {cfg_path} is not plain JSON ({exc}) — refusing to edit blindly.")
plugins = cfg.get("plugins") or []
def is_ours(e):
    # matches: local absolute path, git URLs, or {"package": ...} forms that
    # reference this repo (covers installs made via ./install.sh --from-git)
    s = e.get("package") if isinstance(e, dict) else e
    return s == plugin or (isinstance(s, str) and "opencode-plugin-continuity" in s)
kept = [e for e in plugins if not is_ours(e)]
if len(kept) == len(plugins):
    print("plugin not registered — nothing to do")
else:
    backup = cfg_path.with_name(cfg_path.name + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(cfg_path, backup)
    cfg["plugins"] = kept
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    print(f"plugin removed from {cfg_path.name} (backup: {backup.name})")
PY
else
  echo "no global config found — plugin step skipped"
fi

if [ -f "$AGENTS_FILE" ]; then
  python3 - "$AGENTS_FILE" "$BEGIN_MARK" "$END_MARK" <<'PY'
import re, shutil, sys, time, pathlib
agents = pathlib.Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
text = agents.read_text()
pattern = re.escape(begin) + r".*?" + re.escape(end)
found = re.search(pattern, text, re.S)
if found is None:
    if begin in text or end in text:
        sys.exit(f"ERROR: {agents.name} has markers but out of order — fix manually; refusing to edit.")
    print("no managed block found — nothing to do")
else:
    new = re.sub(pattern, lambda _m: "", text, count=1, flags=re.S)
    new = re.sub(r"\n{3,}", "\n\n", new).strip()
    backup = agents.with_name(agents.name + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(agents, backup)
    if new:
        agents.write_text(new + "\n")
        print(f"managed block removed from {agents.name} (remaining user content kept; backup: {backup.name})")
    else:
        agents.unlink()
        print(f"managed block removed; {agents.name} contained only the block — file deleted (backup: {backup.name})")
PY
else
  echo "no AGENTS.md found — nothing to do"
fi

echo "uninstalled."
echo "reinstall anytime: bash $REPO_DIR/install.sh"
