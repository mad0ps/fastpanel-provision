#!/usr/bin/env bash
#
# fastpanel-provision.sh — opinionated, secure-by-default FastPanel bootstrap.
#
# Installs FastPanel with only the stack a typical web project needs and trims
# the services the default installer leaves open (FTP + mail), so a fresh box
# comes up lean instead of exposing proftpd/exim/dovecot to the internet.
#
# WHAT IT DOES, in order:
#   1. Preflight  — root + fresh Ubuntu 22.04/24.04 check, apt update/upgrade,
#                   prerequisites (wget, whiptail, ca-certificates).
#   2. Gather     — SSH public key, PHP versions (checklist), outgoing SMTP.
#                   Interactive by default; every prompt can be pre-set via an
#                   env var for unattended/CI runs (see CONFIG below).
#   3. Install    — FastPanel + MySQL 8.0 via the official installer.
#   4. PHP        — the chosen fastpanel2-phpXX packages.
#   5. Trim       — mask proftpd + dovecot + exim (not needed; the panel's
#                   defaults ship them open to the world).
#   6. Mail       — msmtp becomes /usr/sbin/sendmail, relaying through the
#                   external SMTP you gave. Credentials live ONLY in
#                   /etc/msmtprc (root, 600) — never in FastPanel, never here.
#   7. Finish     — summary + optional reboot.
#
# HOW TO RUN (interactive — the menus need a real terminal, so download first;
# `curl | bash` will NOT work because stdin is the piped script):
#
#     curl -fsSL <URL>/fastpanel-provision.sh -o fp-setup.sh && bash fp-setup.sh
#
# HOW TO RUN (unattended, e.g. from CI or a test harness):
#
#     FP_UNATTENDED=1 \
#     FP_SSH_KEY="ssh-ed25519 AAAA... you@example.com" \
#     FP_PHP_VERSIONS="74 82" \
#     FP_SMTP_HOST=smtp.example.com FP_SMTP_PORT=587 \
#     FP_SMTP_USER=noreply@example.com FP_SMTP_PASS='secret' \
#     FP_SMTP_FROM=noreply@example.com \
#     FP_REBOOT=no \
#     bash fp-setup.sh
#
# Idempotent where it matters: re-running skips an already-installed panel,
# re-masks services, and rewrites /etc/msmtprc in place.

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG (env overrides — leave unset to be prompted interactively)
# ----------------------------------------------------------------------------
FP_UNATTENDED="${FP_UNATTENDED:-}"       # =1 : never prompt; error if a needed value is missing
FP_MYSQL="${FP_MYSQL:-mysql8.0}"          # -m value for the official installer (valid on Ubuntu 24.04)
FP_SSH_KEY="${FP_SSH_KEY:-}"              # authorized_keys line(s) to add for root
FP_PHP_VERSIONS="${FP_PHP_VERSIONS:-}"    # space-separated, e.g. "74 82" (no dots)
FP_SMTP_HOST="${FP_SMTP_HOST:-}"          # blank => skip mail relay entirely
FP_SMTP_PORT="${FP_SMTP_PORT:-587}"
FP_SMTP_USER="${FP_SMTP_USER:-}"
FP_SMTP_PASS="${FP_SMTP_PASS:-}"
FP_SMTP_FROM="${FP_SMTP_FROM:-}"
FP_SMTP_TLS="${FP_SMTP_TLS:-on}"          # on | starttls-only handled by tls_starttls
FP_REBOOT="${FP_REBOOT:-}"                # yes | no ; prompted if empty

# PHP versions offered in the interactive checklist. The install step verifies
# each against the live repo and warns (not aborts) on any that is unavailable.
PHP_CHOICES=(53 56 70 71 72 73 74 80 81 82 83)
PHP_DEFAULT_ON=(74 82)                     # pre-ticked in the checklist

LOG=/root/fastpanel-provision.$(date -u +%Y%m%d_%H%M%SZ).log
INSTALL_URL="https://repo.fastpanel.direct/install_fastpanel.sh"

