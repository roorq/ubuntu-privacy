# ubuntu-privacy.sh

Skrypt wyłączający telemetrię, raportowanie awarii i „phone home" w Ubuntu.
Testowany pod kątem **Ubuntu 24.04 / 25.10 / 26.04 LTS** (działa też na pochodnych Debiana — kroki, które nie mają zastosowania, są po prostu pomijane).

Każda zmiana jest kopiowana do katalogu backupu, a skrypt generuje `restore.sh`, który cofa **wszystko**.

---

## Szybki start

```bash
# 1. Podgląd — pokazuje co zrobi, nie zmienia niczego
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --dry-run

# 2. Właściwe uruchomienie
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes

# 3. Wariant maksymalny — usuwa pakiety i blokuje domeny w /etc/hosts
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes --purge --hosts
```

> `--yes` jest **wymagane** przy `curl | bash`. Bez terminala skrypt nie ma jak zapytać o potwierdzenie i celowo przerywa działanie.

Po wykonaniu: **zrestartuj system**.

### Bezpieczniejszy wariant (zalecany)

`curl | bash` to wykonanie cudzego kodu na roocie w ciemno. Jeśli wolisz najpierw zobaczyć, co uruchamiasz:

```bash
wget https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh
less ubuntu-privacy.sh          # przeczytaj
sha256sum ubuntu-privacy.sh     # porównaj z sumą poniżej
sudo bash ubuntu-privacy.sh --dry-run
sudo bash ubuntu-privacy.sh
```

Suma kontrolna wersji **1.0.0**:

```
29ed934926b052fc23d430086c0ad189e906f2fcbe737c9c2fa737ff40c0e187  ubuntu-privacy.sh
```

Jednolinijkowa weryfikacja:

```bash
echo "29ed934926b052fc23d430086c0ad189e906f2fcbe737c9c2fa737ff40c0e187  ubuntu-privacy.sh" | sha256sum -c -
```

---

## Opcje

| Flaga | Działanie |
|---|---|
| `-y`, `--yes` | Bez pytania o potwierdzenie (wymagane przy `curl \| bash`) |
| `-n`, `--dry-run` | Wypisuje planowane operacje, nie zmienia niczego |
| `--purge` | Dodatkowo **usuwa** pakiety zamiast tylko je wyłączać |
| `--hosts` | Blokuje domeny telemetrii w `/etc/hosts` |
| `--no-firefox` | Pomija ustawianie polityk prywatności Firefoksa |
| `--keep-conncheck` | Zostawia sprawdzanie połączenia przez NetworkManagera |
| `-h`, `--help` | Pomoc |

---

## Co dokładnie jest wyłączane

### Usługi systemd (wyłączone **i zamaskowane**, żeby aktualizacja pakietu ich nie przywróciła)

`whoopsie.service`, `whoopsie.path`, `apport.service`, `apport-autoreport.{service,timer,path}`,
`kerneloops.service`, `motd-news.{service,timer}`, `apt-news.service`, `esm-cache.service`,
`ubuntu-advantage.service`, `ua-timer.{timer,service}`, `ua-reboot-cmds.service`,
`ubuntu-report.service`, `popularity-contest.{service,timer}`

### Raportowanie awarii

| Element | Zmiana |
|---|---|
| Apport | `enabled=0` w `/etc/default/apport`, wyczyszczony `/etc/apport/autoreport` |
| Zrzuty jądra | `kernel.core_pattern=\|/bin/false` — zrzuty nie trafiają już do apporta |
| Zaległe raporty | Czyszczenie `/var/crash` |
| Whoopsie | `report_crashes=false` w `/etc/whoopsie` (wysyłka do `errors.ubuntu.com`) |

### Statystyki systemu

| Element | Zmiana |
|---|---|
| popularity-contest | `PARTICIPATE="no"` w `/etc/popularity-contest.conf` |
| ubuntu-report | Usunięcie `~/.cache/ubuntu-report` wszystkich użytkowników + wyłączenie usługi |

### Reklamy Ubuntu Pro / ESM i MOTD

| Element | Zmiana |
|---|---|
| motd-news | `ENABLED=0`, `URLS=""` — koniec pobierania „wiadomości" z `motd.ubuntu.com` przy logowaniu |
| Fragmenty MOTD | `chmod -x` na `50-motd-news`, `88-esm-announce`, `91-contract-ua-esm-status`, `10-help-text`, `91-release-upgrade` |
| Hook APT | `/etc/apt/apt.conf.d/20apt-esm-hook.conf` wyzerowany (to on wstrzykuje reklamy ESM do każdego `apt upgrade`) |
| Ubuntu Pro | `pro config set apt_news=false`, jeśli `pro` jest zainstalowane |

### GNOME

Ustawienia trafiają do systemowej bazy dconf (`/etc/dconf/db/local.d/00-ubuntu-privacy`, obejmuje przyszłych użytkowników) **oraz** przez `gsettings` do wszystkich aktualnie zalogowanych użytkowników:

