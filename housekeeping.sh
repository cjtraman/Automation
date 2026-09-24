#!/usr/bin/env bash
# housekeeping.sh - post-install checks and setup for the Jenkins automation host.
#
# Usage:   sudo bash housekeeping.sh [--check-only]
# Optional environment variables:
#   VCENTER=vcenter.lab.local     platform API host Terraform must reach
#   REPO_URL=git@github.com:org/repo.git   test a checkout as the jenkins user
#   EXTRA_HOSTS="host1 host2"     more HTTPS hosts to test
#   HOST_IP, FQDN, JENKINS_HOME, BACKUP_DIR   override the detected defaults
#
# What it does:
#   1. Checks Jenkins security settings (reads config.xml, changes nothing)
#   2. Installs the nightly Jenkins backup job and runs it once
#   3. Checks the firewall rules and which ports are listening
#   4. Prepares GitHub SSH host keys for the jenkins user and tests a checkout
#   5. Tests outbound HTTPS reachability as the jenkins user
# Nothing here changes firewall rules or Jenkins settings. Fixes are printed for you to apply.

set -uo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
BACKUP_DIR="${BACKUP_DIR:-/backup/jenkins}"
HOST_IP="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
FQDN="${FQDN:-automation-01.lab.local}"
VCENTER="${VCENTER:-}"
REPO_URL="${REPO_URL:-}"
EXTRA_HOSTS="${EXTRA_HOSTS:-}"
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

PASS_N=0; WARN_N=0; FAIL_N=0
ok()   { printf '  [ OK ] %s\n'   "$*"; PASS_N=$((PASS_N + 1)); }
warn() { printf '  [WARN] %s\n'   "$*"; WARN_N=$((WARN_N + 1)); }
fail() { printf '  [FAIL] %s\n'   "$*"; FAIL_N=$((FAIL_N + 1)); }
info() { printf '  [INFO] %s\n'   "$*"; }

# ---------- helpers (kept separate so they can be tested) ----------

# Reads "ufw status" text on stdin; prints ALLOW/LIMIT rules that are not SSH or 443.
ufw_extra_rules() {
  grep -E 'ALLOW|LIMIT' | grep -vE '(^|[[:space:]])(22|443)(/tcp)?([[:space:]]|$)|^OpenSSH'
}

# Reads "ss -tlnH" text on stdin; prints local addresses that are listening on port $1.
listeners_for_port() {
  awk -v p=":$1" '{ a=$4; if (length(a) >= length(p) && substr(a, length(a) - length(p) + 1) == p) print a }'
}

# ---------- 1. Jenkins security ----------
jenkins_security() {
  echo "== 1. Jenkins security =="
  local cfg="$JENKINS_HOME/config.xml"
  if [ ! -r "$cfg" ]; then
    fail "cannot read $cfg (run with sudo, and check Jenkins is installed)"
    return
  fi

  if grep -q '<useSecurity>false</useSecurity>' "$cfg"; then
    fail "security is disabled: Manage Jenkins > Security"
  else
    ok "security is enabled"
  fi

  if grep -q '<disableSignup>true</disableSignup>' "$cfg"; then
    ok "user sign-up is disabled"
  elif grep -q 'HudsonPrivateSecurityRealm' "$cfg"; then
    fail "user sign-up is allowed: untick 'Allow users to sign up'"
  else
    warn "not using Jenkins' own user database, sign-up check skipped"
  fi

  local strat
  strat=$(grep -o '<authorizationStrategy class="[^"]*"' "$cfg" | sed 's/.*class="//; s/"$//' | head -1)
  case "$strat" in
    *GlobalMatrixAuthorizationStrategy*|*ProjectMatrixAuthorizationStrategy*)
      ok "Matrix authorization is on ($strat)" ;;
    *FullControlOnceLoggedIn*)
      warn "'Logged-in users can do anything' is active, not Matrix. Switch in Manage Jenkins > Security if you need per-user permissions" ;;
    *)
      fail "authorization strategy is '${strat:-none}': choose Matrix-based security" ;;
  esac

  local anon
  anon=$(grep -o '<permission>[^<]*:anonymous</permission>' "$cfg" | sed 's/<[^>]*>//g' | tr '\n' ' ')
  if [ -n "$anon" ]; then
    fail "anonymous user has permissions: $anon"
  elif grep -q '<denyAnonymousReadAccess>false</denyAnonymousReadAccess>' "$cfg"; then
    fail "anonymous read access is allowed"
  else
    ok "anonymous has no permissions"
  fi
}

