# MCR Server OS — testing & verification

This documents **exactly** what was verified in the Windows/Git-Bash development
environment, what could **not** be verified here, and how the owner should safely
test on a real VPS. Nothing here claims the installer was run end-to-end on a live
Linux host — it cannot be, in this environment (no real distro, no systemd).

## Environment constraints (why we test with mocks)

- Dev host is **Windows**; the only POSIX runtime is **Git Bash** (Cygwin bash 5.3).
- There is **no real Linux distro, no Docker, no systemd** available. WSL/Docker do
  not run the systemd units this installer targets.
- So the installer is proven by (a) `bash -n` syntax checks, (b) a **mock-distro
  dry-run harness**, and (c) an **agent crypto round-trip** against a local mock of
  the fleet API. The real package installs, systemd enablement and certbot can only
  be exercised on an actual VPS.
- `shellcheck` is **not installed** on this host, so static linting beyond `bash -n`
  was not run here. Run `shellcheck linux/*.sh linux/lib/*.sh linux/mcrctl
  linux/mcr-agent` on a machine that has it (recommended before release).

## What was verified here (all passing)

### 1. Syntax — `bash -n` on every script
`install.sh, get.sh, uninstall.sh, mcrctl, mcr-agent, lib/ui.sh, lib/distro.sh,
branding/profile.d-mcrsoft.sh` — all parse clean.

