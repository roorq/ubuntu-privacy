# ubuntu-privacy.sh

A script that disables telemetry, crash reporting and "phone home" behaviour in Ubuntu.
Tested against **Ubuntu 24.04 / 25.10 / 26.04 LTS** (it also works on Debian derivatives — steps that do not apply are simply skipped).

Every change is copied into a backup directory, and the script generates a `restore.sh` that reverts the changes (see [Reverting the changes](#reverting-the-changes) for the few things that cannot be undone).

---

## Quick start

```bash
# 1. Preview — shows what it would do, changes nothing
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --dry-run

# 2. The real run — disables the telemetry and removes the telemetry packages
curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh | sudo bash -s -- --yes
```

> `--yes` is **required** with `curl | bash`. Without a terminal the script has no way to ask for confirmation, so it deliberately aborts.

Afterwards: **reboot the system**.

### The safer variant (recommended)

`curl | bash` means running someone else's code as root, sight unseen. If you would rather see what you are about to run first:

```bash
wget https://raw.githubusercontent.com/roorq/ubuntu-privacy/main/ubuntu-privacy.sh
less ubuntu-privacy.sh          # read it
sudo bash ubuntu-privacy.sh --dry-run
sudo bash ubuntu-privacy.sh
```

---

## Options

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Do not ask for confirmation (required with `curl \| bash`) |
| `-n`, `--dry-run` | Print the planned operations, change nothing |
| `--keep-packages` | Do not remove the telemetry packages, only disable them |
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

The previous state of every unit is recorded, and `restore.sh` re-enables only the units that were enabled before (e.g. `apport-autoreport.*`, which Ubuntu ships disabled, stays disabled).

**Ubuntu Pro:** if the machine is attached to Pro (`pro status`), `ubuntu-advantage`, `ua-timer`, `ua-reboot-cmds` and `esm-cache` are left alone.

### Package config files

Files that belong to a package (`/etc/default/apport`, `/etc/default/motd-news`, `/etc/whoopsie`, `20apt-esm-hook.conf`, ...) are not edited in place. The script moves the package's version aside with `dpkg-divert` (to `<file>.dpkg-divert`) and writes its own. Package updates then go to the diverted file, so they never stop on a conffile prompt, and `unattended-upgrades` keeps installing them.

### Crash reporting

| Item | Change |
|---|---|
| Apport | `enabled=0` in `/etc/default/apport`; `/etc/apport/autoreport` **removed** (its mere existence turns automatic uploading on) |
| Kernel core dumps | `kernel.core_pattern` handed back to the system default (systemd-coredump if installed, otherwise the kernel's `core`), so dumps no longer reach apport but still work for debugging |
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
- `org.gnome.system.location enabled=false`

### Network

| Item | Change |
|---|---|
| NetworkManager | `/etc/NetworkManager/conf.d/99-ubuntu-privacy.conf` — no more periodic polling of `connectivity-check.ubuntu.com` |
| Firefox | `/etc/firefox/policies/policies.json` — `DisableTelemetry`, `DisableFirefoxStudies`, `DisablePocket`, `DisableDefaultBrowserAgent`, `UserMessaging` turned off, plus the new-tab activity-stream telemetry prefs (locked) |

The Firefox policies are written **only if the file does not already exist** — your own configuration is never overwritten.

### Telemetry packages (removed)

`ubuntu-report`, `popularity-contest`, `apport`, `apport-symptoms`, `apport-gtk`,
`whoopsie`, `whoopsie-preferences`, `kerneloops`

Before removing anything the script simulates the removal of each package (`apt-get -s purge`). A package whose removal would take **any other package** with it — typically the `ubuntu-desktop` metapackage — is kept installed (but disabled, see above); the rest are removed. `apt-get autoremove` is never run. With `--keep-packages` nothing is removed.

---

## Side effects — read before running

- **GNOME stops remembering recent files and app usage** (`remember-recent-files`, `remember-app-usage`). Turn them back on in Settings → Privacy if you rely on them.
- **Disabling connectivity-check breaks captive portal detection** (hotels, airports, trains). If you use such networks often, add `--keep-conncheck`.
- **Apport disabled = no crash reports for Ubuntu bugs.** Core dumps themselves still go to systemd-coredump / the kernel default. If you plan to file bugs against Ubuntu, revert the changes first.

---

## Reverting the changes

The script saves everything under `/var/backups/ubuntu-privacy-<date-time>/`:

```
files/              1:1 copies of the modified / removed files (with full paths)
manifest.files      list of modified / removed files
manifest.created    list of files created by the script
manifest.diverted   package config files replaced via dpkg-divert
manifest.units      disabled systemd units + their previous state
manifest.pkgs       removed packages
manifest.gsettings  per-user GNOME settings + their previous values
manifest.pro        present if `pro config apt_news` was changed
restore.sh          the restore script
```

Full rollback (the exact path is printed at the end of the run):

```bash
ls -d /var/backups/ubuntu-privacy-*                       # find the backup directory
sudo /var/backups/ubuntu-privacy-20261106-120000/restore.sh
```

`restore.sh` puts the original files back, deletes the ones the script created, undoes the diversions, unmasks the units (re-enabling only those that were enabled before), reinstalls the removed packages, resets the per-user GNOME settings and `pro`'s `apt_news`. It keeps going if one step fails and lists the failures at the end. Reboot afterwards.

What cannot be reverted: the deleted crash reports in `/var/crash` and the `~/.cache/ubuntu-report` caches. GNOME settings of users who are not logged in during the restore are reset with `dbus-run-session`.

Run log: `/var/log/ubuntu-privacy.log`.

---

## Verifying after a run

```bash
# the units should report "masked" (or "not-found" if their package was removed)
systemctl is-enabled whoopsie apport kerneloops motd-news.timer apt-news 2>&1

# the telemetry packages should be gone (any that are listed were kept on purpose - see the run log)
dpkg -l ubuntu-report popularity-contest apport apport-gtk whoopsie kerneloops 2>/dev/null | grep '^ii'

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

- The script is **idempotent** — you can run it repeatedly. Each run creates a new backup directory (and warns if one already exists). For a full rollback run the `restore.sh` scripts **newest first**, or only the **oldest** one.
- Running it again after a major system upgrade makes sense — Ubuntu can bring some units back when packages are updated (masking prevents that, but new units may appear).
- The script does **not** touch security updates, `unattended-upgrades`, or anything responsible for patching the system. That is deliberate.

## License

MIT