- `org.gnome.desktop.privacy report-technical-problems=false`
- `org.gnome.desktop.privacy send-software-usage-stats=false`
- `org.gnome.desktop.privacy remember-recent-files=false`
- `org.gnome.desktop.privacy remember-app-usage=false`
- `org.gnome.desktop.privacy remove-old-temp-files=true`, `remove-old-trash-files=true`
- `org.gnome.system.location enabled=false`

### Sieć

| Element | Zmiana |
|---|---|
| NetworkManager | `/etc/NetworkManager/conf.d/99-ubuntu-privacy.conf` — koniec cyklicznego odpytywania `connectivity-check.ubuntu.com` |
| Firefox | `/etc/firefox/policies/policies.json` — `DisableTelemetry`, `DisableFirefoxStudies`, `DisablePocket`, `DisableDefaultBrowserAgent`, wyłączone `UserMessaging` i prefy `datareporting.*` / `toolkit.telemetry.*` |
| `/etc/hosts` *(tylko `--hosts`)* | `metrics`, `popcon`, `daisy`, `errors`, `connectivity-check`, `motd` `.ubuntu.com`, `contracts.canonical.com`, `*.telemetry.mozilla.org` |

Polityki Firefoksa są zapisywane **tylko wtedy, gdy plik jeszcze nie istnieje** — własna konfiguracja nigdy nie zostanie nadpisana.

### Pakiety (tylko z `--purge`)

`ubuntu-report`, `popularity-contest`, `apport`, `apport-symptoms`, `apport-gtk`,
`whoopsie`, `whoopsie-preferences`, `kerneloops`

Bez tej flagi pakiety zostają zainstalowane, tylko unieszkodliwione.

---

## Efekty uboczne — przeczytaj przed uruchomieniem

- **`--purge` może usunąć metapakiet `ubuntu-desktop`.** Pulpit działa dalej, ale przyszłe aktualizacje wydania mogą zachowywać się inaczej. Dlatego usuwanie pakietów jest opcjonalne, a nie domyślne.
- **Wyłączenie connectivity-check psuje wykrywanie captive portali** (hotele, lotniska, pociągi). Jeśli często korzystasz z takich sieci — dodaj `--keep-conncheck`.
- **`--hosts` blokuje `contracts.canonical.com`.** Nie używaj tej flagi, jeśli masz aktywną subskrypcję Ubuntu Pro / ESM — przestanie działać.
- **Wyłączony apport = brak lokalnych zrzutów awarii.** Jeśli będziesz zgłaszać błędy w Ubuntu, najpierw cofnij zmiany.

---

## Cofanie zmian

Skrypt zapisuje wszystko do `/var/backups/ubuntu-privacy-<data-godzina>/`:

```
files/            kopie 1:1 zmodyfikowanych plików (z pełnymi ścieżkami)
manifest.files    lista zmodyfikowanych plików
manifest.created  lista plików utworzonych przez skrypt
manifest.units    lista wyłączonych jednostek systemd
manifest.pkgs     lista usuniętych pakietów
restore.sh        skrypt przywracający
```

Pełne cofnięcie:

```bash
sudo /var/backups/ubuntu-privacy-*/restore.sh
```

`restore.sh` przywraca oryginalne pliki, usuwa te utworzone przez skrypt, odmaskowuje i włącza usługi, reinstaluje usunięte pakiety i sprząta wpisy z `/etc/hosts`. Po tym zrestartuj system.

Log przebiegu: `/var/log/ubuntu-privacy.log`.

---

## Weryfikacja po uruchomieniu

```bash
# usługi powinny być "masked"
systemctl is-enabled whoopsie apport kerneloops motd-news.timer apt-news 2>&1

# ustawienia GNOME (jako zwykły użytkownik, nie root)
gsettings get org.gnome.desktop.privacy report-technical-problems
gsettings get org.gnome.desktop.privacy send-software-usage-stats
gsettings get org.gnome.system.location enabled

# apport
grep enabled /etc/default/apport

# podgląd ruchu wychodzącego do Canonical (opcjonalnie)
sudo ss -tunp | grep -Ei 'ubuntu|canonical'
```

---

## Uwagi

- Skrypt jest **idempotentny** — można go uruchomić wielokrotnie. Każde uruchomienie tworzy nowy katalog backupu, więc do pełnego cofnięcia użyj tego **najstarszego**.
- Uruchomienie po większej aktualizacji systemu ma sens — Ubuntu potrafi przywrócić część usług przy aktualizacji pakietów (maskowanie temu zapobiega, ale nowe jednostki mogą dojść).
- Skrypt **nie** rusza aktualizacji bezpieczeństwa, `unattended-upgrades` ani niczego, co odpowiada za łatanie systemu. To celowe.

## Licencja

MIT
