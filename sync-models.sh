#!/usr/bin/env bash
# sync-models.sh — sync limit.context of configured models from the router's
# own /models catalog, falling back to family profiles (regex) for providers
# that report nothing (e.g. aig), then leaving anything unknown untouched.
#
# Priority per model:
#   1. router /models advertised contextWindow  (source of truth)
#   2. family profile (regex on model id, researched specs)
#   3. keep current value + report (never guess)
#
# Usage:
#   ./sync-models.sh           # apply (backup before write)
#   ./sync-models.sh --check   # report only
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$CONFIG_HOME/opencode"
DB="$HOME/.local/share/opencode/opencode.db"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

CONFIG_FILE=""
for f in "$CONFIG_DIR/opencode.json" "$CONFIG_DIR/opencode.jsonc"; do
  [ -f "$f" ] && { CONFIG_FILE="$f"; break; }
done
[ -n "$CONFIG_FILE" ] || { echo "ERROR: no config found in $CONFIG_DIR" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

python3 - "$CONFIG_FILE" "$DB" "$CHECK" <<'PY'
import json, re, sqlite3, sys, shutil, time, urllib.request, pathlib

cfg_path, db_path, check = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
cfg = json.loads(cfg_path.read_text())
stamp = time.strftime("%Y%m%d-%H%M%S")

def key_for(pid: str):
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        row = con.execute("SELECT value FROM credential WHERE integration_id=?", (pid,)).fetchone()
        con.close()
        return json.loads(row[0])["key"] if row else None
    except Exception:
        return None

# Family profiles (regex → limit.context). Order matters: first match wins.
# Sources: vendor specs (openai.com, ai.google.dev, z.ai, llm-stats) + the
# 9router catalog's own per-id values + local empirical evidence (glm-5.3
# processed 984,747-token prompts successfully; 1261 wall ≈ advertised).
PROFILES = [
    (r"gpt-6\.1",            1_050_000),  # OpenAI GPT-6.1 (Sol) — 1M input / 128k out
    (r"gpt-6",               272_000),    # GPT-6 base tier ([1m] variants come from router data)
    (r"gpt-5\.6-sol",        372_000),
    (r"gpt-5\.6",            272_000),
    (r"gemini-(4\.|4-|3\.[5-9])", 1_048_576),  # Google 1M class (3.8 Flash / 4 Argon verified)
    (r"claude-(opus|sonnet)-[4-9]", 1_000_000),  # 2026 Claude gen — 1M per catalog
    (r"glm-5\.[2-9]",        1_048_576),  # Z.ai 1M class (5.2/5.3)
    (r"glm-5",               200_000),    # glm-5 / 5.1 / 5-turbo
    (r"glm-4\.7",            200_000),
    (r"deepseek-v[4-9]",     1_000_000),
    (r"kimi-k3",             1_048_576),
    (r"kimi-k2",             262_144),
    (r"grok-[45]",           256_000),
    (r"seed-2-0",            200_000),
]

report, changed = [], []
for pid, prov in (cfg.get("provider") or {}).items():
    models = prov.get("models") or {}
    if not models:
        continue
    adv = {}
    base = (prov.get("options") or {}).get("baseURL")
    key = key_for(pid)
    if base and key:
        try:
            req = urllib.request.Request(base.rstrip("/") + "/models",
                                         headers={"Authorization": "Bearer " + key,
                                                  "User-Agent": "opencode-sync/1.0"})
            data = json.load(urllib.request.urlopen(req, timeout=30))
            items = data.get("data") if isinstance(data, dict) else data
            for x in items or []:
                cw = (x.get("capabilities") or {}).get("contextWindow") or x.get("context_length") or 0
                if cw:
                    adv[x.get("id")] = int(cw)
            print(f"[{pid}] catalog: {len(adv)} models with context data")
        except Exception as exc:
            print(f"[{pid}] WARN: fetch failed ({exc}) — profiles only")
    else:
        print(f"[{pid}] WARN: no baseURL or no credential in {db_path} — profiles only")

    for mid in models:
        m = models[mid]
        if not isinstance(m, dict):
            report.append(f"{pid}/{mid}: not an object — skipped")
            continue
        target, src = adv.get(mid), "router"
        if not target:
            for pat, ctx in PROFILES:
                if re.search(pat, mid):
                    target, src = ctx, "profile"
                    break
        if not target:
            report.append(f"{pid}/{mid}: no router data, no profile — kept {(m.get('limit') or {}).get('context')}")
            continue
        lim = m.setdefault("limit", {})
        old = lim.get("context")
        line = f"{pid}/{mid}: {old:,} → {target:,} [{src}]  (compact @ {int(target*0.9):,})"
        if old != target:
            lim["context"] = target
            changed.append(line)
        else:
            report.append(f"{pid}/{mid}: up to date ({target:,}) [{src}]")

print()
if changed:
    print("── changes ──")
    for c in changed:
        print("  " + c)
    if not check:
        backup = cfg_path.with_name(cfg_path.name + ".bak-" + stamp)
        shutil.copy2(cfg_path, backup)
        cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
        print(f"\napplied {len(changed)} change(s) (backup: {backup.name})")
    else:
        print(f"\n--check: {len(changed)} change(s) NOT applied")
else:
    print("all models already in sync")
if report:
    print("\n── notes ──")
    for r in report:
        print("  " + r)
PY
