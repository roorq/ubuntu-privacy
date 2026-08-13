#!/usr/bin/env bash
#
# ubuntu-privacy.sh - disable telemetry and "phone home" behaviour in Ubuntu (24.04 / 25.10 / 26.04)
#
#   https://github.com/roorq/ubuntu-privacy
#
#   curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes
#
# Every modified file is copied to /var/backups/ubuntu-privacy-<date>/, which also
# receives a restore.sh that reverts all the changes.
#
set -euo pipefail

VERSION="1.0.0"
REPO_URL="https://github.com/roorq/ubuntu-privacy"
RAW_URL="https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh"
DRY_RUN=0
ASSUME_YES=0
DO_PURGE=0
DO_HOSTS=0
DO_FIREFOX=1
DO_CONNCHECK=1

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/ubuntu-privacy-${STAMP}"
LOG_FILE="/var/log/ubuntu-privacy.log"
[ "$(id -u)" -eq 0 ] || LOG_FILE="/dev/null"   # without root we do not try to write to /var/log

PURGED_PKGS=()
MASKED_UNITS=()
CREATED_FILES=()

# ---------------------------------------------------------------- ui helpers
if [ -t 1 ]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

log()  { printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s\n' "${C_B}::${C_0} $*"; log "[info] $*"; }
ok()   { printf '%s\n' "${C_G} +${C_0} $*"; log "[ok]   $*"; }
warn() { printf '%s\n' "${C_Y} !${C_0} $*"; log "[warn] $*"; }
err()  { printf '%s\n' "${C_R} x${C_0} $*" >&2; log "[err]  $*"; }
skip() { printf '%s\n' "${C_D} -  $* (skipping)${C_0}"; log "[skip] $*"; }
hdr()  { printf '\n%s\n' "${C_B}=== $* ===${C_0}"; log "=== $* ==="; }

usage() {
    cat <<EOF
ubuntu-privacy.sh v${VERSION}
https://github.com/roorq/ubuntu-privacy

Usage:  sudo ./ubuntu-privacy.sh [options]
    or: curl -fsSL ${RAW_URL} | sudo bash -s -- [options]

Options:
  -y, --yes           do not ask for confirmation (required with curl|bash)
  -n, --dry-run       show what would be done, change nothing
      --purge         additionally REMOVE the packages (apport, whoopsie, popularity-contest...)
                      note: may remove the ubuntu-desktop metapackage (the system keeps working)
      --hosts         block telemetry domains in /etc/hosts
      --no-firefox    do not write the Firefox policies
      --keep-conncheck  leave NetworkManager's connectivity checking in place
                        (connectivity-check.ubuntu.com - needed for captive portals)
  -h, --help          this help

What it does by default:
  * disables and masks: whoopsie, apport, kerneloops, motd-news, apt-news, esm-cache
  * disables ubuntu-report and popularity-contest
  * disables error reporting and usage statistics in GNOME (dconf + per-user gsettings)
  * disables GNOME geolocation
  * neutralises the Ubuntu Pro/ESM ads in APT and in the MOTD
  * clears the reports collected in /var/crash and ~/.cache/ubuntu-report
  * writes the Firefox privacy policies (unless you already have your own)
EOF
}

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)          ASSUME_YES=1 ;;
        -n|--dry-run)      DRY_RUN=1 ;;
        --purge)           DO_PURGE=1 ;;
        --hosts)           DO_HOSTS=1 ;;
        --no-firefox)      DO_FIREFOX=0 ;;
        --keep-conncheck)  DO_CONNCHECK=0 ;;
        -h|--help)         usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- sanity
if [ "$(id -u)" -ne 0 ]; then
    err "Run as root:  curl -fsSL ${RAW_URL} | sudo bash -s -- --yes"
    exit 1
fi

OS_NAME="unknown"; OS_VER=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"; OS_VER="${VERSION_ID:-}"
fi

case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*) : ;;
    *) warn "This system is '${OS_NAME}' - the script targets Ubuntu, some steps may not apply." ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
    err "No apt-get - this is not a Debian-based system. Aborting."
    exit 1
fi

hdr "ubuntu-privacy.sh v${VERSION}"
info "System: ${OS_NAME} ${OS_VER}"
info "Backup: ${BACKUP_DIR}"
[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN - no changes will be written"
[ "$DO_PURGE" -eq 1 ] && warn "--purge: packages will be removed, not just disabled"

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        printf '\n%s' "Continue? [y/N] "
        read -r reply </dev/tty || reply=""
        case "$reply" in
            y|Y|yes|YES) : ;;
            *) info "Cancelled."; exit 0 ;;
        esac
    else
        err "No terminal to confirm on. Add --yes (or --dry-run) when using curl|bash."
        exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- primitives
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   \$ $*${C_0}"
        return 0
    fi
    log "\$ $*"
    "$@" >>"$LOG_FILE" 2>&1
}