# ----------------------------------------------------------------------------
# logging helpers
# ----------------------------------------------------------------------------
c_g=$'\033[0;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_b=$'\033[1;36m'; c_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$c_b" "$c_0" "$*" | tee -a "$LOG"; }
ok()   { printf '%s[ok]%s %s\n'  "$c_g" "$c_0" "$*" | tee -a "$LOG"; }
warn() { printf '%s[warn]%s %s\n' "$c_y" "$c_0" "$*" | tee -a "$LOG"; }
die()  { printf '%s[FATAL]%s %s\n' "$c_r" "$c_0" "$*" | tee -a "$LOG" >&2; exit 1; }

# read a line from the real terminal even if the script itself came via a pipe
ask() { # ask <prompt> <varname> [silent]
    local prompt="$1" __var="$2" silent="${3:-}" reply=""
    if [ -n "$silent" ]; then read -rs -p "$prompt" reply < /dev/tty; echo >/dev/tty
    else read -r -p "$prompt" reply < /dev/tty; fi
    printf -v "$__var" '%s' "$reply"
}

need_tty() {
    [ -n "$FP_UNATTENDED" ] && die "unattended mode: missing required value ($1). Set the env var and re-run."
    [ -e /dev/tty ] || die "no terminal available for prompt ($1). Set $1 via env, or run interactively."
}

# ----------------------------------------------------------------------------
# 1. preflight
# ----------------------------------------------------------------------------
preflight() {
    step "Preflight"
    [ "$(id -u)" = 0 ] || die "must run as root."

    [ -r /etc/os-release ] || die "/etc/os-release missing — cannot identify OS."
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04) ok "OS: $PRETTY_NAME" ;;
        *) die "unsupported OS '${PRETTY_NAME:-?}'. This script targets Ubuntu 22.04/24.04." ;;
    esac

    # FastPanel requires a clean OS; refuse if a panel or DB is already present.
    if dpkg-query -W -f='${Status}' fastpanel2 2>/dev/null | grep -q "install ok installed"; then
        warn "fastpanel2 already installed — will skip the install step (idempotent re-run)."
        PANEL_PRESENT=1
    else
        PANEL_PRESENT=0
        for db in mysql-server mariadb-server percona-server-server; do
            if dpkg-query -W -f='${Status}' "$db" 2>/dev/null | grep -q "install ok installed"; then
                die "$db is already installed. FastPanel installs only on a clean OS. Use a fresh droplet."
            fi
        done
    fi

    export DEBIAN_FRONTEND=noninteractive
    step "System update + prerequisites"
    apt-get update -qq            >>"$LOG" 2>&1 || die "apt-get update failed (see $LOG)"
    apt-get -y -qq upgrade        >>"$LOG" 2>&1 || warn "apt upgrade returned non-zero (see $LOG)"
    apt-get -y -qq install wget ca-certificates whiptail >>"$LOG" 2>&1 \
        || die "failed to install prerequisites (see $LOG)"
    ok "system updated, prerequisites present"
}

# ----------------------------------------------------------------------------
# 2. gather config
# ----------------------------------------------------------------------------
gather_ssh_key() {
    step "SSH public key for root"
    if [ -z "$FP_SSH_KEY" ]; then
        need_tty FP_SSH_KEY
        echo "Paste the developer's SSH PUBLIC key (one line, ssh-ed25519/ssh-rsa...), then Enter." >/dev/tty
        echo "Leave empty to skip." >/dev/tty
        ask "key> " FP_SSH_KEY
    fi
    if [ -z "$FP_SSH_KEY" ]; then warn "no SSH key provided — skipping."; return; fi
    case "$FP_SSH_KEY" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) : ;;
        *) die "that does not look like an SSH public key (expected ssh-ed25519/ssh-rsa/ecdsa prefix)." ;;
    esac
    install -d -m 700 /root/.ssh
    touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    if grep -qxF "$FP_SSH_KEY" /root/.ssh/authorized_keys; then
        ok "SSH key already present."
    else
        printf '%s\n' "$FP_SSH_KEY" >> /root/.ssh/authorized_keys
        ok "SSH key added to /root/.ssh/authorized_keys."
    fi
}