# ---------- 2. Backups ----------
install_backup() {
  echo "== 2. Backups =="
  if [ "$CHECK_ONLY" -eq 1 ]; then
    [ -x /usr/local/bin/jenkins-backup.sh ] && ok "backup script installed" || warn "backup script not installed (skipped by --check-only)"
    [ -f /etc/cron.d/jenkins-backup ] && ok "nightly cron job present" || warn "nightly cron job missing"
    return
  fi
  if [ ! -d "$JENKINS_HOME" ]; then
    fail "$JENKINS_HOME does not exist, nothing to back up"
    return
  fi

  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"

  cat > /usr/local/bin/jenkins-backup.sh <<'BACKUP_EOF'
#!/usr/bin/env bash
# Nightly Jenkins backup. The archive contains credentials and secret keys: keep it private.
set -uo pipefail
umask 077
SRC="__JENKINS_HOME__"
DEST="__BACKUP_DIR__"
mkdir -p "$DEST"
OUT="$DEST/jenkins-$(date +%F_%H%M).tgz"
tar --warning=no-file-changed \
    --exclude='workspace' --exclude='caches' --exclude='logs' --exclude='.cache' \
    -czf "$OUT" -C "$(dirname "$SRC")" "$(basename "$SRC")"
rc=$?
# tar exit 1 means "a file changed while reading", which is normal on a live Jenkins
if [ "$rc" -gt 1 ]; then
  echo "backup failed (tar exit $rc)" >&2
  rm -f "$OUT"
  exit "$rc"
fi
find "$DEST" -name 'jenkins-*.tgz' -mtime +14 -delete
logger -t jenkins-backup "created $OUT"
BACKUP_EOF
  sed -i "s|__JENKINS_HOME__|$JENKINS_HOME|; s|__BACKUP_DIR__|$BACKUP_DIR|" /usr/local/bin/jenkins-backup.sh
  chmod 700 /usr/local/bin/jenkins-backup.sh
  echo '0 2 * * * root /usr/local/bin/jenkins-backup.sh' > /etc/cron.d/jenkins-backup
  chmod 644 /etc/cron.d/jenkins-backup
  ok "installed /usr/local/bin/jenkins-backup.sh and cron job (02:00 daily, 14 days kept)"

  if /usr/local/bin/jenkins-backup.sh; then
    local latest
    latest=$(ls -t "$BACKUP_DIR"/jenkins-*.tgz 2>/dev/null | head -1)
    if [ -n "$latest" ] && tar -tzf "$latest" >/dev/null 2>&1; then
      ok "test backup created and readable: $latest ($(du -h "$latest" | cut -f1))"
    else
      fail "test backup was not created or is unreadable"
    fi
  else
    fail "test backup run failed: check disk space in $BACKUP_DIR"
  fi

  if [ "$(stat -c %d "$BACKUP_DIR" 2>/dev/null)" = "$(stat -c %d "$JENKINS_HOME" 2>/dev/null)" ]; then
    warn "backups are on the same filesystem as Jenkins: mount a separate disk or share at $BACKUP_DIR"
  fi
  warn "MANUAL: take a VM snapshot in your hypervisor now (this script cannot do that)"
}

# ---------- 3. Firewall and listeners ----------
firewall_and_listeners() {
  echo "== 3. Firewall and listening ports =="
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed"
  else
    local st
    st=$(ufw status verbose 2>&1)
    if ! printf '%s\n' "$st" | grep -q '^Status: active'; then
      fail "ufw is not active: sudo ufw enable (allow OpenSSH first)"
    else
      ok "ufw is active"
      printf '%s\n' "$st" | grep -qi 'deny (incoming)' && ok "default incoming policy is deny" || warn "default incoming policy is not deny"
      local extra
      extra=$(printf '%s\n' "$st" | ufw_extra_rules)
      if [ -n "$extra" ]; then
        fail "rules other than SSH and 443 exist (remove with: sudo ufw delete <number>, see 'ufw status numbered'):"
        printf '%s\n' "$extra" | sed 's/^/           /'
      else
        ok "only SSH and 443 are allowed"
      fi
    fi
  fi

  local ss_out
  ss_out=$(ss -tlnH 2>/dev/null)

  local a443 a80 a8080 bad=0 a
  a443=$(printf '%s\n' "$ss_out" | listeners_for_port 443)
  a80=$(printf '%s\n' "$ss_out" | listeners_for_port 80)
  a8080=$(printf '%s\n' "$ss_out" | listeners_for_port 8080)

  if [ -z "$a443" ]; then
    fail "nothing is listening on 443: check nginx (sudo nginx -t; systemctl status nginx)"
  elif [ "$a443" = "$HOST_IP:443" ]; then
    ok "nginx listens on $HOST_IP:443 only"
  else
    warn "443 listeners: $(echo $a443) (expected $HOST_IP:443)"
  fi

  if [ -n "$a80" ]; then
    fail "something listens on port 80: $(echo $a80) (remove the port 80 server block in nginx)"
  else
    ok "port 80 is not listening"
  fi

  if [ -z "$a8080" ]; then
    fail "Jenkins is not listening on 8080: systemctl status jenkins"
  else
    for a in $a8080; do
      case "$a" in
        127.0.0.1:8080|'[::ffff:127.0.0.1]:8080'|'[::1]:8080') ;;
        *) bad=1 ;;
      esac
    done
    if [ "$bad" -eq 0 ]; then
      ok "Jenkins listens on localhost only ($(echo $a8080))"
    else
      fail "Jenkins is reachable beyond localhost ($(echo $a8080)): set JENKINS_LISTEN_ADDRESS=127.0.0.1 in the systemd override"
    fi
  fi
}