backup_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && { printf '%s\n' "${C_D}   backup: $f${C_0}"; return 0; }
    local dest="${BACKUP_DIR}/files$(dirname "$f")"
    mkdir -p "$dest"
    cp -a "$f" "$dest/" 2>/dev/null || return 0
    printf '%s\n' "$f" >>"${BACKUP_DIR}/manifest.files"
}

# write_file <path> <<'EOF' ... EOF
write_file() {
    local f="$1" content
    content="$(cat)"
    backup_file "$f"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   write: $f${C_0}"
        return 0
    fi
    [ -e "$f" ] || printf '%s\n' "$f" >>"${BACKUP_DIR}/manifest.created"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$content" >"$f"
    chmod 644 "$f"
}

unit_exists() { systemctl cat -- "$1" >/dev/null 2>&1; }

disable_unit() {
    local u="$1"
    if ! unit_exists "$u"; then skip "unit $u does not exist"; return 0; fi
    run systemctl disable --now -- "$u" || true
    run systemctl mask -- "$u" || true
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$u" >>"${BACKUP_DIR}/manifest.units"
    ok "disabled and masked: $u"
}

pkg_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$'; }

purge_pkg() {
    local p="$1"
    if ! pkg_installed "$p"; then skip "package $p is not installed"; return 0; fi
    run apt-get purge -y -- "$p" || { warn "failed to remove $p"; return 0; }
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$p" >>"${BACKUP_DIR}/manifest.pkgs"
    ok "package removed: $p"
}

