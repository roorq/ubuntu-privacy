# ubuntu-privacy.sh

A script that disables telemetry, crash reporting and "phone home" behaviour in Ubuntu.
Tested against **Ubuntu 24.04 / 25.10 / 26.04 LTS** (it also works on Debian derivatives — steps that do not apply are simply skipped).

Every change is copied into a backup directory, and the script generates a `restore.sh` that reverts **everything**.

---

## Quick start

```bash
# 1. Preview — shows what it would do, changes nothing
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --dry-run

# 2. The real run
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes

# 3. Maximum variant — removes packages and blocks domains in /etc/hosts
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes --purge --hosts
```

> `--yes` is **required** with `curl | bash`. Without a terminal the script has no way to ask for confirmation, so it deliberately aborts.

Afterwards: **reboot the system**.

### The safer variant (recommended)

`curl | bash` means running someone else's code as root, sight unseen. If you would rather see what you are about to run first:

```bash
wget https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh
less ubuntu-privacy.sh          # read it
sha256sum ubuntu-privacy.sh     # compare with the checksum below
sudo bash ubuntu-privacy.sh --dry-run
sudo bash ubuntu-privacy.sh
```

Checksum of version **1.0.0**:

```
8f9b28b6d69c51e8b8320fb7842cfcc811aa7211d11ad0c91107dbbdfcaccbf6  ubuntu-privacy.sh
```

One-line verification:

```bash
echo "8f9b28b6d69c51e8b8320fb7842cfcc811aa7211d11ad0c91107dbbdfcaccbf6  ubuntu-privacy.sh" | sha256sum -c -
```

---

## Options

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Do not ask for confirmation (required with `curl \| bash`) |
| `-n`, `--dry-run` | Print the planned operations, change nothing |
| `--purge` | Additionally **remove** the packages instead of merely disabling them |
| `--hosts` | Block telemetry domains in `/etc/hosts` |
| `--no-firefox` | Skip writing the Firefox privacy policies |
| `--keep-conncheck` | Leave NetworkManager's connectivity checking in place |
| `-h`, `--help` | Help |

---

## What exactly gets disabled

### systemd units (disabled **and masked**, so a package update cannot bring them back)

`whoopsie.service`, `whoopsie.path`, `apport.service`, `apport-autoreport.{service,timer,path}`,
`kerneloops.service`, `motd-news.{service,timer}`, `apt-news.service`, `esm-cache.service`,
`ubuntu-advantage.service`, `ua-timer.{timer,service}`, `ua-reboot-cmds.service`,
`ubuntu-report.service`, `popularity-contest.{service,timer}`

### Crash reporting

| Item | Change |
|---|---|
| Apport | `enabled=0` in `/etc/default/apport`, `/etc/apport/autoreport` cleared |
| Kernel core dumps | `kernel.core_pattern=\|/bin/false` — dumps no longer reach apport |
| Pending reports | `/var/crash` is cleaned out |
| Whoopsie | `report_crashes=false` in `/etc/whoopsie` (uploads to `errors.ubuntu.com`) |

### System statistics

| Item | Change |
|---|---|
| popularity-contest | `PARTICIPATE="no"` in `/etc/popularity-contest.conf` |
| ubuntu-report | Removes `~/.cache/ubuntu-report` for every user + disables the unit |

### Ubuntu Pro / ESM ads and MOTD

| Item | Change |
|---|---|
| motd-news | `ENABLED=0`, `URLS=""` — no more fetching "news" from `motd.ubuntu.com` at login |
| MOTD fragments | `chmod -x` on `50-motd-news`, `88-esm-announce`, `91-contract-ua-esm-status`, `10-help-text`, `91-release-upgrade` |
| APT hook | `/etc/apt/apt.conf.d/20apt-esm-hook.conf` blanked out (this is what injects ESM ads into every `apt upgrade`) |
| Ubuntu Pro | `pro config set apt_news=false`, if `pro` is installed |

### GNOME

