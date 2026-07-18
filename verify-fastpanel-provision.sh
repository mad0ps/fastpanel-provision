#!/usr/bin/env bash
# Verify the end-state of fastpanel-provision.sh. Run ON the provisioned server.
# Usage: verify-fastpanel-provision.sh "74 82" [expect_mail=1]
set -uo pipefail
EXPECT_PHP="${1:-}"
EXPECT_MAIL="${2:-1}"
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL  $1"; fail=$((fail+1)); }

echo "=== 1. FastPanel installed and listening on :8888 ==="
dpkg-query -W -f='${Status}' fastpanel2 2>/dev/null | grep -q "install ok installed" \
  && ok "fastpanel2 package installed" || bad "fastpanel2 not installed"
ss -tlnp 2>/dev/null | grep -q ':8888' && ok ":8888 listening" || bad ":8888 not listening"

echo "=== 2. MySQL present ==="
(command -v mysql >/dev/null && mysql --version) && ok "mysql client present" || bad "mysql missing"
ss -tlnp 2>/dev/null | grep -q ':3306' && ok ":3306 listening" || bad ":3306 not listening"

echo "=== 3. requested PHP versions installed ==="
for v in $EXPECT_PHP; do
  [ -x "/opt/php${v}/bin/php" ] && ok "PHP ${v} -> $(/opt/php${v}/bin/php -r 'echo PHP_VERSION;' 2>/dev/null)" \
    || bad "PHP ${v} missing (/opt/php${v}/bin/php)"
done

echo "=== 4. unwanted services masked ==="
for svc in proftpd dovecot exim4; do
  st="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  if [ "$st" = masked ]; then ok "$svc masked"
  elif [ -z "$st" ] || [ "$st" = "not-found" ]; then ok "$svc absent"
  else bad "$svc is '$st' (expected masked/absent)"; fi
done
echo "--- listeners that should be GONE (21/25 unless mail relay uses local):"
ss -tlnp 2>/dev/null | grep -E ':(21|110|143|993|995)\b' && bad "ftp/imap/pop listener present" || ok "no ftp/imap/pop listeners"

echo "=== 5. mail via msmtp ==="
if [ "$EXPECT_MAIL" = 1 ]; then
  command -v msmtp >/dev/null && ok "msmtp installed" || bad "msmtp missing"
  [ -f /etc/msmtprc ] && [ "$(stat -c %a /etc/msmtprc)" = 600 ] && ok "/etc/msmtprc present, mode 600" || bad "/etc/msmtprc missing or wrong mode"
  readlink -f /usr/sbin/sendmail 2>/dev/null | grep -q msmtp && ok "sendmail -> msmtp" || bad "sendmail not pointing at msmtp"
else
  echo "  (mail not expected — skipped)"
fi

echo "=== 6. root SSH key present ==="
[ -s /root/.ssh/authorized_keys ] && ok "authorized_keys non-empty ($(wc -l < /root/.ssh/authorized_keys) key(s))" || bad "authorized_keys empty"

echo
echo "==============================="
echo "  passed: $pass   failed: $fail"
echo "==============================="
[ "$fail" -eq 0 ]