# gsettings for every logged-in user
gset_all_users() {
    local schema="$1" key="$2" val="$3" uid u
    for d in /run/user/*; do
        [ -d "$d" ] || continue
        uid="$(basename "$d")"
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        u="$(id -nu "$uid" 2>/dev/null)" || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '%s\n' "${C_D}   [$u] gsettings set $schema $key $val${C_0}"
            continue
        fi
        sudo -u "$u" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${d}/bus" \
            gsettings set "$schema" "$key" "$val" >>"$LOG_FILE" 2>&1 || true
    done
}

if [ "$DRY_RUN" -ne 1 ]; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    : >"$LOG_FILE" || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    log "start $(date -Is) - ${OS_NAME} ${OS_VER} - options: purge=$DO_PURGE hosts=$DO_HOSTS firefox=$DO_FIREFOX"
fi

# ================================================================= 1. units
hdr "1/8  Telemetry and reporting units"

for u in \
    whoopsie.service \
    whoopsie.path \
    apport.service \
    apport-autoreport.service \
    apport-autoreport.timer \
    apport-autoreport.path \
    kerneloops.service \
    motd-news.service \
    motd-news.timer \
    apt-news.service \
    esm-cache.service \
    ubuntu-advantage.service \
    ua-timer.timer \
    ua-timer.service \
    ua-reboot-cmds.service \
    ubuntu-report.service \
    popularity-contest.service \
    popularity-contest.timer
do
    disable_unit "$u"
done

# ================================================================= 2. apport
hdr "2/8  Apport (collecting and uploading crash dumps)"

write_file /etc/default/apport <<'EOF'
# set by ubuntu-privacy.sh
# 0 = apport neither collects nor uploads crash reports
enabled=0
EOF
ok "/etc/default/apport: enabled=0"

write_file /etc/apport/autoreport <<'EOF'
# set by ubuntu-privacy.sh - no automatic uploading
EOF

# no new dumps reach apport
write_file /etc/sysctl.d/60-ubuntu-privacy-nocoredump.conf <<'EOF'
# set by ubuntu-privacy.sh
kernel.core_pattern=|/bin/false
EOF
run sysctl -p /etc/sysctl.d/60-ubuntu-privacy-nocoredump.conf || true
ok "core_pattern redirected away from apport"

if [ -d /var/crash ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   \$ rm -f /var/crash/*${C_0}"
    else
        find /var/crash -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    fi
    ok "/var/crash cleared"
fi

# ================================================================= 3. whoopsie
hdr "3/8  Whoopsie (uploads reports to errors.ubuntu.com)"

write_file /etc/whoopsie <<'EOF'
# set by ubuntu-privacy.sh
[General]
report_crashes=false
EOF
ok "/etc/whoopsie: report_crashes=false"

# ================================================================= 4. popcon + ubuntu-report
hdr "4/8  popularity-contest and ubuntu-report"

if [ -f /etc/popularity-contest.conf ]; then
    backup_file /etc/popularity-contest.conf
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   sed: PARTICIPATE=no in /etc/popularity-contest.conf${C_0}"
    else
        if grep -q '^ *PARTICIPATE=' /etc/popularity-contest.conf; then
            sed -i 's/^ *PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf
        else
            printf 'PARTICIPATE="no"\n' >>/etc/popularity-contest.conf
        fi
    fi
    ok "popularity-contest: PARTICIPATE=no"
else
    skip "no /etc/popularity-contest.conf"
fi

# ubuntu-report: users' pending report cache
for home in /home/* /root; do
    [ -d "$home/.cache/ubuntu-report" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   \$ rm -rf $home/.cache/ubuntu-report${C_0}"
    else
        rm -rf "$home/.cache/ubuntu-report"
    fi
    ok "ubuntu-report cache removed: $home"
done

# ================================================================= 5. Pro/ESM ads + MOTD
hdr "5/8  Ubuntu Pro / ESM / MOTD-news"

write_file /etc/default/motd-news <<'EOF'
# set by ubuntu-privacy.sh
# 0 = no fetching of "news" from motd.ubuntu.com at login
ENABLED=0
URLS=""
WAIT=1
EOF
ok "motd-news disabled"

for f in /etc/update-motd.d/10-help-text \
         /etc/update-motd.d/50-motd-news \
         /etc/update-motd.d/88-esm-announce \
         /etc/update-motd.d/91-contract-ua-esm-status \
         /etc/update-motd.d/91-release-upgrade
do
    [ -e "$f" ] || continue
    backup_file "$f"
    run chmod -x "$f" || true
    ok "MOTD fragment disabled: $(basename "$f")"
done

# the APT hook that injects ESM ads into every apt update/upgrade
if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
    write_file /etc/apt/apt.conf.d/20apt-esm-hook.conf <<'EOF'
// blanked out by ubuntu-privacy.sh - the original is in /var/backups/ubuntu-privacy-*/
EOF
    ok "APT ESM-ad hook blanked out"
else
    skip "no 20apt-esm-hook.conf"
fi

if command -v pro >/dev/null 2>&1; then
    run pro config set apt_news=false || true
    ok "pro: apt_news=false"
fi

# ================================================================= 6. GNOME / dconf
hdr "6/8  GNOME: problem reporting, statistics, geolocation"

if [ -d /etc/dconf ] || command -v dconf >/dev/null 2>&1; then
    if [ ! -f /etc/dconf/profile/user ]; then
        write_file /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
        ok "dconf profile /etc/dconf/profile/user created"
    elif ! grep -q '^system-db:local' /etc/dconf/profile/user; then
        backup_file /etc/dconf/profile/user
        [ "$DRY_RUN" -eq 1 ] || printf 'system-db:local\n' >>/etc/dconf/profile/user
        ok "system-db:local added to the dconf profile"
    fi

    write_file /etc/dconf/db/local.d/00-ubuntu-privacy <<'EOF'
# set by ubuntu-privacy.sh
[org/gnome/desktop/privacy]
report-technical-problems=false
send-software-usage-stats=false
remember-recent-files=false
remember-app-usage=false
remove-old-temp-files=true
remove-old-trash-files=true

[org/gnome/system/location]
enabled=false
EOF
    run dconf update || true
    ok "system-wide dconf defaults written"
else
    skip "dconf unavailable (system without GNOME)"
fi

gset_all_users org.gnome.desktop.privacy report-technical-problems false
gset_all_users org.gnome.desktop.privacy send-software-usage-stats false
gset_all_users org.gnome.desktop.privacy remember-recent-files false
gset_all_users org.gnome.desktop.privacy remember-app-usage false
gset_all_users org.gnome.system.location enabled false
ok "settings applied for the logged-in users"

# ================================================================= 7. network
hdr "7/8  Background network requests"

if [ "$DO_CONNCHECK" -eq 1 ]; then
    if [ -d /etc/NetworkManager ]; then
        write_file /etc/NetworkManager/conf.d/99-ubuntu-privacy.conf <<'EOF'
# set by ubuntu-privacy.sh
# stops the periodic polling of connectivity-check.ubuntu.com
[connectivity]
enabled=false
uri=
interval=0
EOF
        run systemctl reload NetworkManager || run systemctl restart NetworkManager || true
        ok "NetworkManager connectivity checking disabled"
        warn "side effect: no automatic captive portal detection (hotels, airports)"
    else
        skip "no NetworkManager"
    fi
else
    skip "connectivity checking left in place (--keep-conncheck)"
fi

if [ "$DO_HOSTS" -eq 1 ]; then
    backup_file /etc/hosts
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   appending blocks to /etc/hosts${C_0}"
    else
        if ! grep -q 'ubuntu-privacy.sh BEGIN' /etc/hosts; then
            cat >>/etc/hosts <<'EOF'

# ubuntu-privacy.sh BEGIN - telemetry domain blocklist
0.0.0.0 metrics.ubuntu.com
0.0.0.0 popcon.ubuntu.com
0.0.0.0 daisy.ubuntu.com
0.0.0.0 errors.ubuntu.com
0.0.0.0 connectivity-check.ubuntu.com
0.0.0.0 motd.ubuntu.com
0.0.0.0 contracts.canonical.com
0.0.0.0 incoming.telemetry.mozilla.org
0.0.0.0 telemetry.mozilla.org
# ubuntu-privacy.sh END
EOF
        fi
    fi
    ok "telemetry domains blocked in /etc/hosts"
    warn "blocking contracts.canonical.com also breaks Ubuntu Pro, if you use it"
else
    skip "/etc/hosts blocking (enable with --hosts)"
fi

if [ "$DO_FIREFOX" -eq 1 ]; then
    if [ -e /etc/firefox/policies/policies.json ]; then
        skip "/etc/firefox/policies/policies.json already exists - not overwriting"
    else
        write_file /etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableDefaultBrowserAgent": true,
    "DisableFeedbackCommands": true,
    "UserMessaging": {
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "UrlbarInterventions": false,
      "SkipOnboarding": true
    },
    "Preferences": {
      "datareporting.healthreport.uploadEnabled": false,
      "datareporting.policy.dataSubmissionEnabled": false,
      "toolkit.telemetry.enabled": false,
      "toolkit.telemetry.unified": false,
      "toolkit.telemetry.archive.enabled": false,
      "browser.ping-centre.telemetry": false,
      "browser.newtabpage.activity-stream.feeds.telemetry": false,
      "browser.newtabpage.activity-stream.telemetry": false,
      "app.shield.optoutstudies.enabled": false
    }
  }
}
EOF
        ok "Firefox privacy policies written"
    fi
