# MCR Server OS — universal Linux installer suite

Turn any fresh, supported Linux VPS into a branded **MCRSOFT BY WOBOO.IO** server with a
single command. MCR Server OS installs the web stack (nginx/apache + PHP-FPM + MariaDB),
deploys the MCR application, applies cosmetic branding so `neofetch`/`fastfetch` show
`MCRSOFT BY WOBOO.IO`, and registers the host with the MCR Fleet dashboard for central
management.

> ### Honest limits — read this
> **MCR Server OS is not a new kernel or a from-scratch operating system.** It is a
> *provisioning + branding + management layer* installed **on top of your existing Linux
> distribution**. The reason `neofetch`/`fastfetch` display `MCRSOFT BY WOBOO.IO` is that we
> change `PRETTY_NAME`/`NAME` in `/etc/os-release` and ship fastfetch/neofetch configs — this
> is **cosmetic and fully reversible** (`mcrctl branding off`). We deliberately **keep
> `ID`, `ID_LIKE` and `VERSION_ID` intact** so your package manager and every distro-detection
> tool keep working. The original `/etc/os-release` is backed up to `/etc/os-release.mcr.bak`.
> Nothing here claims to be unbreakable; the fleet command channel is protected by standard
> Ed25519 signatures and an allow-list, which raises the bar but is not magic.

## Quick start

```bash
# One-liner (hosted bootstrap -> downloads + sha256-verifies the suite + runs install.sh)
curl -fsSL https://raw.githubusercontent.com/Xrack762/installer/main/get.sh | sudo bash

# With options
curl -fsSL https://raw.githubusercontent.com/Xrack762/installer/main/get.sh | sudo bash -s -- \
  --domain example.com --email you@example.com \
  --fleet-url https://fleet.example.com/wp-json --enroll-token XXXX

# Or from a local checkout
sudo ./install.sh --domain example.com --email you@example.com
```

**Always dry-run first** on anything you care about:

```bash
sudo ./install.sh --dry-run --yes --plain
```

## Supported systems

| Family | IDs | Package manager |
|---|---|---|
| Debian / Ubuntu | debian, ubuntu, mint, pop, kali… | `apt-get` |
| RHEL family | rhel, rocky, almalinux, centos, oracle | `dnf` → `yum` |
| Fedora | fedora | `dnf` |
| Arch | arch, manjaro, endeavouros | `pacman` |
| openSUSE | opensuse-leap, opensuse-tumbleweed, sles | `zypper` |
| Alpine | alpine | `apk` |

Architectures: `x86_64`, `aarch64`. Anything else fails clearly. Root required.

## Flags

```
--domain <d>        Public domain (enables TLS via certbot unless --no-tls)
--email <e>         Email for Let's Encrypt
--no-tls            Skip TLS
--web nginx|apache  Web server (default nginx)
--fleet-url <url>   MCR Fleet base URL (…/wp-json) for enrollment
--enroll-token <t>  Fleet enrollment token
--plain             No colour/unicode (also auto when NO_COLOR set or non-tty)
--dry-run           Mock all package/system mutations; prove the flow, change nothing
--yes               Assume yes to prompts
```

## What gets installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/mcrctl` | Admin CLI |
| `/usr/local/bin/mcr-agent` | Fleet agent (enroll/heartbeat/command runner) |
| `/usr/local/lib/mcrsoft/` | shared `ui.sh` + `distro.sh` |
| `/etc/mcrsoft/secrets.env` | DB + app secrets — **chmod 600** |
| `/etc/mcrsoft/agent.env` | node_id + node_secret — **chmod 600** |
| `/etc/mcrsoft/fleet.pub` | pinned fleet **public** key (verify-only) |
| `/etc/mcrsoft/branding-src/` | branding assets for `mcrctl branding` |
| `/opt/mcrsoft/www` | web root |
| `/opt/mcrsoft/data` | private data (outside web root) |
| `/etc/os-release` | `PRETTY_NAME`/`NAME` overridden; `ID*`/`VERSION_ID` kept |
| `/etc/os-release.mcr.bak` | original, for reversal |
| `/etc/mcrsoft-release`, `/etc/motd`, `/etc/profile.d/mcrsoft.sh` | branding/MOTD |
| `/etc/systemd/system/mcr-agent.{service,timer}` | heartbeat every ~60s |
| `/etc/systemd/system/mcr-web.service` | groups nginx/php-fpm/mariadb |
| `/var/log/mcrsoft/install.log`, `/var/log/mcrsoft/agent.log` | logs |

