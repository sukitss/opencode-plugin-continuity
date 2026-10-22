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

## Install — one-liner (macOS & Linux)

```sh
curl -fsSL https://raw.githubusercontent.com/sukitss/opencode-plugin-continuity/main/install.sh | bash
```

- Clones this repo to `~/.local/share/opencode-plugin-continuity` (override with
  `OPENCODE_CONTINUITY_DIR=/some/path`), then installs plugin + system prompt.
- Rerunning it updates the clone and re-applies both pieces (idempotent).
- Requires: `git`, `python3` (and `bash`). The repo must be public for this URL to work.

## Install — from a manual clone

```sh
git clone https://github.com/sukitss/opencode-plugin-continuity.git
cd opencode-plugin-continuity && ./install.sh
```

## Uninstall

```sh
# one-liner installs:
bash ~/.local/share/opencode-plugin-continuity/uninstall.sh

# manual clones:
./uninstall.sh
```

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