# ---------- 4. Git over SSH ----------
git_ssh() {
  echo "== 4. Git and GitHub access =="
  local ssh_dir="$JENKINS_HOME/.ssh" kh="$JENKINS_HOME/.ssh/known_hosts"
  if ! id jenkins >/dev/null 2>&1; then
    fail "user 'jenkins' does not exist"
    return
  fi

  if timeout 6 bash -c '</dev/tcp/github.com/22' 2>/dev/null; then
    ok "outbound SSH (22) to github.com works"
  else
    warn "cannot reach github.com:22, use an HTTPS repo URL with a personal access token instead"
  fi

  if [ "$CHECK_ONLY" -eq 0 ]; then
    sudo -H -u jenkins mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"
  fi
  if sudo -H -u jenkins ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1; then
    ok "github.com host key is already trusted by the jenkins user"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "github.com host key is not trusted yet (skipped by --check-only)"
  else
    local key
    key=$(timeout 15 ssh-keyscan -t ed25519 github.com 2>/dev/null)
    if [ -n "$key" ]; then
      printf '%s\n' "$key" | sudo -H -u jenkins tee -a "$kh" >/dev/null
      ok "added github.com host key to $kh"
      info "fingerprint: $(printf '%s\n' "$key" | ssh-keygen -lf - 2>/dev/null)"
      info "compare it with GitHub's published SSH key fingerprints (docs.github.com) once"
    else
      fail "ssh-keyscan returned nothing for github.com"
    fi
  fi

  if [ -n "$REPO_URL" ]; then
    if sudo -H -u jenkins env GIT_TERMINAL_PROMPT=0 timeout 25 git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1; then
      ok "jenkins user can read $REPO_URL"
    else
      warn "jenkins user cannot read $REPO_URL from the shell. That is expected for a private repo: the key or token lives in the Jenkins credential store, so test with a pipeline checkout"
    fi
  else
    info "set REPO_URL=... to test a checkout. Deploy key or token goes into Manage Jenkins > Credentials"
  fi
}

# ---------- 5. Outbound reachability ----------
reachability() {
  echo "== 5. Outbound HTTPS from the jenkins user =="
  if ! id jenkins >/dev/null 2>&1; then
    fail "user 'jenkins' does not exist, cannot test as that user"
    return
  fi
  local h code
  for h in registry.terraform.io releases.hashicorp.com github.com api.samanage.com galaxy.ansible.com pkg.jenkins.io $EXTRA_HOSTS; do
    code=$(sudo -H -u jenkins curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
      fail "$h unreachable (DNS, firewall or proxy)"
    else
      ok "$h answered HTTP $code"
    fi
  done

  if [ -n "$VCENTER" ]; then
    if getent hosts "$VCENTER" >/dev/null 2>&1; then
      code=$(sudo -H -u jenkins curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$VCENTER/" 2>/dev/null)
      if [ -z "$code" ] || [ "$code" = "000" ]; then
        fail "$VCENTER resolves but HTTPS failed (firewall or service down)"
      else
        ok "$VCENTER answered HTTP $code (certificate not verified in this test)"
      fi
    else
      fail "$VCENTER does not resolve from this host (DNS)"
    fi
  else
    info "set VCENTER=<fqdn> to test the platform Terraform will call"
  fi
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash $0 [--check-only]" >&2
    exit 2
  fi
  echo "Housekeeping for $FQDN ($HOST_IP), Jenkins home $JENKINS_HOME"
  [ "$CHECK_ONLY" -eq 1 ] && echo "(check-only mode: no files are created or changed)"
  echo
  jenkins_security; echo
  install_backup; echo
  firewall_and_listeners; echo
  git_ssh; echo
  reachability; echo
  echo "== Summary: $PASS_N ok, $WARN_N warnings, $FAIL_N failures =="
  [ "$FAIL_N" -eq 0 ]
}

# Run main only when executed directly (lets the helpers be sourced for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
