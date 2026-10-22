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

# Family profiles: (regex, base_context_when_router_silent, compaction_target_pct)
#
# pct = where auto-compact SHOULD fire, as a share of the advertised window —
# the "effective context" point before long-context quality degrades. OpenCode's
# ceiling is always 90% of limit.context, so limit.context = base × pct / 0.9.
#
# Sources (researched 2026-10-23):
# - OpenAI system-card coverage: GPT-6.1 Sol hard input max = 922K (1.05M − 128K output)
#   → pct 85 keeps the ceiling (~893K) below that wall.
# - Google MRCR v2 (self-published): Gemini multi-needle degrades past 256K; single-needle
#   holds near 1M → agentic work sits between → pct 65.
# - NVIDIA RULER: frontier models reliably use only 50-65% of advertised windows for
#   multi-hop work → family pct values stay within/below the top of that band.
# - LongCodeEdit (nrehiew): reasoning-over-long-code degrades earlier than retrieval;
#   older Kimi-K2/GLM-4.5 <32K — newer 1M-class gens are far better but not at 100%.
# - Local evidence: glm-5.3 processed a 984,747-token prompt (94% of advertised) —
#   needle-capacity confirmed, but IndexPool compression is lossy → pct 80, not 90.
# - Moonshot: Kimi K3 KDA claims usable 1M, flat pricing → pct 75 (conservative-middle).
PROFILES = [
    (r"kimi-k3",                  1_048_576, 75),
    (r"kimi-k2",                  262_144,   80),
    (r"gpt-6\.1",                 1_050_000, 85),
    (r"^coding",                  1_050_000, 85),
    (r"gpt-6",                    272_000,   85),
    (r"gpt-5\.6-sol",             372_000,   80),
    (r"gpt-5\.6",                 272_000,   85),
    (r"gemini-(4\.|4-|3\.[5-9])", 1_048_576, 65),
    (r"claude-(opus|sonnet)-[4-9]", 1_000_000, 75),
    (r"glm-5\.[2-9]",             1_048_576, 80),
    (r"glm-5",                    200_000,   85),
    (r"glm-4\.7",                 200_000,   85),
    (r"deepseek-v[4-9]",          1_000_000, 75),
    (r"grok-[45]",                256_000,   75),
    (r"seed-2-0",                 200_000,   85),
]
DEFAULT_PCT = 90  # no profile match → trust the advertised window (opencode default)

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
        base = adv.get(mid)
        pct = DEFAULT_PCT
        src = "router"
        for pat, pbase, ppct in PROFILES:
            if re.search(pat, mid):
                if not base:
                    base, src = pbase, "profile"
                else:
                    src = f"router+profile({ppct}%)"
                pct = ppct
                break
        if not base:
            report.append(f"{pid}/{mid}: no router data, no profile — kept {(m.get('limit') or {}).get('context')}")
            continue
        target = int(base * pct / 90 / 1000 + 0.5) * 1000  # pct/100 ÷ 0.9-ceiling
        lim = m.setdefault("limit", {})
        old = lim.get("context")
        line = f"{pid}/{mid}: {old:,} → {target:,} [{src}]  (compact @ {int(target*0.9):,} = {pct}% of base)"
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
