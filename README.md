# fastpanel-provision

An opinionated, **secure-by-default** bootstrap for [FastPanel](https://fastpanel.direct/) on a fresh Ubuntu server.

FastPanel's default installer brings up a full stack **and** leaves FTP (`proftpd`) and mail (`exim` + `dovecot`) installed and listening on the public internet — services most web projects never use. This script installs the panel with just the web/DB/PHP stack a typical site needs, trims the rest, and wires outgoing mail through an external SMTP relay instead.

One script, run once on a clean box. Interactive by default; fully scriptable for unattended runs.

## Quick start

Copy-paste this on a fresh server (as root) and follow the prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/mad0ps/fastpanel-provision/main/fastpanel-provision.sh -o fp-setup.sh && bash fp-setup.sh
```

## What it does

1. **Preflight** — checks it's running as root on a clean Ubuntu 22.04/24.04, runs `apt update && upgrade`, installs prerequisites (`wget`, `whiptail`).
2. **Gathers config** — your SSH public key, the PHP versions you want (arrow-key checklist), and optional outgoing-SMTP details.
3. **Installs FastPanel** + MySQL 8.0 via the official installer.
4. **Installs the PHP versions** you picked (`fastpanel2-phpXX`).
5. **Trims** `proftpd`, `dovecot`, and `exim` — stopped **and masked**, so a panel self-update can't quietly revive them.
6. **Sets up outgoing mail** with [`msmtp`](https://marlam.de/msmtp/) as `/usr/sbin/sendmail`, relaying through the SMTP server you provide. Credentials live only in `/etc/msmtprc` (root, `600`).
7. **Finishes** with a summary and an optional reboot.

## Requirements

- A **fresh** Ubuntu **22.04** or **24.04** server (the FastPanel installer refuses a box that already has nginx/MySQL/apache).
- Root access.
- 1 GB RAM minimum (the full stack on 512 MB will OOM).

## Usage

### Interactive (recommended)

The [Quick start](#quick-start) one-liner above is all you need. It downloads the script, then runs it — you'll be asked for your SSH key, PHP versions (space toggles, Enter confirms), and optional SMTP relay.

> **Why download-then-run and not `curl … | bash`?** The interactive menus read your keystrokes from the terminal. In a `curl … | bash` pipe, stdin is busy carrying the script itself, so the menus can't see your input. Running from a saved file keeps the terminal free — which is why the one-liner uses `-o fp-setup.sh && bash fp-setup.sh` instead of a pipe.

### Unattended

Pre-set every answer with environment variables and it runs without prompting — handy for CI, cloud-init, or a golden image:

```bash
FP_UNATTENDED=1 \
FP_SSH_KEY="ssh-ed25519 AAAA... you@example.com" \
FP_PHP_VERSIONS="74 82" \
FP_SMTP_HOST=smtp.example.com FP_SMTP_PORT=587 \
FP_SMTP_USER=noreply@example.com FP_SMTP_PASS='secret' \
FP_SMTP_FROM=noreply@example.com \
FP_REBOOT=no \
bash fastpanel-provision.sh
```

### Environment variables

| Variable | Meaning | Default |
|---|---|---|
| `FP_UNATTENDED` | `1` = never prompt; error if a needed value is missing | *(prompt)* |
| `FP_SSH_KEY` | SSH public key line added to `root`'s `authorized_keys` | *(prompt)* |
| `FP_PHP_VERSIONS` | Space-separated versions, no dots — e.g. `74 82` | *(checklist)* |
| `FP_MYSQL` | `-m` value for the installer | `mysql8.0` |
| `FP_SMTP_HOST` | Relay host; leave empty to skip mail setup | *(prompt)* |
| `FP_SMTP_PORT` | Relay port | `587` |
| `FP_SMTP_USER` / `FP_SMTP_PASS` | Relay credentials | *(prompt)* |
| `FP_SMTP_FROM` | Envelope/from address | `FP_SMTP_USER` |
| `FP_REBOOT` | `yes` / `no` | *(prompt)* |

## Verify

`verify-fastpanel-provision.sh` checks the end state — panel + MySQL up, the requested PHP versions installed, unwanted services masked, mail wired, SSH key present:

```bash
bash verify-fastpanel-provision.sh "74 82"   # pass the PHP versions you installed
```

## Design notes

- **Mask, not disable.** A FastPanel self-update re-runs `services configure` for `exim`/`dovecot`; masking is what actually keeps them down.
- **msmtp, not exim smarthost.** FastPanel has no external-SMTP setting and rewrites `exim`'s config on update, so relaying through `exim` is fragile. `msmtp` owns `sendmail` instead, and everything (panel alerts, cron, `mail()`) relays transparently. Credentials never touch FastPanel and never touch this script — only `/etc/msmtprc`.
- **No firewall step.** Intentionally out of scope — bring your own (FastPanel's built-in firewall, `ufw`, or cloud firewall). The script only adds your SSH key.
- **Idempotent.** Re-running skips an already-installed panel, re-masks services, and rewrites `/etc/msmtprc` in place.

## Caveats

- **FastPanel license activation** is a one-time browser step (it asks for an email on first login at `https://<ip>:8888/`). The script can't do that part.
- **Outbound SMTP may be blocked by your host.** DigitalOcean, for one, blocks ports 25/465/587 on new accounts — mail won't leave until you unblock it (a support ticket, usually). This is a host policy, not a script issue.

## License

MIT — see [LICENSE](LICENSE).