gather_php() {
    step "PHP versions"
    if [ -z "$FP_PHP_VERSIONS" ]; then
        need_tty FP_PHP_VERSIONS
        local args=() v
        for v in "${PHP_CHOICES[@]}"; do
            local on=off; printf '%s ' "${PHP_DEFAULT_ON[@]}" | grep -qw "$v" && on=on
            args+=("$v" "PHP ${v:0:1}.${v:1}" "$on")
        done
        FP_PHP_VERSIONS="$(whiptail --title "PHP versions" --separate-output \
            --checklist "Space = toggle, Enter = confirm. Pick the versions your sites need:" \
            20 60 12 "${args[@]}" 3>&1 1>&2 2>&3)" || die "PHP selection cancelled."
        FP_PHP_VERSIONS="$(echo "$FP_PHP_VERSIONS" | tr '\n' ' ')"
    fi
    FP_PHP_VERSIONS="$(echo "$FP_PHP_VERSIONS" | tr ',' ' ' | xargs || true)"
    [ -n "$FP_PHP_VERSIONS" ] && ok "selected PHP: $FP_PHP_VERSIONS" || warn "no PHP versions selected."
}

gather_smtp() {
    step "Outgoing SMTP relay (msmtp)"
    if [ -z "$FP_SMTP_HOST" ] && [ -z "$FP_UNATTENDED" ]; then
        if [ -e /dev/tty ] && whiptail --title "Outgoing mail" \
            --yesno "Configure an external SMTP relay so this server can send mail?\n(Recommended. You can skip and add it later.)" 10 60; then
            ask "SMTP host (e.g. smtp.example.com): " FP_SMTP_HOST
            ask "SMTP port [587]: " FP_SMTP_PORT; FP_SMTP_PORT="${FP_SMTP_PORT:-587}"
            ask "SMTP username: " FP_SMTP_USER
            ask "SMTP password: " FP_SMTP_PASS silent
            ask "From address [${FP_SMTP_USER}]: " FP_SMTP_FROM; FP_SMTP_FROM="${FP_SMTP_FROM:-$FP_SMTP_USER}"
        fi
    fi
    if [ -n "$FP_SMTP_HOST" ]; then
        [ -n "$FP_SMTP_USER" ] && [ -n "$FP_SMTP_PASS" ] || die "SMTP host given but username/password missing."
        FP_SMTP_FROM="${FP_SMTP_FROM:-$FP_SMTP_USER}"
        ok "SMTP relay: $FP_SMTP_USER via $FP_SMTP_HOST:$FP_SMTP_PORT"
    else
        warn "no SMTP relay configured — the server will not send mail until /etc/msmtprc is set up."
    fi
}

# ----------------------------------------------------------------------------
# 3. install FastPanel
# ----------------------------------------------------------------------------
install_panel() {
    step "Install FastPanel + MySQL ($FP_MYSQL)"
    if [ "${PANEL_PRESENT:-0}" = 1 ]; then ok "panel already installed — skipped."; return; fi
    # Official installer: fully non-interactive (DEBIAN_FRONTEND, generates fastuser pw).
    set -o pipefail
    if ! wget -qO- "$INSTALL_URL" | bash -s -- -m "$FP_MYSQL" >>"$LOG" 2>&1; then
        die "FastPanel installer failed — see $LOG"
    fi
    dpkg-query -W -f='${Status}' fastpanel2 2>/dev/null | grep -q "install ok installed" \
        || die "installer finished but fastpanel2 is not installed — see $LOG"
    PANEL_PW="$(grep -aoP 'Password:\s*\K\S+' "$LOG" | tail -1 || true)"
    ok "FastPanel installed."
}

install_php() {
    step "Install PHP versions"
    [ -z "$FP_PHP_VERSIONS" ] && { warn "none selected — skipping PHP install."; return; }
    apt-get update -qq >>"$LOG" 2>&1 || true
    local v pkg
    for v in $FP_PHP_VERSIONS; do
        pkg="fastpanel2-php${v}"
        if apt-get install -y -qq "$pkg" >>"$LOG" 2>&1; then
            if [ -x "/opt/php${v}/bin/php" ]; then ok "PHP ${v:0:1}.${v:1} -> /opt/php${v}/bin/php"
            else warn "$pkg installed but /opt/php${v}/bin/php missing — check $LOG"; fi
        else
            warn "$pkg not available in repo — skipped (see $LOG)"
        fi
    done
}

