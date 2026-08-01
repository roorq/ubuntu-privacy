#!/usr/bin/env bash
#
# ubuntu-privacy.sh — wylaczenie telemetrii i "phone home" w Ubuntu (24.04 / 25.10 / 26.04)
#
#   curl -fsSL <URL>/ubuntu-privacy.sh | sudo bash -s -- --dry-run
#   curl -fsSL <URL>/ubuntu-privacy.sh | sudo bash -s -- --yes
#
# Kazdy modyfikowany plik jest kopiowany do /var/backups/ubuntu-privacy-<data>/,
# gdzie powstaje takze restore.sh cofajacy wszystkie zmiany.
#
set -euo pipefail

VERSION="1.0.0"
DRY_RUN=0
ASSUME_YES=0
DO_PURGE=0
DO_HOSTS=0
DO_FIREFOX=1
DO_CONNCHECK=1

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/ubuntu-privacy-${STAMP}"
LOG_FILE="/var/log/ubuntu-privacy.log"
[ "$(id -u)" -eq 0 ] || LOG_FILE="/dev/null"   # bez roota nie probujemy pisac do /var/log

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
skip() { printf '%s\n' "${C_D} -  $* (pomijam)${C_0}"; log "[skip] $*"; }
hdr()  { printf '\n%s\n' "${C_B}=== $* ===${C_0}"; log "=== $* ==="; }

usage() {
    cat <<EOF
ubuntu-privacy.sh v${VERSION}

Uzycie:  sudo ./ubuntu-privacy.sh [opcje]
   albo: curl -fsSL <URL> | sudo bash -s -- [opcje]

Opcje:
  -y, --yes           bez pytania o potwierdzenie (wymagane przy curl|bash)
  -n, --dry-run       pokaz co zostanie zrobione, nie zmieniaj niczego
      --purge         dodatkowo USUN pakiety (apport, whoopsie, popularity-contest...)
                      uwaga: moze usunac metapakiet ubuntu-desktop (sam system dziala dalej)
      --hosts         zablokuj domeny telemetrii w /etc/hosts
      --no-firefox    nie ustawiaj polityk Firefoksa
      --keep-conncheck  zostaw sprawdzanie polaczenia NetworkManagera
                        (connectivity-check.ubuntu.com — potrzebne do captive portali)
  -h, --help          ta pomoc

Co robi domyslnie:
  * wylacza i maskuje: whoopsie, apport, kerneloops, motd-news, apt-news, esm-cache
  * wylacza ubuntu-report i popularity-contest
  * wylacza raportowanie bledow i statystyk w GNOME (dconf + per-user gsettings)
  * wylacza geolokalizacje GNOME
  * neutralizuje reklamy Ubuntu Pro/ESM w APT i w MOTD
  * czysci zebrane raporty z /var/crash i ~/.cache/ubuntu-report
  * ustawia polityki prywatnosci Firefoksa (o ile nie masz wlasnych)
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
        *) err "Nieznana opcja: $1"; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- sanity
if [ "$(id -u)" -ne 0 ]; then
    err "Uruchom jako root:  curl -fsSL <URL> | sudo bash -s -- --yes"
    exit 1
fi

OS_NAME="nieznany"; OS_VER=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${NAME:-nieznany}"; OS_VER="${VERSION_ID:-}"
fi

case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*) : ;;
    *) warn "System to '${OS_NAME}' — skrypt jest pisany pod Ubuntu, czesc krokow moze nie miec zastosowania." ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
    err "Brak apt-get — to nie jest system oparty na Debianie. Przerywam."
    exit 1
fi

hdr "ubuntu-privacy.sh v${VERSION}"
info "System: ${OS_NAME} ${OS_VER}"
info "Backup: ${BACKUP_DIR}"
[ "$DRY_RUN" -eq 1 ] && warn "TRYB PROBNY — zadne zmiany nie zostana zapisane"
[ "$DO_PURGE" -eq 1 ] && warn "--purge: pakiety zostana usuniete, nie tylko wylaczone"

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        printf '\n%s' "Kontynuowac? [t/N] "
        read -r reply </dev/tty || reply=""
        case "$reply" in
            t|T|y|Y|tak|TAK|yes) : ;;
            *) info "Anulowano."; exit 0 ;;
        esac
    else
        err "Brak terminala do potwierdzenia. Dodaj --yes (lub --dry-run) przy curl|bash."
        exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- prymitywy
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

