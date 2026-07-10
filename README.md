# Server Health Check and Alerting Script

A Bash script that monitors Linux servers for disk, memory, CPU, and
service health, logs the results, and sends a Slack/Discord webhook
alert when a threshold is breached or a critical service goes down.

Built as a portfolio project to demonstrate Linux administration and
Bash scripting for a Junior Technical Support Specialist role.

## What it checks

| Check    | Source              | Default threshold        |
|----------|----------------------|---------------------------|
| Disk     | `df -P`               | 80% used, per mount point |
| Memory   | `free -m`              | 90% used                 |
| CPU load | `/proc/loadavg`        | 1-minute load average >= 2.0 |
| Services | `systemctl is-active`  | any listed service not `active` |

It can also check multiple hosts over SSH, not just the machine it
runs on.

## How it avoids alert spam

Each issue (e.g. "disk on `/` over threshold", "service `nginx` down")
gets its own state file under `STATE_DIR`. The rules:

- **New breach** -> alert immediately, write a state file.
- **Still breached on a later run** -> alert again only after
  `ALERT_COOLDOWN_SECONDS` has passed since the last alert (default 30
  minutes).
- **Resolved** (check passes again) -> send a "RESOLVED" alert and
  remove the state file.

Every check result is written to `LOG_FILE` on every run regardless of
whether it triggers a webhook alert, so the log is a complete history
even between alerts.

## Setup

1. Copy the example config and edit it:

   ```bash
   cp config.example.env config.env
   ```

2. Edit `config.env`:
   - `HOSTS` - `(localhost)` to monitor just this machine, or add
     hostnames/IPs to also check over SSH.
   - `DISK_THRESHOLD`, `MEMORY_THRESHOLD`, `CPU_LOAD_THRESHOLD` -
     percentages/load average that trigger an alert.
   - `SERVICES` - systemd unit names that must be `active`, e.g.
     `(ssh nginx)`.
   - `WEBHOOK_URL` - a Slack or Discord incoming webhook URL. **While
     testing, point this at a throwaway URL from
     [webhook.site](https://webhook.site)** so you can see payloads
     without spamming a real channel. Switch it to the real channel
     webhook once everything works.
   - `LOG_FILE` / `STATE_DIR` - where results and alert state are kept.
   - `SSH_USER`, `SSH_KEY`, `SSH_TIMEOUT` - only used for remote hosts
     in `HOSTS`. Set up passwordless key-based SSH to each remote host
     first (`ssh-copy-id` or manually append your public key to the
     remote `~/.ssh/authorized_keys`).

3. Make the script executable:

   ```bash
   chmod +x health_check.sh
   ```

4. Run it once by hand to confirm it works:

   ```bash
   ./health_check.sh
   tail logs/health_check.log
   ```

`config.env` is git-ignored (see `.gitignore`) since it may contain a
real webhook URL - don't commit it.

## Scheduling with cron

Run every 5 minutes:

```
*/5 * * * * /full/path/to/health_check.sh >> /full/path/to/logs/cron.log 2>&1
```

Add it with `crontab -e`. Use full absolute paths in the crontab line -
cron does not run with your interactive shell's working directory or
`$PATH`.

## Testing

These simulate real failures so you can confirm logging and alerting
both work end-to-end.

**Disk threshold:**

```bash
fallocate -l 5G /tmp/fill_disk.img   # adjust size to cross your threshold
./health_check.sh
# check logs/health_check.log and the webhook for the alert
rm /tmp/fill_disk.img
./health_check.sh                     # confirm a RESOLVED alert fires
```

**Service down:**

```bash
sudo systemctl stop nginx    # use a non-critical service you can safely stop
./health_check.sh
sudo systemctl start nginx
./health_check.sh            # confirm RESOLVED alert
```

**Cooldown behavior:** leave an issue unresolved and re-run the script
within `ALERT_COOLDOWN_SECONDS` - confirm no duplicate alert fires, then
wait past the cooldown and confirm a repeat alert does fire.

## Example log output

```
2026-07-10 14:32:01 [INFO] ==== health check run started ====
2026-07-10 14:32:01 [OK] host localhost is reachable
2026-07-10 14:32:01 [OK] [localhost] disk usage on / is 42% (threshold 80%)
2026-07-10 14:32:01 [OK] [localhost] memory usage is 61% (threshold 90%)
2026-07-10 14:32:01 [OK] [localhost] 1-minute load average is 0.15 (threshold 2.0)
2026-07-10 14:32:01 [OK] [localhost] service 'ssh' is active (expected active)
2026-07-10 14:32:01 [INFO] ==== health check run completed ====

2026-07-10 14:40:01 [BREACH] [localhost] disk usage on / is 87% (threshold 80%)
2026-07-10 14:40:01 [INFO] Webhook alert sent (HTTP 200): ALERT: [localhost] disk usage on / is 87% (threshold 80%)

2026-07-10 14:45:01 [OK] [localhost] disk usage on / is 55% (threshold 80%)
2026-07-10 14:45:01 [INFO] Webhook alert sent (HTTP 200): RESOLVED: [localhost] disk usage on / is 55% (threshold 80%)
```

## Remote hosts over SSH

Add remote hosts to `HOSTS` in `config.env`, e.g. `HOSTS=(localhost 10.0.0.5)`.
The script checks reachability first (`ssh ... echo ok`); if a host is
unreachable it logs and alerts `host unreachable` for that host and
skips the rest of its checks for that run, instead of crashing the
whole script. All other hosts still run normally.

Each remote host needs the script's SSH user able to log in with a key
(no password prompt) and run `df`, `free`, `cat /proc/loadavg`, and
`systemctl is-active` non-interactively.

## Repo structure

```
health_check.sh        # main script
config.example.env     # copy to config.env and edit
README.md
logs/                   # created at runtime: health_check.log + state/
```