# ----------------------------------------------------------------------------
# 5. trim unwanted services
# ----------------------------------------------------------------------------
trim_services() {
    step "Trim unneeded services (proftpd, dovecot, exim)"
    # mask (not just disable): a FastPanel self-update re-runs `services configure`
    # for exim/dovecot and would otherwise revive them.
    local svc
    for svc in proftpd dovecot; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
           && systemctl cat "${svc}.service" >/dev/null 2>&1; then
            systemctl disable --now "$svc" >>"$LOG" 2>&1 || true
            systemctl mask "$svc"          >>"$LOG" 2>&1 || true
            ok "$svc stopped + masked"
        else
            ok "$svc not installed — nothing to do"
        fi
    done
    # exim is handled together with mail: if we install msmtp we stop+mask exim,
    # otherwise we leave the base MTA in place (something must own sendmail).
}

# ----------------------------------------------------------------------------
# 6. mail via msmtp
# ----------------------------------------------------------------------------
setup_mail() {
    step "Outgoing mail via msmtp"
    if [ -z "$FP_SMTP_HOST" ]; then
        warn "no SMTP relay — leaving the base MTA in place, mail sending not configured."
        return
    fi
    # msmtp-mta diverts /usr/sbin/sendmail to msmtp via dpkg-divert.
    apt-get install -y -qq msmtp msmtp-mta >>"$LOG" 2>&1 || die "failed to install msmtp (see $LOG)"

    local tls_line="tls on" starttls="tls_starttls on"
    [ "$FP_SMTP_TLS" = "off" ] && { tls_line="tls off"; starttls="tls_starttls off"; }

    umask 077
    cat > /etc/msmtprc <<EOF
# managed by fastpanel-provision.sh — external SMTP relay for outgoing mail
defaults
auth           on
$tls_line
$starttls
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        relay
host           $FP_SMTP_HOST
port           $FP_SMTP_PORT
from           $FP_SMTP_FROM
user           $FP_SMTP_USER
password       $FP_SMTP_PASS

account default : relay
EOF
    chmod 600 /etc/msmtprc; chown root:root /etc/msmtprc
    touch /var/log/msmtp.log; chmod 660 /var/log/msmtp.log

    # ensure /usr/sbin/sendmail resolves to msmtp, and retire exim
    if [ ! -e /usr/sbin/sendmail ] || ! readlink -f /usr/sbin/sendmail | grep -q msmtp; then
        ln -sf /usr/bin/msmtp /usr/sbin/sendmail
    fi
    for svc in exim4 exim; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            systemctl disable --now "$svc" >>"$LOG" 2>&1 || true
            systemctl mask "$svc"          >>"$LOG" 2>&1 || true
            ok "$svc stopped + masked (msmtp owns sendmail now)"
        fi
    done
    ok "/etc/msmtprc written (600); /usr/sbin/sendmail -> $(readlink -f /usr/sbin/sendmail)"
}

# ----------------------------------------------------------------------------
# 7. finish
# ----------------------------------------------------------------------------
finish() {
    step "Done"
    local ip; ip="$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
    {
        echo "FastPanel:   https://${ip}:8888/   (login: fastuser)"
        [ -n "${PANEL_PW:-}" ] && echo "Password:    ${PANEL_PW}"
        echo "PHP:         ${FP_PHP_VERSIONS:-none}"
        if [ -n "$FP_SMTP_HOST" ]; then echo "Mail:        relay via $FP_SMTP_HOST:$FP_SMTP_PORT"
        else echo "Mail:        not configured"; fi
        echo "Trimmed:     proftpd, dovecot${FP_SMTP_HOST:+, exim} (masked)"
        echo "Log:         $LOG"
    } | tee -a "$LOG"

    if [ -z "$FP_REBOOT" ]; then
        if [ -e /dev/tty ] && [ -z "$FP_UNATTENDED" ]; then
            whiptail --title "Reboot" --yesno "Reboot now to finish?" 8 50 && FP_REBOOT=yes || FP_REBOOT=no
        else
            FP_REBOOT=no
        fi
    fi
    if [ "$FP_REBOOT" = yes ]; then step "Rebooting..."; sleep 2; reboot
    else warn "reboot skipped — run 'reboot' when convenient."; fi
}

main() {
    printf '%s\n' "fastpanel-provision.sh — log: $LOG"
    preflight
    gather_ssh_key
    gather_php
    gather_smtp
    install_panel
    install_php
    trim_services
    setup_mail
    finish
}

main "$@"