else
    skip "Firefox policies (--no-firefox)"
fi

# ================================================================= 8. packages
hdr "8/8  Packages"

if [ "$DO_PURGE" -eq 1 ]; then
    for p in ubuntu-report popularity-contest apport apport-symptoms apport-gtk \
             whoopsie whoopsie-preferences kerneloops
    do
        purge_pkg "$p"
    done
    run apt-get autoremove -y || true
else
    info "the packages stay installed but are disabled (use --purge to remove them)"
fi

# ================================================================= restore.sh
if [ "$DRY_RUN" -ne 1 ]; then
    cat >"${BACKUP_DIR}/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
# Reverts the changes made by ubuntu-privacy.sh. Run as root.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. files created by the script - remove them
if [ -f "$DIR/manifest.created" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f" && echo "removed $f"
    done <"$DIR/manifest.created"
fi

# 2. modified files - restore them from the backup
if [ -f "$DIR/manifest.files" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        src="$DIR/files$f"
        [ -e "$src" ] || continue
        mkdir -p "$(dirname "$f")"
        cp -a "$src" "$f" && echo "restored $f"
    done <"$DIR/manifest.files"
fi

# 3. systemd units - unmask and enable
if [ -f "$DIR/manifest.units" ]; then
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        systemctl unmask "$u" 2>/dev/null || true
        systemctl enable --now "$u" 2>/dev/null || true
        echo "enabled $u"
    done <"$DIR/manifest.units"
fi

# 4. packages removed by --purge
if [ -f "$DIR/manifest.pkgs" ]; then
    mapfile -t pkgs <"$DIR/manifest.pkgs"
    if [ "${#pkgs[@]}" -gt 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    fi
fi

# 5. /etc/hosts entries
if grep -q 'ubuntu-privacy.sh BEGIN' /etc/hosts 2>/dev/null; then
    sed -i '/ubuntu-privacy.sh BEGIN/,/ubuntu-privacy.sh END/d' /etc/hosts
    echo "removed the blocks from /etc/hosts"
fi

command -v dconf >/dev/null && dconf update || true
sysctl -p /etc/sysctl.d/*.conf >/dev/null 2>&1 || true
systemctl daemon-reload || true
echo
echo "Restore complete. A reboot is recommended."
RESTORE
    chmod 700 "${BACKUP_DIR}/restore.sh"
fi

# ================================================================= summary
hdr "Done"

if [ "$DRY_RUN" -eq 1 ]; then
    info "That was a dry run - nothing was changed."
    info "Run again without --dry-run (and with --yes) to apply the changes."
else
    ok  "Backups:      ${BACKUP_DIR}"
    ok  "Revert with:  sudo ${BACKUP_DIR}/restore.sh"
    ok  "Log:          ${LOG_FILE}"
    printf '\n'
    warn "Reboot the system so that all the changes take effect."
fi
info "Issues / feedback: ${REPO_URL}/issues"
printf '\n'
