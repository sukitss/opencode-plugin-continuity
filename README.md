# opencode-plugin-continuity

Keeps OpenCode coding agents running — without patching OpenCode source.

- **Plugin** (`index.ts`): on provider failures — vetoes pointless retries when the prompt is
  too large for the upstream (`Prompt exceeds max length` / code `1261` and friends) and asks
  the session to compact so the next prompt continues; paces retries on HTTP 5xx (30s delay).
  Model context limits are clamped via config (see `agents/autonomy.md` ticket history —
  v2.0.30 `model.transform` does not reach the model read path).
- **System prompt** (`agents/autonomy.md`): "work until done" autonomy rules, adapted from
  Claude Code's proactivity system, installed as the global `~/.config/opencode/AGENTS.md`
  between managed markers.

## Install (one shot)

```sh
git clone <this-repo-url> && cd opencode-plugin-continuity && ./install.sh
```

Idempotent: safe to rerun. Every config change is backed up (`*.bak-<timestamp>`) and the
autonomy block is wrapped in managed markers, so existing content in `AGENTS.md` is never
touched. Requires `python3`; `opencode` CLI optional (used for verification).

## Install from a git remote (after pushing this repo)

```sh
./install.sh --from-git
# equivalent to: opencode plugin add <origin-url>
```

## Uninstall

```sh
./uninstall.sh
```

## Verify

```sh
opencode plugin list                 # should list: continuity
opencode api get /api/model | grep 200000   # context clamp visible (models defined in config)
```

Note: the autonomy prompt applies to new sessions (and is hot-injected into running ones
by the harness when the file changes).