# write_file <sciezka> <<'EOF' ... EOF
write_file() {
    local f="$1" content
    content="$(cat)"
    backup_file "$f"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   zapis: $f${C_0}"
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
    if ! unit_exists "$u"; then skip "jednostka $u nie istnieje"; return 0; fi
    run systemctl disable --now -- "$u" || true
    run systemctl mask -- "$u" || true
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$u" >>"${BACKUP_DIR}/manifest.units"
    ok "wylaczona i zamaskowana: $u"
}

pkg_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$'; }

purge_pkg() {
    local p="$1"
    if ! pkg_installed "$p"; then skip "pakiet $p nie jest zainstalowany"; return 0; fi
    run apt-get purge -y -- "$p" || { warn "nie udalo sie usunac $p"; return 0; }
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$p" >>"${BACKUP_DIR}/manifest.pkgs"
    ok "usuniety pakiet: $p"
}

# gsettings dla wszystkich zalogowanych uzytkownikow
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
    log "start $(date -Is) — ${OS_NAME} ${OS_VER} — opcje: purge=$DO_PURGE hosts=$DO_HOSTS firefox=$DO_FIREFOX"
fi

# ================================================================= 1. uslugi
hdr "1/8  Uslugi telemetryczne i raportowania"

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
hdr "2/8  Apport (zbieranie i wysylanie zrzutow bledow)"

write_file /etc/default/apport <<'EOF'
# ustawione przez ubuntu-privacy.sh
# 0 = apport nie zbiera ani nie wysyla raportow o awariach
enabled=0
EOF
ok "/etc/default/apport: enabled=0"

write_file /etc/apport/autoreport <<'EOF'
# ustawione przez ubuntu-privacy.sh — brak automatycznego wysylania
EOF

# zadne nowe zrzuty nie trafia do apporta
write_file /etc/sysctl.d/60-ubuntu-privacy-nocoredump.conf <<'EOF'
# ustawione przez ubuntu-privacy.sh
kernel.core_pattern=|/bin/false
EOF
run sysctl -p /etc/sysctl.d/60-ubuntu-privacy-nocoredump.conf || true
ok "core_pattern przekierowany poza apporta"

