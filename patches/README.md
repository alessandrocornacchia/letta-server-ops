# Local patches

Hotfixes for bugs in the installed `@letta-ai/letta-code` package, applied until the fix ships upstream. `letta-maintain` re-applies them after every upgrade (an upgrade replaces the patched files) and checks them every 15 minutes.

## Current patches

| Patch | Fixes | Upstream |
|---|---|---|
| `slack-thread-routes` | `MessageChannel` fails with `No route for chat_id` when a conversation is attached to several Slack threads of one channel. Replies now go to the thread that triggered the turn. A message the agent sends on its own (schedules, reports) with no thread gets back the list of threads with their topics, so the agent picks one or starts a new thread. | branches `fix/slack-thread-route-selection`, `fix/slack-thread-choice` (PR pending) |

## States

`letta-maintain patches` applies what's needed and lists every patch:

| State | Meaning |
|---|---|
| `applied` | Just applied. Takes effect at the next restart, which `letta-maintain` schedules for an idle moment. |
| `active` | Already applied to the installed version. |
| `pending` | Would be applied (shown by `letta-maintain status`). |
| `obsolete` | The installed Letta already contains the fix, so the patch is skipped. You get a one-time Slack note; delete the patch. |
| `broken` | Letta's code changed and the patch no longer matches. Letta runs unpatched and you get a Slack alert until the patch is updated. |
| `disabled` | Turned off (see below). |

## Turning a patch off

Either list it in `~/.config/letta-server-ops/env`:

```bash
LETTA_PATCHES_DISABLED=slack-thread-routes
```

or create an empty `disabled` file in its folder. A patch that's already applied stays in the installed files until the next upgrade or a reinstall: `npm i -g @letta-ai/letta-code@<version>`.

## Writing a patch

```
patches/<id>/
  patch.json
  edits/01-something.find
  edits/01-something.replace
  ...
```

`patch.json`:

```json
{
  "description": "One sentence: what the patch fixes.",
  "upstream": "Link to the upstream issue or PR.",
  "target": "letta.js",
  "obsolete_if": "Text that only exists once upstream ships the fix.",
  "edits": [
    { "find": "01-something.find", "replace": "01-something.replace" }
  ]
}
```

Rules the engine (`lib/letta_patch.py`) enforces:

- Each `.find` text must occur **exactly once** in the target, copied byte for byte from the installed file. Otherwise the patch is `broken` and nothing is changed.
- A patch applies **all edits or none**, and the file is replaced atomically.
- An applied patch leaves a marker line (`// letta-server-ops patch: <id> <hash>`) at the end of the target, so re-runs do nothing. Editing a patch changes its hash.
- Name new top-level helpers with a `lettaOps` prefix so they can't collide with Letta's own identifiers.

Test a patch on a copy before installing it:

```bash
mkdir /tmp/pkg && cp "$(npm root -g)/@letta-ai/letta-code/"{letta.js,package.json} /tmp/pkg/
python3 lib/letta_patch.py apply patches /tmp/pkg && node --check /tmp/pkg/letta.js
```

Then run `./install.sh` and `letta-maintain patches`.