The settings go into the system dconf database (`/etc/dconf/db/local.d/00-ubuntu-privacy`, which covers future users) **and** are applied through `gsettings` to every currently logged-in user:

- `org.gnome.desktop.privacy report-technical-problems=false`
- `org.gnome.desktop.privacy send-software-usage-stats=false`
- `org.gnome.desktop.privacy remember-recent-files=false`
- `org.gnome.desktop.privacy remember-app-usage=false`
- `org.gnome.desktop.privacy remove-old-temp-files=true`, `remove-old-trash-files=true`
- `org.gnome.system.location enabled=false`

### Network

| Item | Change |
|---|---|
| NetworkManager | `/etc/NetworkManager/conf.d/99-ubuntu-privacy.conf` — no more periodic polling of `connectivity-check.ubuntu.com` |
| Firefox | `/etc/firefox/policies/policies.json` — `DisableTelemetry`, `DisableFirefoxStudies`, `DisablePocket`, `DisableDefaultBrowserAgent`, `UserMessaging` turned off, plus the `datareporting.*` / `toolkit.telemetry.*` prefs |
| `/etc/hosts` *(only with `--hosts`)* | `metrics`, `popcon`, `daisy`, `errors`, `connectivity-check`, `motd` `.ubuntu.com`, `contracts.canonical.com`, `*.telemetry.mozilla.org` |

The Firefox policies are written **only if the file does not already exist** — your own configuration is never overwritten.

### Packages (only with `--purge`)

`ubuntu-report`, `popularity-contest`, `apport`, `apport-symptoms`, `apport-gtk`,
`whoopsie`, `whoopsie-preferences`, `kerneloops`

Without that flag the packages stay installed, just neutralised.

---

## Side effects — read before running

- **`--purge` may remove the `ubuntu-desktop` metapackage.** The desktop keeps working, but future release upgrades may behave differently. That is why removing packages is optional rather than the default.
- **Disabling connectivity-check breaks captive portal detection** (hotels, airports, trains). If you use such networks often, add `--keep-conncheck`.
- **`--hosts` blocks `contracts.canonical.com`.** Do not use that flag if you have an active Ubuntu Pro / ESM subscription — it will stop working.
- **Apport disabled = no local crash dumps.** If you plan to file bugs against Ubuntu, revert the changes first.

---

## Reverting the changes

The script saves everything under `/var/backups/ubuntu-privacy-<date-time>/`:

```
files/            1:1 copies of the modified files (with full paths)
manifest.files    list of modified files
manifest.created  list of files created by the script
manifest.units    list of disabled systemd units
manifest.pkgs     list of removed packages
restore.sh        the restore script
```

Full rollback:

```bash
sudo /var/backups/ubuntu-privacy-*/restore.sh
```

`restore.sh` puts the original files back, deletes the ones the script created, unmasks and re-enables the units, reinstalls the removed packages and cleans up the `/etc/hosts` entries. Reboot afterwards.

Run log: `/var/log/ubuntu-privacy.log`.

---

## Verifying after a run

```bash
# the units should report "masked"
systemctl is-enabled whoopsie apport kerneloops motd-news.timer apt-news 2>&1

# GNOME settings (as a regular user, not root)
gsettings get org.gnome.desktop.privacy report-technical-problems
gsettings get org.gnome.desktop.privacy send-software-usage-stats
gsettings get org.gnome.system.location enabled

# apport
grep enabled /etc/default/apport

# a look at outbound traffic to Canonical (optional)
sudo ss -tunp | grep -Ei 'ubuntu|canonical'
```

---

## Notes

- The script is **idempotent** — you can run it repeatedly. Each run creates a new backup directory, so for a full rollback use the **oldest** one.
- Running it again after a major system upgrade makes sense — Ubuntu can bring some units back when packages are updated (masking prevents that, but new units may appear).
- The script does **not** touch security updates, `unattended-upgrades`, or anything responsible for patching the system. That is deliberate.

## License

MIT