if [ -d /var/crash ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   \$ rm -f /var/crash/*${C_0}"
    else
        find /var/crash -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    fi
    ok "wyczyszczone /var/crash"
fi

# ================================================================= 3. whoopsie
hdr "3/8  Whoopsie (wysylka raportow do errors.ubuntu.com)"

write_file /etc/whoopsie <<'EOF'
# ustawione przez ubuntu-privacy.sh
[General]
report_crashes=false
EOF
ok "/etc/whoopsie: report_crashes=false"

# ================================================================= 4. popcon + ubuntu-report
hdr "4/8  popularity-contest i ubuntu-report"

if [ -f /etc/popularity-contest.conf ]; then
    backup_file /etc/popularity-contest.conf
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   sed: PARTICIPATE=no w /etc/popularity-contest.conf${C_0}"
    else
        if grep -q '^ *PARTICIPATE=' /etc/popularity-contest.conf; then
            sed -i 's/^ *PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf
        else
            printf 'PARTICIPATE="no"\n' >>/etc/popularity-contest.conf
        fi
    fi
    ok "popularity-contest: PARTICIPATE=no"
else
    skip "brak /etc/popularity-contest.conf"
fi

# ubuntu-report: pending report cache uzytkownikow
for home in /home/* /root; do
    [ -d "$home/.cache/ubuntu-report" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   \$ rm -rf $home/.cache/ubuntu-report${C_0}"
    else
        rm -rf "$home/.cache/ubuntu-report"
    fi
    ok "usuniety cache ubuntu-report: $home"
done

# ================================================================= 5. reklamy Pro/ESM + MOTD
hdr "5/8  Ubuntu Pro / ESM / MOTD-news"

write_file /etc/default/motd-news <<'EOF'
# ustawione przez ubuntu-privacy.sh
# 0 = brak pobierania "wiadomosci" z motd.ubuntu.com przy logowaniu
ENABLED=0
URLS=""
WAIT=1
EOF
ok "motd-news wylaczone"

for f in /etc/update-motd.d/10-help-text \
         /etc/update-motd.d/50-motd-news \
         /etc/update-motd.d/88-esm-announce \
         /etc/update-motd.d/91-contract-ua-esm-status \
         /etc/update-motd.d/91-release-upgrade
do
    [ -e "$f" ] || continue
    backup_file "$f"
    run chmod -x "$f" || true
    ok "wylaczony fragment MOTD: $(basename "$f")"
done

# hook APT wstrzykujacy reklamy ESM do kazdego apt update/upgrade
if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
    write_file /etc/apt/apt.conf.d/20apt-esm-hook.conf <<'EOF'
// wyzerowane przez ubuntu-privacy.sh — oryginal w /var/backups/ubuntu-privacy-*/
EOF
    ok "hook APT z reklamami ESM wyzerowany"
else
    skip "brak 20apt-esm-hook.conf"
fi

if command -v pro >/dev/null 2>&1; then
    run pro config set apt_news=false || true
    ok "pro: apt_news=false"
fi

# ================================================================= 6. GNOME / dconf
hdr "6/8  GNOME: raportowanie problemow, statystyki, geolokalizacja"

if [ -d /etc/dconf ] || command -v dconf >/dev/null 2>&1; then
    if [ ! -f /etc/dconf/profile/user ]; then
        write_file /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
        ok "utworzony profil dconf /etc/dconf/profile/user"
    elif ! grep -q '^system-db:local' /etc/dconf/profile/user; then
        backup_file /etc/dconf/profile/user
        [ "$DRY_RUN" -eq 1 ] || printf 'system-db:local\n' >>/etc/dconf/profile/user
        ok "dodane system-db:local do profilu dconf"
    fi

    write_file /etc/dconf/db/local.d/00-ubuntu-privacy <<'EOF'
# ustawione przez ubuntu-privacy.sh
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
    ok "systemowe domyslne dconf zapisane"
else
    skip "dconf niedostepny (system bez GNOME)"
fi

gset_all_users org.gnome.desktop.privacy report-technical-problems false
gset_all_users org.gnome.desktop.privacy send-software-usage-stats false
gset_all_users org.gnome.desktop.privacy remember-recent-files false
gset_all_users org.gnome.desktop.privacy remember-app-usage false
gset_all_users org.gnome.system.location enabled false
ok "ustawienia zastosowane dla zalogowanych uzytkownikow"

# ================================================================= 7. siec
hdr "7/8  Zapytania sieciowe w tle"

if [ "$DO_CONNCHECK" -eq 1 ]; then
    if [ -d /etc/NetworkManager ]; then
        write_file /etc/NetworkManager/conf.d/99-ubuntu-privacy.conf <<'EOF'
# ustawione przez ubuntu-privacy.sh
# blokuje cykliczne odpytywanie connectivity-check.ubuntu.com
[connectivity]
enabled=false
uri=
interval=0
EOF
        run systemctl reload NetworkManager || run systemctl restart NetworkManager || true
        ok "wylaczone sprawdzanie polaczenia NetworkManagera"
        warn "efekt uboczny: brak automatycznego wykrywania captive portali (hotele, lotniska)"
    else
        skip "brak NetworkManagera"
    fi
else
    skip "sprawdzanie polaczenia zostawione (--keep-conncheck)"
fi

if [ "$DO_HOSTS" -eq 1 ]; then
    backup_file /etc/hosts
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${C_D}   dopisanie blokad do /etc/hosts${C_0}"
    else
        if ! grep -q 'ubuntu-privacy.sh BEGIN' /etc/hosts; then
            cat >>/etc/hosts <<'EOF'

# ubuntu-privacy.sh BEGIN — blokada domen telemetrii
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
    ok "domeny telemetrii zablokowane w /etc/hosts"
    warn "blokada contracts.canonical.com wylacza tez dzialanie Ubuntu Pro, jesli go uzywasz"
else
    skip "blokada w /etc/hosts (wlacz opcja --hosts)"
fi

if [ "$DO_FIREFOX" -eq 1 ]; then
    if [ -e /etc/firefox/policies/policies.json ]; then
        skip "masz juz /etc/firefox/policies/policies.json — nie nadpisuje"
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
        ok "polityki prywatnosci Firefoksa zapisane"
    fi
else
    skip "polityki Firefoksa (--no-firefox)"
fi

# ================================================================= 8. pakiety
hdr "8/8  Pakiety"

if [ "$DO_PURGE" -eq 1 ]; then
    for p in ubuntu-report popularity-contest apport apport-symptoms apport-gtk \
             whoopsie whoopsie-preferences kerneloops
    do
        purge_pkg "$p"
    done
    run apt-get autoremove -y || true
else
    info "pakiety pozostaja zainstalowane, ale sa wylaczone (uzyj --purge aby usunac)"
fi

# ================================================================= restore.sh
if [ "$DRY_RUN" -ne 1 ]; then
    cat >"${BACKUP_DIR}/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
# Cofa zmiany wprowadzone przez ubuntu-privacy.sh. Uruchom jako root.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Uruchom jako root"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. pliki utworzone przez skrypt — usuwamy
if [ -f "$DIR/manifest.created" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f" && echo "usunieto $f"
    done <"$DIR/manifest.created"
fi

# 2. pliki zmodyfikowane — przywracamy z kopii
if [ -f "$DIR/manifest.files" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        src="$DIR/files$f"
        [ -e "$src" ] || continue
        mkdir -p "$(dirname "$f")"
        cp -a "$src" "$f" && echo "przywrocono $f"
    done <"$DIR/manifest.files"
fi

# 3. jednostki systemd — odmaskowanie i wlaczenie
if [ -f "$DIR/manifest.units" ]; then
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        systemctl unmask "$u" 2>/dev/null || true
        systemctl enable --now "$u" 2>/dev/null || true
        echo "wlaczono $u"
    done <"$DIR/manifest.units"
fi

# 4. pakiety usuniete przez --purge
if [ -f "$DIR/manifest.pkgs" ]; then
    mapfile -t pkgs <"$DIR/manifest.pkgs"
    if [ "${#pkgs[@]}" -gt 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    fi
fi

# 5. wpisy w /etc/hosts
if grep -q 'ubuntu-privacy.sh BEGIN' /etc/hosts 2>/dev/null; then
    sed -i '/ubuntu-privacy.sh BEGIN/,/ubuntu-privacy.sh END/d' /etc/hosts
    echo "usunieto blokady z /etc/hosts"
fi

command -v dconf >/dev/null && dconf update || true
sysctl -p /etc/sysctl.d/*.conf >/dev/null 2>&1 || true
systemctl daemon-reload || true
echo
echo "Przywracanie zakonczone. Zalecany restart."
RESTORE
    chmod 700 "${BACKUP_DIR}/restore.sh"
fi

# ================================================================= podsumowanie
hdr "Gotowe"

if [ "$DRY_RUN" -eq 1 ]; then
    info "To byl tryb probny — nic nie zostalo zmienione."
    info "Uruchom ponownie bez --dry-run (i z --yes), aby zastosowac zmiany."
else
    ok  "Kopie zapasowe:   ${BACKUP_DIR}"
    ok  "Cofniecie zmian:  sudo ${BACKUP_DIR}/restore.sh"
    ok  "Log:              ${LOG_FILE}"
    printf '\n'
    warn "Zrestartuj system, zeby wszystkie zmiany weszly w zycie."
fi
printf '\n'