### 2. Mock-distro dry-run harness — `test/run-mocks.sh`  → **56 passed, 0 failed**
For each of the 7 fake distros (Ubuntu, Debian, Rocky/RHEL, Fedora, Arch,
openSUSE Leap, Alpine) the harness:
- puts logging stubs for `apt-get/dnf/yum/zypper/pacman/apk/systemctl/useradd/
  mysql/ufw/firewall-cmd/certbot/fastfetch/neofetch/...` on `PATH` (only the
  family's own package manager is present, like a real host),
- fakes `/etc/os-release` (`MCR_OSRELEASE_FILE`),
- runs `install.sh --dry-run --yes --plain --web nginx --domain … --email …`,

and asserts: **exit 0**, the **correct package manager** is chosen, a
**signature package** for that family is installed (e.g. `php-mysqlnd` on RHEL,
`php82-fpm` on Alpine, `php8-fpm` on openSUSE), the os-release branding message
states **ID/ID_LIKE/VERSION_ID are preserved**, **secrets are chmod 600**, all
**9 steps report ✓**, the **right firewall** is chosen (ufw on Debian/Ubuntu/Arch,
firewalld on RHEL/Fedora/openSUSE, skipped on Alpine), and the **certbot** step
runs when a domain+email are supplied.

### 3. Agent crypto round-trip — `test/run-agent.sh` → **13 passed, 0 failed**
Runs a local **mock fleet** (`test/router.php` via `C:\xampp\php\php.exe -S`) that
generates a **fresh Ed25519 keypair** (so the real fleet secret is never needed —
the agent is pointed at the test public key via `MCR_FLEET_PUBKEY`; production pins
the real key `XkOx…=`). It proves:
1. **enroll** stores `node_id` + `node_secret` in `agent.env`, and the secret is
   **never printed to stdout**;
2. **heartbeat** body is **HMAC-SHA256 signed** and the server **verifies** it;
3. an **unsigned** (garbage-sig) command is **REJECTED** (signature invalid);
4. a command signed with the **wrong key** is **REJECTED**;
5. a command **signed with the fleet key** is **verified, executed** (allow-listed
   `restart-service` → `systemctl restart nginx` via a stub) and the **result is
   reported back** (HMAC-signed `command-result`);
6. a **non-allow-listed** command type (`rm-rf-everything`) is **REJECTED before any
   execution**;
7. **replay**: a reused timestamp is accepted once (200) then **rejected (401)**, and
   a **tampered body with a stale signature** is **rejected (401)**.

This is the core security contract: Ed25519 verify-before-run with the pinned key,
an allow-list switch (never `eval`), HMAC heartbeats, and a replay window.

### 4. TUI render
A colourised dry-run was captured to `test/sample-ubuntu-color.txt` (ANSI banner,
boxed target/summary panels, per-step `✓` + timing, greyed dry-run commands) and a
plain run to `test/sample-ubuntu-dryrun.txt`. Reproduce the colour sample with:
```bash
MCR_FORCE_TTY=1 TERM=xterm-256color bash install.sh --dry-run --yes --domain d --email e@x
```
`MCR_FORCE_TTY=1` is a documented demo switch that forces TTY rendering when output
is piped; normal runs auto-detect the tty and honour `NO_COLOR` / `--plain`.

## How to reproduce here

```bash
cd linux
for f in install.sh get.sh uninstall.sh mcrctl mcr-agent lib/ui.sh lib/distro.sh; do bash -n "$f"; done
bash test/run-mocks.sh      # 56/56
bash test/run-agent.sh      # 13/13  (needs C:\xampp\php\php.exe + openssl + curl)
```

## What CANNOT be verified until a real VPS

These depend on a live systemd Linux host and were only exercised in dry-run / mock:

- **Actual package installation** and that distro package names resolve on every
  release (names drift; e.g. php-fpm unit is versioned on Debian `php8.2-fpm`, and
  fastfetch may need EPEL/extra repos on older RHEL — the script falls back to
  neofetch, but this needs confirming per distro/version).
- **systemd**: `systemctl enable --now`, the `mcr-agent.timer` firing every ~60s, the
  service hardening directives, `systemd-detect-virt`.
- **MariaDB**: real DB/user creation, socket-vs-TCP auth, `mysql_secure_installation`
  defaults (the script connects as root via local socket — verify on each distro).
- **Branding on a real console**: that `neofetch`/`fastfetch` actually print
  `MCRSOFT BY WOBOO.IO`, and that the os-release rewrite doesn't upset the distro's
  own tooling (we keep ID/ID_LIKE/VERSION_ID, but confirm per distro).
- **certbot / TLS**: real ACME issuance needs a public domain + open :80/:443.
- **Firewall**: ufw/firewalld actually applied without locking out SSH.
- **Real fleet**: enroll/heartbeat/command against the actual `fleet/mcr-fleet`
  plugin (workstream E), including it verifying with the **real** public key and the
  server-side replay/rate-limit behaviour.
- **aarch64**: logic is arch-agnostic but was not run on ARM.

## Safe way for the owner to test on a real VPS

1. **Use a throwaway VM first** (a $5 droplet / snapshot you can destroy). Never a
   production box on the first run.
2. **Dry-run first**, always:
   ```bash
   sudo ./install.sh --dry-run --yes --plain
   ```
   Read the printed plan; confirm the package list and steps look right for the distro.
3. Take a **snapshot** of the VM.
4. Run for real, starting **without TLS/fleet** to isolate basics:
   ```bash
   sudo ./install.sh --yes
   ```
   then check `mcrctl status`, `neofetch`, `cat /etc/os-release` (ID intact),
   `mcrctl branding off` (reverts), `mcrctl branding on`.
5. Add a domain + TLS only once DNS points at the box:
   ```bash
   sudo ./install.sh --domain your.domain --email you@domain
   ```
6. Enroll with the fleet once E is deployed:
   ```bash
   sudo mcrctl enroll https://fleet.example/wp-json <token>
   systemctl status mcr-agent.timer
   journalctl -u mcr-agent -f
   ```
7. **Uninstall / rollback**:
   ```bash
   sudo ./uninstall.sh            # keeps data + packages
   sudo ./uninstall.sh --purge    # also drops DB + /opt/mcrsoft
   ```
   Confirm `/etc/os-release` is restored from `/etc/os-release.mcr.bak`.
8. The one-liner (`get.sh`) should be hosted and tested **last**, and only after you
   pin `MCR_SUITE_SHA256` so the download is integrity-checked.