## mcrctl

```
mcrctl status [--json]      services + health + fastfetch
mcrctl start|stop|restart   manage the stack
mcrctl backup | restore <f> DB + web root
mcrctl update               refresh packages/app
mcrctl license              license marker state
mcrctl enroll <url> <token> register this node with the fleet
mcrctl node [--json]        node id + profile + fingerprint
mcrctl branding on|off      apply / reverse branding
mcrctl uninstall            remove MCR Server OS
mcrctl version
```

## Fleet agent & security

The agent speaks the shared `fleet/v1` contract (workstream E):

- **Enroll** `POST /fleet/v1/enroll {token, node}` → `{node_id, node_secret}`.
  `node_secret` becomes the HMAC key for this node's own heartbeats and is stored in
  `/etc/mcrsoft/agent.env` (chmod 600). The node also pins the fleet **public** key.
- **Heartbeat** `POST /fleet/v1/heartbeat` every ~60s via the systemd timer, carrying the
  device profile + live metrics (load, cpu%, mem, disk, uptime, service states, versions,
  public IP). The body is **HMAC-SHA256 signed** with `node_secret` over the exact body;
  the fleet must reject timestamps older than the **5-minute replay window**.
- **Commands** come back in the heartbeat response. Each command is **Ed25519-signed by the
  fleet secret key**; the agent verifies it with the pinned **public** key *before* running,
  and only runs commands whose `type` is on the allow-list. There is **no `eval`** and no
  arbitrary shell from the network.

### Command allow-list (the ONLY things the agent will run)

| type | action | guard |
|---|---|---|
| `restart-service` | `systemctl restart <svc>` | svc must be one of nginx/apache2/httpd/php-fpm/mariadb/mcr-agent.timer |
| `backup-now` | `mcrctl backup` | — |
| `update` | `mcrctl update` | — |
| `branding` | `mcrctl branding on\|off` | state ∈ {on,off} |
| `collect-logs` | tail agent log + journal | read-only |
| `set-maintenance` | toggle `/etc/mcrsoft/MAINTENANCE` | enabled ∈ {true,false} |
| `reboot` | `systemctl reboot` | requires `payload.confirm == "yes"` |

Any other type, a bad/missing signature, or a disallowed service argument is **rejected and
reported** (never executed).

### Node profile / fingerprint

`{ node_id, hostname, fqdn, machine_id(hashed), fingerprint, os{distro_id,pretty,version,
kernel,arch}, cpu{model,cores,threads}, mem_total_mb, disk_total_gb, primary_ip, public_ip,
virt, mcr{app_version,php_version,db_version,web}, agent_version, enrolled_at }`.
`fingerprint = sha256(machine_id | product_uuid | primary MAC)`.

## Branding (how the brand appears, honestly)

`mcrctl branding on` (also run automatically during install):

1. Backs up `/etc/os-release` → `/etc/os-release.mcr.bak` (once).
2. Rewrites `/etc/os-release` keeping every original line **except** `PRETTY_NAME`/`NAME`
   (overridden) and adds `MCR_VARIANT`/`MCR_VERSION`/`HOME_URL`/`SUPPORT_URL`.
   `ID`, `ID_LIKE`, `VERSION_ID` are **never touched**.
3. Installs the fastfetch config + ASCII logo, a neofetch config (root, `/etc/skel`, existing
   users), `/etc/mcrsoft-release`, `/etc/motd` and `/etc/profile.d/mcrsoft.sh`.

`mcrctl branding off` restores the backup and removes the branding files.

## Uninstall

```bash
sudo ./uninstall.sh            # remove MCR layer, keep DB/app + installed packages
sudo ./uninstall.sh --purge    # ALSO drop the DB and /opt/mcrsoft (prompts)
```

Uninstall deregisters from the fleet, stops/disables the units, restores `/etc/os-release`,
removes branding, and (with `--purge`) drops data. The underlying distro and the packages it
installed are intentionally left in place.

## Testing

See [`TESTING.md`](TESTING.md). A mock-distro dry-run harness (`test/run-mocks.sh`) proves every
distro branch, the branding render, secret permissions and the agent crypto path without a real
VPS. Items that can only be verified on a real systemd host are listed there too.
