#!/usr/bin/env bash
#
# ubuntu-privacy.sh - disable telemetry and "phone home" behaviour in Ubuntu (24.04 / 25.10 / 26.04 / 26.10)
#
#   https://github.com/roorq/ubuntu-privacy
#
#   curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes
#
# Every modified file is copied to /var/backups/ubuntu-privacy-<date>/, which also
# receives a restore.sh that reverts the changes.
#
# Everything below is wrapped in functions and only main "$@" (the very last line)
# executes anything - a download cut short by curl|bash therefore runs nothing.
#
set -euo pipefail

SCRIPT_VERSION="1.1.0"
REPO_URL="https://github.com/roorq/ubuntu-privacy"
RAW_URL="https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh"
DIVERT_SUFFIX=".dpkg-divert"   # apt silently ignores apt.conf.d files matching \.dpkg-[a-z]+$

DRY_RUN=0
ASSUME_YES=0
DO_PURGE=1
DO_CONNCHECK=1
PRO_ATTACHED=0

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/ubuntu-privacy-${STAMP}"
LOG_FILE="/var/log/ubuntu-privacy.log"
OS_NAME="unknown"; OS_VER=""; OS_IDS=""

PURGE_CANDIDATES=(ubuntu-report popularity-contest apport apport-symptoms apport-gtk
                  whoopsie whoopsie-preferences kerneloops)
# Units that Ubuntu Pro needs - left alone when the machine is attached to Pro
PRO_UNITS=" ubuntu-advantage.service ua-timer.timer ua-timer.service ua-reboot-cmds.service esm-cache.service "

# ---------------------------------------------------------------- ui helpers
if [ -t 1 ]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

log()  { [ "$DRY_RUN" -eq 1 ] && return 0; printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s\n' "${C_B}::${C_0} $*"; log "[info] $*"; }
ok()   { printf '%s\n' "${C_G} +${C_0} $*"; log "[ok]   $*"; }
warn() { printf '%s\n' "${C_Y} !${C_0} $*"; log "[warn] $*"; }
err()  { printf '%s\n' "${C_R} x${C_0} $*" >&2; log "[err]  $*"; }
skip() { printf '%s\n' "${C_D} -  $* (skipping)${C_0}"; log "[skip] $*"; }
hdr()  { printf '\n%s\n' "${C_B}=== $* ===${C_0}"; log "=== $* ==="; }
dry()  { printf '%s\n' "${C_D}   $*${C_0}"; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
ubuntu-privacy.sh v${SCRIPT_VERSION}
${REPO_URL}

Usage:  sudo ./ubuntu-privacy.sh [options]
    or: curl -fsSL ${RAW_URL} | sudo bash -s -- [options]

Options:
  -y, --yes           do not ask for confirmation (required with curl|bash)
  -n, --dry-run       show what would be done, change nothing
      --keep-packages do not remove the telemetry packages, only disable them
      --keep-conncheck  leave NetworkManager's connectivity checking in place
                        (connectivity-check.ubuntu.com - needed for captive portals)
  -h, --help          this help

What it does by default:
  * disables and masks: whoopsie, apport, kerneloops, motd-news, apt-news, popularity-contest
    (+ the Ubuntu Pro units ua-timer/esm-cache - only when the machine is NOT attached to Pro)
  * disables ubuntu-report and popularity-contest
  * disables error reporting and usage statistics in GNOME (dconf + per-user gsettings)
  * GNOME: stops recording recent files and app usage, disables geolocation
  * neutralises the Ubuntu Pro/ESM ads in APT and in the MOTD
  * clears the reports collected in /var/crash and ~/.cache/ubuntu-report
  * removes the telemetry packages: ${PURGE_CANDIDATES[*]}
    (a package whose removal would take anything else with it, e.g. ubuntu-desktop, is kept)
Package-owned config files are replaced via dpkg-divert, so package updates
(including unattended-upgrades) are never blocked by conffile prompts.
EOF
}

# ---------------------------------------------------------------- primitives
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        dry "\$ $*"
        return 0
    fi
    log "\$ $*"
    # </dev/null: with curl|bash the script itself is on stdin - nothing may eat it
    "$@" </dev/null >>"$LOG_FILE" 2>&1
}

