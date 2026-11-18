# 🛠️ letta-server-ops

Keep a self-hosted **Letta Code remote environment** (`letta server`) healthy, up to date and reachable from the Letta webapp, and get a friendly Slack DM whenever something happens. 💬

One `./install.sh` sets up the systemd service, a maintenance script and two cron jobs. Re-run it any time; it only changes what's out of date.

---

## 🤔 Why this tool?

Running `letta server` as a systemd service works great... until it doesn't:

- 👻 **The silent offline.** Letta's connection to Letta Cloud drops many times a day and normally reconnects within seconds. Occasionally a reconnect fails and it **never retries**. `systemctl` still says `active (running)`, but the webapp shows your environment as **offline**, sometimes for hours, and nobody notices.
- 💥 **Restarts kill your experiments.** The service uses `KillMode=control-group`, so *everything* the agent launched (a 16-hour training run, a benchmark, a `nohup`'d script) lives in the service's cgroup. A plain `systemctl restart` kills all of it.
- 📦 **Upgrades pile up.** New `@letta-ai/letta-code` versions ship often, and an old client can misbehave against the cloud.

letta-server-ops fixes all three: it **upgrades daily**, **restarts only when Letta is idle**, **detects and repairs the stuck connection**, **moves your background jobs to safety before any restart**, and **tells you about it on Slack**. 🎉

---

## ✅ Prerequisites

| | What | Check |
|---|---|---|
| 🐧 | Linux with **systemd** (cgroup v2) | `systemctl --version` |
| 🔑 | **Passwordless sudo** for your user | `sudo -n true && echo ok` |
| 🟢 | **Node.js + npm** (nvm is fine) | `node --version` |
| 🤖 | **Letta Code** installed globally | `npm i -g @letta-ai/letta-code` |
| 🗝️ | A **Letta API key** | [app.letta.com](https://app.letta.com) → API keys |
| 🧰 | `curl`, `python3`, `flock`, `busctl`, `crontab` | usually preinstalled on Ubuntu |
| 💬 | *(optional)* A Slack workspace where you can install apps | |

`install.sh` checks all of these and tells you what's missing.

---

## 🚀 How to install

```bash
git clone https://github.com/alessandrocornacchia/letta-server-ops.git
cd letta-server-ops
./install.sh --env-name my-copilot --channels whatsapp
```

| Option | Meaning | Default |
|---|---|---|
| `--env-name NAME` | How this machine shows up in the Letta webapp | the hostname |
| `--channels LIST` | Letta channels to run, e.g. `whatsapp` | none |
| `--dry-run` | Show what would change, change nothing 👀 | |
| `--force-unit` | Replace an existing, different systemd unit | keep existing |

What gets installed:

- 📄 `/etc/systemd/system/letta-server.service` (+ `override.conf`), enabled at boot
- 🔐 `/etc/letta/.env`, the Letta secrets (created from `letta.env.example` if missing)
- 🧹 `~/.local/bin/letta-maintain`, the maintenance script
- ⚙️ `~/.config/letta-server-ops/env`, your settings
- ⏰ two cron jobs in your crontab

> 🛡️ The installer **never restarts a running service**. If the unit changed, the new version takes effect at the next idle restart.

---

## ⚙️ How to configure

### 1. 🔐 Letta secrets

```bash
sudo nano /etc/letta/.env      # set LETTA_API_KEY (and CLAUDE_CODE_OAUTH_TOKEN if you use Claude Code)
sudo systemctl start letta-server
```

### 2. 💬 Slack notifications (optional but recommended)

1. Go to **[api.slack.com/apps](https://api.slack.com/apps)** → **Create New App** → **From a manifest**, then pick your workspace.
2. Paste [`slack-manifest.json`](slack-manifest.json). This creates a bot called **Letta Ops**.
3. **Install to Workspace**, then copy the **Bot User OAuth Token** (`xoxb-…`) from *OAuth & Permissions*.
4. Find your **member ID**: your Slack profile → ⋮ → *Copy member ID* (`U…`).
5. Put both in `~/.config/letta-server-ops/env`:

   ```bash
   SLACK_BOT_TOKEN=xoxb-...
   SLACK_USER_ID=U0123456789
   ```
6. Say hi 👋: `letta-maintain test`

> ♻️ One Slack app can serve all your machines: every message starts with the hostname.

### 3. 🎛️ Tuning (optional)

The thresholds live at the top of `letta-maintain.sh`: stuck timeout (10 min), quiet period before an idle restart (10 min), stuck-restart limits (1/hour, 3/day). Edit, then re-run `./install.sh`.

---

## 🔍 What it does

### ⏰ Every day at 02:00 UTC: `letta-maintain daily`
- ⬆️ Upgrades `@letta-ai/letta-code` to the latest version.
- 🏷️ Marks a restart as due, so the new version actually gets loaded.

### 🔁 Every 15 minutes: `letta-maintain check`
- 🚨 **Stuck connection?** If the last listener event is `Reconnecting` with no `Connected` for more than 10 minutes, it restarts right away. Rate-limited to 1/hour and 3/day, so a bad detection can never cause a restart loop.
- 😴 **Restart due and Letta idle?** If Letta has no running agent turn (no child processes, no `status: processing` for 10 min), it restarts.
- 🛟 **Before any restart**, background jobs in the service's cgroup that aren't part of Letta itself are moved into their own `letta-orphans-<timestamp>.scope`, so your experiments keep running. 🧪
- ✔️ **After a restart**, it waits for `Connected. Awaiting instructions.` and reports the result.

### 📬 What you'll see on Slack

| | Message |
|---|---|
| ⬆️ | Letta upgraded `0.34.63 → 0.34.65`; it will restart once idle |
| ✅ | Restarted while idle, reconnected, now on version X (and N jobs kept alive) |
| 🚨 | Restarted because the listener was stuck; reconnected |
| ⚠️ | Restarted but didn't reconnect within 90 s |
| ⚠️ | npm upgrade failed |
| ⚠️ | Log markers missing for 24 h: Letta's log format may have changed, so stuck detection is paused |
| ⚠️ | 3 stuck-restarts in 24 h: stopped restarting, please look |
| ⚠️ | Daily restart waiting 48 h for an idle moment |
| ❌ | Couldn't move background jobs out first, so the restart was skipped to protect them |

Alerts are sent **once** and re-armed when the problem clears. No spam. 🙏

### 🩺 Handy commands

```bash
letta-maintain status    # health summary: version, listener, idle, pending restart, Slack
letta-maintain test      # send a test Slack message
letta-maintain check     # run the 15-min check now
tail -f ~/.letta/maintain/maintain.log
journalctl -u letta-server -f
```

---

## 💡 Tips

- 🧪 **Launch long experiments outside the service** so they never depend on the rescue step:
  ```bash
  sudo systemd-run --uid=$USER --gid=$(id -gn) --unit=my-exp --working-directory=$PWD ./run.sh
  systemctl status my-exp; journalctl -u my-exp -f
  ```
  (`systemd-run --user` only works if your user manager is running, e.g. after `sudo loginctl enable-linger $USER`.)
- 🔄 **Updating letta-server-ops**: `git pull && ./install.sh --env-name … --channels …`
- 🙅 **Secrets never go in this repo.** `/etc/letta/.env` and `~/.config/letta-server-ops/env` stay on the machine.