manifest() { [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$2" >>"${BACKUP_DIR}/manifest.$1"; }

backup_file() {
    local f="$1" dest
    [ -e "$f" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && { dry "backup: $f"; return 0; }
    dest="${BACKUP_DIR}/files$(dirname "$f")"
    mkdir -p "$dest" || die "cannot create $dest - aborting before anything is overwritten"
    cp -a "$f" "$dest/" || die "backup of $f failed - aborting before anything is overwritten"
    manifest files "$f"
}

# is <path> a conffile of an installed package?
is_conffile() {
    local f="$1" pkg
    pkg="$(dpkg-query -S -- "$f" 2>/dev/null | grep -v '^diversion ' | head -n1 | sed 's/: .*//; s/:.*//')" || true
    [ -n "$pkg" ] || return 1
    dpkg-query -W -f='${Conffiles}\n' -- "$pkg" 2>/dev/null \
        | awk -v f="$f" '$1 == f { found = 1 } END { exit !found }'
}

is_diverted() { [ -n "$(dpkg-divert --listpackage "$1" 2>/dev/null)" ]; }

# write_file <path> <<'EOF' ... EOF
#   - conffile of a package -> dpkg-divert (original moved to <path>.dpkg-divert), then write
#   - other existing file   -> backup, then overwrite
#   - new file              -> recorded as created
write_file() {
    local f="$1" content
    content="$(cat)"
    if [ -e "$f" ] && ! is_diverted "$f" && is_conffile "$f"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            dry "divert + write: $f (original -> $f$DIVERT_SUFFIX)"
            return 0
        fi
        run dpkg-divert --local --rename --divert "$f$DIVERT_SUFFIX" --add "$f" \
            || die "dpkg-divert of $f failed"
        manifest diverted "$f"
    elif [ -e "$f" ]; then
        backup_file "$f"
    else
        [ "$DRY_RUN" -eq 1 ] || manifest created "$f"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        dry "write: $f"
        return 0
    fi
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$content" >"$f"
    chmod 644 "$f"
}

# remove_file <path> - backup, then delete (restore.sh copies it back)
remove_file() {
    local f="$1"
    [ -e "$f" ] || return 1
    backup_file "$f"
    if [ "$DRY_RUN" -eq 1 ]; then dry "\$ rm -f $f"; else rm -f -- "$f"; fi
}

unit_exists() { systemctl cat -- "$1" >/dev/null 2>&1; }

disable_unit() {
    local u="$1" state
    if ! unit_exists "$u"; then skip "unit $u does not exist"; return 0; fi
    if [ "$PRO_ATTACHED" -eq 1 ] && [[ "$PRO_UNITS" == *" $u "* ]]; then
        skip "$u - this machine is attached to Ubuntu Pro"
        return 0
    fi
    state="$(systemctl is-enabled -- "$u" 2>/dev/null || true)"
    case "$state" in
        masked|masked-runtime) skip "$u is already masked"; return 0 ;;
    esac
    run systemctl disable --now -- "$u" || true
    run systemctl mask -- "$u" || true
    # remember the previous state, restore.sh re-enables only what was enabled
    manifest units "$u"$'\t'"${state:-unknown}"
    ok "disabled and masked: $u ${C_D}(was: ${state:-unknown})${C_0}"
}

pkg_installed() { dpkg-query -W -f='${db:Status-Status}' -- "$1" 2>/dev/null | grep -q '^installed$'; }

# logged-in desktop users: prints "<user> <uid> <bus path>"
desktop_users() {
    local d uid u
    for d in /run/user/*; do
        [ -S "$d/bus" ] || continue
        uid="$(basename "$d")"
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        u="$(id -nu "$uid" 2>/dev/null)" || continue
        printf '%s %s %s\n' "$u" "$uid" "$d/bus"
    done
}

as_user() {   # as_user <user> <uid> <bus> <cmd...>
    local u="$1" uid="$2" bus="$3"; shift 3
    runuser -u "$u" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
        XDG_RUNTIME_DIR="/run/user/${uid}" "$@" </dev/null
}

# gsettings for every logged-in user; the previous value is recorded for restore.sh
gset_all_users() {
    local schema="$1" key="$2" val="$3" u uid bus old
    while read -r u uid bus; do
        if [ "$DRY_RUN" -eq 1 ]; then
            dry "[$u] gsettings set $schema $key $val"
            continue
        fi
        old="$(as_user "$u" "$uid" "$bus" gsettings get "$schema" "$key" 2>/dev/null)" || continue
        [ -n "$old" ] || continue
        [ "$old" = "$val" ] && continue
        if as_user "$u" "$uid" "$bus" gsettings set "$schema" "$key" "$val" >>"$LOG_FILE" 2>&1; then
            manifest gsettings "$u"$'\t'"$schema"$'\t'"$key"$'\t'"$old"
        fi
    done < <(desktop_users)
}

# ================================================================= setup
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)          ASSUME_YES=1 ;;
            -n|--dry-run)      DRY_RUN=1 ;;
            --keep-packages)   DO_PURGE=0 ;;
            --purge)           DO_PURGE=1 ;;   # default since 1.1.0, kept for old command lines
            --keep-conncheck)  DO_CONNCHECK=0 ;;
            -h|--help)         usage; exit 0 ;;
            *) DRY_RUN=1; err "Unknown option: $1"; usage; exit 2 ;;
        esac
        shift
    done
}

sanity() {
    [ "$(id -u)" -eq 0 ] || { DRY_RUN=1; die "Run as root:  curl -fsSL ${RAW_URL} | sudo bash -s -- --yes"; }

    if [ -r /etc/os-release ]; then
        # subshell: os-release defines VERSION, NAME, ID... - do not let them leak in
        # shellcheck disable=SC1091
        OS_NAME="$(. /etc/os-release && printf '%s' "${NAME:-unknown}")"
        # shellcheck disable=SC1091
        OS_VER="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
        # shellcheck disable=SC1091
        OS_IDS="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    fi
    case "$OS_IDS" in
        *ubuntu*|*debian*) : ;;
        *) warn "This system is '${OS_NAME}' - the script targets Ubuntu, some steps may not apply." ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die "No apt-get - this is not a Debian-based system. Aborting."
    command -v runuser >/dev/null 2>&1 || die "runuser (util-linux) not found. Aborting."

    if command -v pro >/dev/null 2>&1; then
        local st
        st="$(pro status --format json 2>/dev/null </dev/null || true)"
        if [[ "$st" =~ \"attached\":\ *true ]]; then PRO_ATTACHED=1; fi
    fi
}

confirm() {
    hdr "ubuntu-privacy.sh v${SCRIPT_VERSION}"
    info "System: ${OS_NAME} ${OS_VER}"
    info "Backup: ${BACKUP_DIR}"
    [ "$DRY_RUN" -eq 1 ] && warn "DRY RUN - no changes will be written"
    [ "$DO_PURGE" -eq 1 ] || info "--keep-packages: packages are only disabled, not removed"
    [ "$PRO_ATTACHED" -eq 1 ] && info "Ubuntu Pro is attached - Pro/ESM units are left alone"

    local prev
    prev="$(ls -d /var/backups/ubuntu-privacy-* 2>/dev/null | head -n1 || true)"
    if [ -n "$prev" ]; then
        warn "a previous run exists ($prev). To fully revert later, run the restore.sh"
        warn "scripts newest-first, or only the OLDEST one - see README."
    fi

    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        if [ -e /dev/tty ] && [ -r /dev/tty ]; then
            printf '\n%s' "Continue? [y/N] "
            local reply
            read -r reply </dev/tty || reply=""
            case "$reply" in
                y|Y|yes|YES) : ;;
                *) info "Cancelled."; exit 0 ;;
            esac
        else
            die "No terminal to confirm on. Add --yes (or --dry-run) when using curl|bash."
        fi
    fi

    if [ "$DRY_RUN" -ne 1 ]; then
        mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 600 "$LOG_FILE" 2>/dev/null || true
        log ""
        log "start $(date -Is) v${SCRIPT_VERSION} - ${OS_NAME} ${OS_VER} - options: purge=$DO_PURGE conncheck=$DO_CONNCHECK pro=$PRO_ATTACHED"
    fi
}

# ================================================================= 1. units
step_units() {
    hdr "1/8  Telemetry and reporting units"
    local u
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
}

# ================================================================= 2. apport
step_apport() {
    hdr "2/8  Apport (collecting and uploading crash dumps)"

    if [ -e /etc/default/apport ]; then
        write_file /etc/default/apport <<'EOF'
# set by ubuntu-privacy.sh (the package's original: /etc/default/apport.dpkg-divert)
# 0 = apport neither collects nor uploads crash reports
enabled=0
EOF
        ok "/etc/default/apport: enabled=0"
    else
        skip "no /etc/default/apport"
    fi

    # the mere EXISTENCE of this file turns automatic crash uploading on
    if remove_file /etc/apport/autoreport; then
        ok "/etc/apport/autoreport removed (automatic crash uploading was switched on)"
    fi

    # Hand core dumps back to the system default instead of apport: systemd-coredump
    # if installed, otherwise the kernel's plain "core" (written only if ulimit -c > 0).
    local core="core" cur
    if [ -r /usr/lib/sysctl.d/50-coredump.conf ]; then
        core="$(sed -n 's/^[[:space:]]*kernel\.core_pattern[[:space:]]*=[[:space:]]*//p' \
                /usr/lib/sysctl.d/50-coredump.conf | tail -n1)"
        [ -n "$core" ] || core="core"
    fi
    write_file /etc/sysctl.d/60-ubuntu-privacy-coredump.conf <<EOF
# set by ubuntu-privacy.sh - core dumps go to the system default, not to apport
kernel.core_pattern=${core}
EOF
    cur="$(cat /proc/sys/kernel/core_pattern 2>/dev/null || true)"
    if [[ "$cur" == *apport* ]]; then
        run sysctl -p /etc/sysctl.d/60-ubuntu-privacy-coredump.conf || true
    fi
    ok "core_pattern: ${core}"

    if [ -d /var/crash ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            dry "\$ rm -f /var/crash/*"
        else
            find /var/crash -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
        fi
        ok "/var/crash cleared"
    fi
}

# ================================================================= 3. whoopsie
step_whoopsie() {
    hdr "3/8  Whoopsie (uploads reports to errors.ubuntu.com)"
    write_file /etc/whoopsie <<'EOF'
# set by ubuntu-privacy.sh
[General]
report_crashes=false
EOF
    ok "/etc/whoopsie: report_crashes=false"
}

# ================================================================= 4. popcon + ubuntu-report
step_popcon() {
    hdr "4/8  popularity-contest and ubuntu-report"

    if [ -f /etc/popularity-contest.conf ]; then
        backup_file /etc/popularity-contest.conf
        if [ "$DRY_RUN" -eq 1 ]; then
            dry "sed: PARTICIPATE=no in /etc/popularity-contest.conf"
        elif grep -q '^ *PARTICIPATE=' /etc/popularity-contest.conf; then
            sed -i 's/^ *PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf
        else
            printf 'PARTICIPATE="no"\n' >>/etc/popularity-contest.conf
        fi
        ok "popularity-contest: PARTICIPATE=no"
    else
        skip "no /etc/popularity-contest.conf"
    fi

    local home
    for home in /home/* /root; do
        [ -d "$home/.cache/ubuntu-report" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            dry "\$ rm -rf $home/.cache/ubuntu-report"
        else
            rm -rf -- "$home/.cache/ubuntu-report"
        fi
        ok "ubuntu-report cache removed: $home"
    done
}

# ================================================================= 5. Pro/ESM ads + MOTD
step_motd() {
    hdr "5/8  Ubuntu Pro / ESM / MOTD-news"

    write_file /etc/default/motd-news <<'EOF'
# set by ubuntu-privacy.sh
# 0 = no fetching of "news" from motd.ubuntu.com at login
ENABLED=0
URLS=""
WAIT=1
EOF
    ok "motd-news disabled"

    local f
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
// blanked out by ubuntu-privacy.sh - the original is 20apt-esm-hook.conf.dpkg-divert
EOF
        ok "APT ESM-ad hook blanked out"
    else
        skip "no 20apt-esm-hook.conf"
    fi

    if command -v pro >/dev/null 2>&1; then
        local cur
        cur="$(pro config show apt_news 2>/dev/null </dev/null | awk '{print $NF}' || true)"
        if [ "$cur" != "False" ] && [ "$cur" != "false" ]; then
            run pro config set apt_news=false || true
            manifest pro "apt_news"
        fi
        ok "pro: apt_news=false"
    fi
}

# ================================================================= 6. GNOME / dconf
step_gnome() {
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
}

# ================================================================= 7. network
step_network() {
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
            # reload only - a restart could drop the network (and an SSH session)
            run systemctl reload NetworkManager || warn "NetworkManager reload failed - takes effect after reboot"
            ok "NetworkManager connectivity checking disabled"
            warn "side effect: no automatic captive portal detection (hotels, airports)"
        else
            skip "no NetworkManager"
        fi
    else
        skip "connectivity checking left in place (--keep-conncheck)"
    fi
}

# ================================================================= 8. packages
step_packages() {
    hdr "8/8  Telemetry packages"

    if [ "$DO_PURGE" -ne 1 ]; then
        info "the packages stay installed but are disabled (--keep-packages)"
        return 0
    fi

    local p q sim extra changed installed=() safe=()
    local -A removes=()
    for p in "${PURGE_CANDIDATES[@]}"; do
        if pkg_installed "$p"; then installed+=("$p"); else skip "package $p is not installed"; fi
    done
    [ "${#installed[@]}" -gt 0 ] || return 0

    # Simulate each removal and remember everything apt would take with it.
    for p in "${installed[@]}"; do
        if sim="$(apt-get -s purge -- "$p" 2>/dev/null </dev/null)"; then
            removes[$p]="$(printf '%s\n' "$sim" | awk '$1=="Purg"||$1=="Remv"{print $2}' | sed 's/:.*//' | tr '\n' ' ')"
            safe+=("$p")
        else
            warn "apt-get simulation for $p failed - kept (disabled)"
        fi
    done

    # A package is removed only if everything its removal drags along is itself in
    # the safe set. Anything else (ubuntu-desktop and friends) keeps it installed -
    # restore.sh could not bring those back reliably. Repeat until stable, so that
    # e.g. apport is kept when it would drag along a kept apport-gtk.
    # apt-get autoremove is never run.
    changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        local next=()
        for p in "${safe[@]}"; do
            extra=""
            for q in ${removes[$p]}; do
                [[ " ${safe[*]} " == *" $q "* ]] || extra+=" $q"
            done
            if [ -n "$extra" ]; then
                warn "$p kept (disabled) - removing it would also remove:$extra"
                changed=1
            else
                next+=("$p")
            fi
        done
        safe=("${next[@]}")
    done
    [ "${#safe[@]}" -gt 0 ] || return 0

    if run apt-get purge -y -- "${safe[@]}"; then
        for p in "${safe[@]}"; do
            manifest pkgs "$p"
            ok "package removed: $p"
        done
        info "leftover dependencies can be reviewed with: apt-get autoremove --dry-run"
    else
        warn "apt-get purge failed - see ${LOG_FILE}"
    fi
}

# ================================================================= restore.sh
write_restore() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    cat >"${BACKUP_DIR}/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
# Reverts the changes made by ubuntu-privacy.sh. Run as root.
# Best effort: a failing step is reported and the rest still runs.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
fail() { echo "WARNING: $*" >&2; FAILED=1; }

# 1. files created by the script - remove them
if [ -f "$DIR/manifest.created" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f -- "$f" && echo "removed $f"
    done <"$DIR/manifest.created"
fi

# 2. diverted package conffiles - drop ours, move the package's original back
if [ -f "$DIR/manifest.diverted" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f -- "$f"
        if dpkg-divert --local --rename --divert "$f.dpkg-divert" --remove "$f" >/dev/null; then
            echo "undiverted $f"
        else
            fail "could not remove the diversion of $f"
        fi
    done <"$DIR/manifest.diverted"
fi

# 3. modified / removed files - restore them from the backup
if [ -f "$DIR/manifest.files" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        src="$DIR/files$f"
        [ -e "$src" ] || continue
        mkdir -p "$(dirname "$f")"
        cp -a "$src" "$f" && echo "restored $f" || fail "could not restore $f"
    done <"$DIR/manifest.files"
fi

# 4. systemd units - unmask; re-enable only those that were enabled before
if [ -f "$DIR/manifest.units" ]; then
    while IFS=$'\t' read -r u state; do
        [ -n "$u" ] || continue
        systemctl unmask -- "$u" >/dev/null 2>&1 || true
        case "$state" in
            enabled|enabled-runtime)
                systemctl enable --now -- "$u" >/dev/null 2>&1 || fail "could not enable $u"
                echo "enabled $u" ;;
            *)  echo "unmasked $u (was: ${state:-unknown})" ;;
        esac
    done <"$DIR/manifest.units"
fi

# 5. removed telemetry packages
if [ -f "$DIR/manifest.pkgs" ]; then
    mapfile -t pkgs <"$DIR/manifest.pkgs"
    if [ "${#pkgs[@]}" -gt 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update || fail "apt-get update failed"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${pkgs[@]}" \
            || fail "reinstalling ${pkgs[*]} failed"
    fi
fi

# 6. per-user GNOME settings
if [ -f "$DIR/manifest.gsettings" ]; then
    while IFS=$'\t' read -r user schema key val; do
        [ -n "$user" ] || continue
        uid="$(id -u "$user" 2>/dev/null)" || continue
        bus="/run/user/$uid/bus"
        if [ -S "$bus" ]; then
            runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
                XDG_RUNTIME_DIR="/run/user/$uid" gsettings set "$schema" "$key" "$val" </dev/null
        elif command -v dbus-run-session >/dev/null; then
            runuser -u "$user" -- dbus-run-session -- gsettings set "$schema" "$key" "$val" </dev/null
        else
            false
        fi && echo "[$user] $schema $key = $val" \
           || fail "[$user] could not reset $schema $key - run as that user: gsettings set $schema $key $val"
    done <"$DIR/manifest.gsettings"
fi

# 7. Ubuntu Pro config
if [ -f "$DIR/manifest.pro" ] && command -v pro >/dev/null; then
    pro config set apt_news=true >/dev/null && echo "pro: apt_news=true" || fail "pro config set apt_news=true failed"
fi

command -v dconf >/dev/null && dconf update || true
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reload || true
systemctl reload NetworkManager >/dev/null 2>&1 || true
echo
if [ "$FAILED" -eq 0 ]; then
    echo "Restore complete. A reboot is recommended."
else
    echo "Restore finished WITH WARNINGS (see above). A reboot is recommended."
    exit 1
fi
RESTORE
    chmod 700 "${BACKUP_DIR}/restore.sh"
}

# ================================================================= summary
summary() {
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
}

main() {
    parse_args "$@"
    sanity
    confirm
    export DEBIAN_FRONTEND=noninteractive
    step_units
    step_apport
    step_whoopsie
    step_popcon
    step_motd
    step_gnome
    step_network
    step_packages
    write_restore
    summary
}

main "$@"
