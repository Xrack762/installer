#!/usr/bin/env bash
# =============================================================================
#  MCR Server OS — universal Linux installer
#  Turns a fresh supported Linux VPS into a branded MCR server.
#  "MCR Server OS" is a provisioning + branding + management layer over your
#  existing distro. It is NOT a new kernel or from-scratch OS.
#
#  Usage:  sudo ./install.sh [flags]
#  One-liner: curl -fsSL https://raw.githubusercontent.com/Xrack762/installer/main/get.sh | sudo bash
# =============================================================================
set -euo pipefail

MCR_VERSION="1.0.0"

# Fleet signing PUBLIC key (Ed25519, base64 raw 32 bytes). Verify-only on nodes.
MCR_FLEET_PUBKEY_DEFAULT="XkOxmTbHwx/EIhgtYHcygLLzXi3wVlF3R3D6U1ZbIRw="

# ---- locate our own directory (works for local run; one-liner self-fetches) --
SELF_SRC="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF_SRC")" 2>/dev/null && pwd || echo "")"

# When piped from curl there is no script dir with lib/. Allow MCR_SRC_DIR / a
# download base to be set; the one-liner (get.sh) clones the suite first.
LIB_DIR="${MCR_SRC_DIR:-$SCRIPT_DIR}/lib"
BRANDING_DIR="${MCR_SRC_DIR:-$SCRIPT_DIR}/branding"

# ---- defaults / flags --------------------------------------------------------
OPT_DOMAIN=""
OPT_EMAIL=""
OPT_NO_TLS=0
OPT_WEB="nginx"
OPT_FLEET_URL=""
OPT_ENROLL_TOKEN=""
OPT_PLAIN=0
OPT_DRYRUN=0
OPT_YES=0

LOG_FILE="/var/log/mcrsoft/install.log"
ETC_DIR="/etc/mcrsoft"
APP_ROOT="/opt/mcrsoft"
WWW_DIR="$APP_ROOT/www"
DATA_DIR="$APP_ROOT/data"
SECRETS_ENV="$ETC_DIR/secrets.env"
AGENT_ENV="$ETC_DIR/agent.env"

usage() {
  cat <<'EOF'
MCR Server OS installer

  --domain <d>        Public domain for the site (enables TLS unless --no-tls)
  --email <e>         Email for Let's Encrypt registration
  --no-tls            Skip certbot / TLS
  --web nginx|apache  Web server to install (default: nginx)
  --fleet-url <url>   MCR Fleet base URL (…/wp-json) for agent enrollment
  --enroll-token <t>  Fleet enrollment token
  --plain             Disable colour/unicode (also honours NO_COLOR / non-tty)
  --dry-run           Mock all package/system mutations; prove the flow, no changes
  --yes               Assume "yes" to prompts (non-interactive)
  -h, --help          This help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) OPT_DOMAIN="${2:-}"; shift 2 ;;
      --domain=*) OPT_DOMAIN="${1#*=}"; shift ;;
      --email) OPT_EMAIL="${2:-}"; shift 2 ;;
      --email=*) OPT_EMAIL="${1#*=}"; shift ;;
      --no-tls) OPT_NO_TLS=1; shift ;;
      --web) OPT_WEB="${2:-}"; shift 2 ;;
      --web=*) OPT_WEB="${1#*=}"; shift ;;
      --fleet-url) OPT_FLEET_URL="${2:-}"; shift 2 ;;
      --fleet-url=*) OPT_FLEET_URL="${1#*=}"; shift ;;
      --enroll-token) OPT_ENROLL_TOKEN="${2:-}"; shift 2 ;;
      --enroll-token=*) OPT_ENROLL_TOKEN="${1#*=}"; shift ;;
      --plain) OPT_PLAIN=1; shift ;;
      --dry-run) OPT_DRYRUN=1; shift ;;
      --yes|-y) OPT_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done
  case "$OPT_WEB" in nginx|apache) : ;; *) echo "--web must be nginx or apache" >&2; exit 2 ;; esac
}

# ---- command runner: honours --dry-run, logs everything, NEVER evals ----------
# All system mutation goes through run(). In dry-run it only logs the argv.
run() {
  _logline "RUN $*"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s %s\n' "$(_c "$C_GREY" "(dry-run)")" "$(_c "$C_GREY" "$*")"
    return 0
  fi
  "$@"
}

# run_sh: run a shell snippet that legitimately needs shell features (pipes,
# redirection). The snippet is a fixed string WE author — never user input.
run_sh() {
  _logline "RUN-SH $*"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s %s\n' "$(_c "$C_GREY" "(dry-run sh)")" "$(_c "$C_GREY" "$*")"
    return 0
  fi
  sh -c "$1"
}

die() { ui_error "$*"; exit 1; }

require_root() {
  if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && [ "$OPT_DRYRUN" != "1" ]; then
    die "This installer must run as root (use sudo)."
  fi
}

# rand_secret <nbytes> : url-safe-ish random string, never logged.
rand_secret() {
  local n="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((n * 2)) | tr -dc 'A-Za-z0-9' | head -c "$n"
  elif [ -r /dev/urandom ]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n"
  else
    date +%s%N | sha256sum | head -c "$n"
  fi
}

# write_secret_file <path> <content> : creates with chmod 600, no echo of value.
write_secret_file() {
  local path="$1" content="$2"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s %s (chmod 600)\n' "$(_c "$C_GREY" "(dry-run write)")" "$(_c "$C_GREY" "$path")"
    _logline "WRITE-SECRET $path (chmod 600) [value redacted]"
    return 0
  fi
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir"
  ( umask 077; printf '%s\n' "$content" > "$path" )
  chmod 600 "$path"
  _logline "WRITE-SECRET $path (chmod 600) [value redacted]"
}

# =============================================================================
#  Main
# =============================================================================
main() {
  parse_args "$@"

  # propagate plain mode to the UI before init
  [ "$OPT_PLAIN" = "1" ] && export MCR_PLAIN=1
  [ "$OPT_YES" = "1" ] && export MCR_ASSUME_YES=1

  # shellcheck source=lib/ui.sh
  [ -r "$LIB_DIR/ui.sh" ] || { echo "Missing $LIB_DIR/ui.sh" >&2; exit 1; }
  # shellcheck source=lib/distro.sh
  [ -r "$LIB_DIR/distro.sh" ] || { echo "Missing $LIB_DIR/distro.sh" >&2; exit 1; }
  . "$LIB_DIR/ui.sh"
  . "$LIB_DIR/distro.sh"

  ui_init
  ui_log_init "${MCR_LOG_FILE:-$LOG_FILE}"
  _logline "===== MCR Server OS installer v$MCR_VERSION start (dry-run=$OPT_DRYRUN) ====="

  ui_banner "$BRANDING_DIR/logo.txt"
  [ "$OPT_DRYRUN" = "1" ] && ui_warn "DRY-RUN: no changes will be made. Proving the flow only."

  require_root

  # ---- detect ---------------------------------------------------------------
  if ! distro_detect; then
    die "Could not detect a supported distro or package manager."
  fi
  if ! distro_supported; then
    die "Unsupported system: $(distro_human). Supported: Debian/Ubuntu, RHEL/Rocky/Alma/CentOS, Fedora, Arch/Manjaro, openSUSE, Alpine on x86_64/aarch64."
  fi

  ui_box "Target system" \
    "Distro     : $(distro_human)" \
    "Pkg manager: $PKG ($PKG_FAMILY)" \
    "Web server : $OPT_WEB" \
    "Domain     : ${OPT_DOMAIN:-<none> (IP only)}" \
    "TLS        : $([ "$OPT_NO_TLS" = 1 ] && echo disabled || { [ -n "$OPT_DOMAIN" ] && echo "certbot" || echo "n/a (no domain)"; })" \
    "Fleet      : ${OPT_FLEET_URL:-<not enrolling>}"
  echo

  if ! ui_confirm "Proceed with installation on this host?"; then
    ui_warn "Aborted by user."; exit 0
  fi

  ui_steps_total 9

  # ---- 1. base repos + tools ------------------------------------------------
  ui_step_begin "Refresh repositories & install base tools"
  do_base_tools || { ui_step_end 1 "base tools"; die "base tools failed"; }
  ui_step_end 0

  # ---- 2. web server --------------------------------------------------------
  ui_step_begin "Install web server ($OPT_WEB)"
  do_webserver || { ui_step_end 1; die "web server install failed"; }
  ui_step_end 0

  # ---- 3. PHP-FPM -----------------------------------------------------------
  ui_step_begin "Install PHP-FPM (>=8.1) + extensions"
  do_php || { ui_step_end 1; die "php install failed"; }
  ui_step_end 0

  # ---- 4. MariaDB -----------------------------------------------------------
  ui_step_begin "Install & initialise MariaDB"
  do_mariadb || { ui_step_end 1; die "mariadb install failed"; }
  ui_step_end 0

  # ---- 5. app + db creds ----------------------------------------------------
  ui_step_begin "Create database, app user & secrets"
  do_app_and_secrets || { ui_step_end 1; die "app provisioning failed"; }
  ui_step_end 0

  # ---- 6. branding ----------------------------------------------------------
  ui_step_begin "Apply MCRSOFT branding (os-release, fastfetch, MOTD)"
  do_branding || { ui_step_end 1; die "branding failed"; }
  ui_step_end 0

  # ---- 7. firewall + TLS ----------------------------------------------------
  ui_step_begin "Configure firewall & TLS"
  do_firewall_tls || { ui_step_end 1; die "firewall/tls failed"; }
  ui_step_end 0

  # ---- 8. systemd units + mcrctl/agent install ------------------------------
  ui_step_begin "Install mcrctl, mcr-agent & systemd units"
  do_install_tooling || { ui_step_end 1; die "tooling install failed"; }
  ui_step_end 0

  # ---- 9. fleet enroll (optional) -------------------------------------------
  ui_step_begin "Enroll with MCR Fleet"
  do_enroll || { ui_step_end 1; ui_warn "Enrollment failed (non-fatal); run 'mcrctl enroll' later."; }
  ui_step_end 0
  echo

  # ---- summary --------------------------------------------------------------
  local url_host="${OPT_DOMAIN:-$(primary_ip)}"
  local scheme="http"; { [ -n "$OPT_DOMAIN" ] && [ "$OPT_NO_TLS" != 1 ]; } && scheme="https"
  ui_summary "Installation complete — MCRSOFT BY WOBOO.IO" \
    "Site URL     : $scheme://$url_host/" \
    "Web root     : $WWW_DIR" \
    "Secrets      : $SECRETS_ENV (chmod 600)" \
    "Admin CLI    : mcrctl status" \
    "Branding     : neofetch / fastfetch now show 'MCRSOFT BY WOBOO.IO'" \
    "Fleet agent  : systemctl status mcr-agent.timer" \
    "Install log  : ${MCR_LOG_FILE:-$LOG_FILE}"
  ui_note "DB credentials are stored only in $SECRETS_ENV (never printed)."
  _logline "===== installer finished ok ====="
  return 0
}

# ---------------------------------------------------------------------------
# Step implementations
# ---------------------------------------------------------------------------
pm_update() { run_sh "$(pkg_update_cmd)"; }
pm_install() { # pm_install <pkg...>
  [ -n "$*" ] || return 0
  run_sh "$(pkg_install_cmd) $*"
}

do_base_tools() {
  # Non-interactive frontends
  [ "$PKG_FAMILY" = "deb" ] && export DEBIAN_FRONTEND=noninteractive
  pm_update
  pm_install "$(pkg_names tools)"
  # fastfetch, with neofetch fallback (best-effort; never fatal)
  if ! pm_install "$(pkg_names fetch)"; then
    ui_note "fastfetch unavailable; trying neofetch"
    pm_install "$(pkg_names fetch-fallback)" || ui_note "no fetch tool installed (branding MOTD still works)"
  fi
  return 0
}

do_webserver() {
  if [ "$OPT_WEB" = "apache" ]; then
    pm_install "$(pkg_names web-apache)"
    run systemctl enable --now "$(svc_name web-apache)"
  else
    pm_install "$(pkg_names web-nginx)"
    run systemctl enable --now "$(svc_name web-nginx)"
  fi
}

do_php() {
  pm_install "$(pkg_names php)"
  run systemctl enable --now "$(svc_name phpfpm)" || ui_note "php-fpm unit name varies; verify with 'systemctl'"
}

do_mariadb() {
  pm_install "$(pkg_names mariadb)"
  # Arch/some RPM need explicit data dir init
  if [ "$PKG_FAMILY" = "arch" ]; then
    run_sh "[ -d /var/lib/mysql/mysql ] || mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql"
  fi
  run systemctl enable --now "$(svc_name mariadb)"
}

do_app_and_secrets() {
  mkdir_p_run "$ETC_DIR" "$WWW_DIR" "$DATA_DIR"
  # Idempotent: reuse existing secrets if present.
  if [ -r "$SECRETS_ENV" ] && [ "$OPT_DRYRUN" != "1" ]; then
    ui_note "secrets.env already exists; reusing"
  else
    local db_name="mcr_app" db_user="mcr_app" db_pass
    db_pass="$(rand_secret 28)"
    local wp_salt; wp_salt="$(rand_secret 48)"
    write_secret_file "$SECRETS_ENV" "$(cat <<EOF
# MCR Server OS secrets — chmod 600 — do not share
MCR_DB_NAME=$db_name
MCR_DB_USER=$db_user
MCR_DB_PASS=$db_pass
MCR_DB_HOST=127.0.0.1
MCR_WEB=$OPT_WEB
MCR_DOMAIN=$OPT_DOMAIN
MCR_SECRET_SALT=$wp_salt
EOF
)"
    # Create DB + user (idempotent SQL). Password passed via stdin, never argv.
    if [ "$OPT_DRYRUN" = "1" ]; then
      printf '      %s create db/user mcr_app (password redacted)\n' "$(_c "$C_GREY" "(dry-run mysql)")"
    else
      mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'127.0.0.1' IDENTIFIED BY '$db_pass';
ALTER USER '$db_user'@'127.0.0.1' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
    fi
  fi

  # Deploy app bundle if provided (sha256-verified), else leave web root ready.
  if [ -n "${MCR_APP_BUNDLE:-}" ]; then
    deploy_bundle "$MCR_APP_BUNDLE" "${MCR_APP_BUNDLE_SHA256:-}" || return 1
  else
    ui_note "No app bundle supplied; web root prepared at $WWW_DIR"
    run_sh "[ -f '$WWW_DIR/index.html' ] || printf '%s\n' '<h1>MCRSOFT BY WOBOO.IO</h1><p>Server ready.</p>' > '$WWW_DIR/index.html'"
  fi
  # Ownership
  run_sh "id mcrsoft >/dev/null 2>&1 || useradd --system --home '$APP_ROOT' --shell /usr/sbin/nologin mcrsoft || true"
  run_sh "chown -R mcrsoft:mcrsoft '$APP_ROOT' 2>/dev/null || true"
}

# deploy_bundle <path-or-url> <sha256>
deploy_bundle() {
  local src="$1" want="$2" tmp="/tmp/mcr-bundle.$$"
  mkdir_p_run "$tmp"
  case "$src" in
    http://*|https://*) run_sh "curl -fsSL '$src' -o '$tmp/bundle.zip'" ;;
    *) run_sh "cp '$src' '$tmp/bundle.zip'" ;;
  esac
  if [ -n "$want" ]; then
    if [ "$OPT_DRYRUN" = "1" ]; then
      ui_note "(dry-run) would verify sha256=$want"
    else
      local got; got="$(sha256sum "$tmp/bundle.zip" | awk '{print $1}')"
      if [ "$got" != "$want" ]; then
        ui_error "Bundle sha256 mismatch (want $want got $got)"; return 1
      fi
      ui_note "bundle sha256 verified"
    fi
  else
    ui_warn "No sha256 given for bundle; cannot verify integrity"
  fi
  run_sh "unzip -oq '$tmp/bundle.zip' -d '$WWW_DIR'"
  run_sh "rm -rf '$tmp'"
}

do_branding() {
  install_mcrctl_now  # ensure mcrctl present so we can call branding on
  # Perform branding directly (same logic mcrctl uses).
  branding_apply on
}

do_firewall_tls() {
  local fw; fw="$(pkg_names firewall)"
  if [ -n "$fw" ]; then
    pm_install "$fw" || ui_note "firewall package unavailable; skipping"
    case "$(svc_name firewall)" in
      ufw)
        run systemctl enable --now ufw || true
        run ufw --force enable || true
        run ufw allow 22/tcp || true
        run ufw allow 80/tcp || true
        run ufw allow 443/tcp || true
        ;;
      firewalld)
        run systemctl enable --now firewalld || true
        run firewall-cmd --permanent --add-service=http || true
        run firewall-cmd --permanent --add-service=https || true
        run firewall-cmd --permanent --add-service=ssh || true
        run firewall-cmd --reload || true
        ;;
    esac
  else
    ui_note "No managed firewall for this distro; configure manually"
  fi

  if [ -n "$OPT_DOMAIN" ] && [ "$OPT_NO_TLS" != "1" ]; then
    [ -n "$OPT_EMAIL" ] || { ui_warn "TLS requested but no --email; skipping certbot"; return 0; }
    pm_install "$(pkg_names certbot)" || { ui_note "certbot unavailable; skipping TLS"; return 0; }
    if [ "$OPT_WEB" = "nginx" ]; then
      run certbot --nginx -n --agree-tos -m "$OPT_EMAIL" -d "$OPT_DOMAIN" || ui_warn "certbot failed; site still on HTTP"
    else
      run certbot --apache -n --agree-tos -m "$OPT_EMAIL" -d "$OPT_DOMAIN" || ui_warn "certbot failed; site still on HTTP"
    fi
  else
    ui_note "TLS skipped ($([ -z "$OPT_DOMAIN" ] && echo 'no domain' || echo '--no-tls'))"
  fi
  return 0
}

do_install_tooling() {
  local src="${MCR_SRC_DIR:-$SCRIPT_DIR}"
  install_mcrctl_now
  # mcr-agent
  run_sh "install -m 0755 '$src/mcr-agent' /usr/local/bin/mcr-agent 2>/dev/null || cp '$src/mcr-agent' /usr/local/bin/mcr-agent"
  run_sh "chmod 0755 /usr/local/bin/mcr-agent"
  # embed pinned fleet pubkey for the agent
  write_regular_file "$ETC_DIR/fleet.pub" "$MCR_FLEET_PUBKEY_DEFAULT"
  # systemd units
  if [ -d "$src/systemd" ]; then
    run_sh "cp '$src/systemd/mcr-agent.service' /etc/systemd/system/ 2>/dev/null || true"
    run_sh "cp '$src/systemd/mcr-agent.timer' /etc/systemd/system/ 2>/dev/null || true"
    run_sh "cp '$src/systemd/mcr-web.service' /etc/systemd/system/ 2>/dev/null || true"
    run systemctl daemon-reload || true
    run systemctl enable --now mcr-agent.timer || ui_note "enable mcr-agent.timer later (needs enrollment)"
  fi
  return 0
}

install_mcrctl_now() {
  local src="${MCR_SRC_DIR:-$SCRIPT_DIR}"
  [ -x /usr/local/bin/mcrctl ] && return 0
  run_sh "install -m 0755 '$src/mcrctl' /usr/local/bin/mcrctl 2>/dev/null || cp '$src/mcrctl' /usr/local/bin/mcrctl"
  run_sh "chmod 0755 /usr/local/bin/mcrctl"
  # make libs + branding available system-wide for mcrctl/agent
  mkdir_p_run /usr/local/lib/mcrsoft "$ETC_DIR"
  run_sh "cp '$src/lib/ui.sh' '$src/lib/distro.sh' /usr/local/lib/mcrsoft/ 2>/dev/null || true"
  run_sh "cp -r '$src/branding' '$ETC_DIR/branding-src' 2>/dev/null || true"
}

do_enroll() {
  if [ -z "$OPT_FLEET_URL" ] || [ -z "$OPT_ENROLL_TOKEN" ]; then
    ui_note "No --fleet-url/--enroll-token; skipping enrollment"
    return 0
  fi
  if [ "$OPT_DRYRUN" = "1" ]; then
    ui_note "(dry-run) would run: mcr-agent enroll '$OPT_FLEET_URL' <token-redacted>"
    return 0
  fi
  MCR_FLEET_URL="$OPT_FLEET_URL" /usr/local/bin/mcr-agent enroll "$OPT_FLEET_URL" "$OPT_ENROLL_TOKEN"
}

# ---------------------------------------------------------------------------
# Branding apply/remove (shared with mcrctl). Kept here so install.sh is
# self-contained; mcrctl sources this file's functions via /usr/local/lib copy.
# ---------------------------------------------------------------------------
branding_apply() { # branding_apply on|off
  local mode="$1"
  local bsrc="$BRANDING_DIR"
  [ -d "$bsrc" ] || bsrc="$ETC_DIR/branding-src"
  if [ "$mode" = "off" ]; then
    branding_remove; return $?
  fi
  mkdir_p_run "$ETC_DIR"
  # logo + release + configs
  run_sh "cp '$bsrc/logo.txt' '$ETC_DIR/logo.txt'"
  run_sh "cp '$bsrc/mcrsoft-release' /etc/mcrsoft-release"
  run_sh "cp '$bsrc/fastfetch.jsonc' '$ETC_DIR/fastfetch.jsonc'"
  run_sh "cp '$bsrc/neofetch.conf' '$ETC_DIR/neofetch.conf'"
  run_sh "cp '$bsrc/motd' /etc/motd"
  run_sh "cp '$bsrc/profile.d-mcrsoft.sh' /etc/profile.d/mcrsoft.sh && chmod 0644 /etc/profile.d/mcrsoft.sh"
  # os-release override (keep ID/ID_LIKE/VERSION_ID)
  osrelease_brand "$bsrc/os-release.fields"
  # neofetch config for root + skel + existing users
  neofetch_configs
  ui_note "branding on: neofetch/fastfetch now show MCRSOFT BY WOBOO.IO"
}

branding_remove() {
  if [ -f /etc/os-release.mcr.bak ]; then
    run_sh "cp /etc/os-release.mcr.bak /etc/os-release"
    ui_note "restored original /etc/os-release"
  fi
  run_sh "rm -f /etc/mcrsoft-release /etc/profile.d/mcrsoft.sh '$ETC_DIR/fastfetch.jsonc' '$ETC_DIR/neofetch.conf' 2>/dev/null || true"
  run_sh "rm -f /root/.config/neofetch/config.conf 2>/dev/null || true"
  ui_note "branding off"
}

# osrelease_brand <fields-file>: back up, then override PRETTY_NAME/NAME + add MCR_*.
osrelease_brand() {
  local fields="$1" target="/etc/os-release"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s back up %s then set PRETTY_NAME/NAME + MCR_* (keep ID/ID_LIKE/VERSION_ID)\n' \
      "$(_c "$C_GREY" "(dry-run)")" "$target"
    return 0
  fi
  [ -f "$target.mcr.bak" ] || cp "$target" "$target.mcr.bak"
  # Build a new file: copy original, drop keys we override, append our fields.
  local tmp; tmp="$(mktemp)"
  # keep every original line EXCEPT PRETTY_NAME/NAME/HOME_URL/SUPPORT_URL/MCR_*/LOGO
  grep -Ev '^(PRETTY_NAME|NAME|HOME_URL|SUPPORT_URL|LOGO|MCR_[A-Z_]+)=' "$target.mcr.bak" > "$tmp" || true
  # append our fields (skip comment lines)
  grep -Ev '^\s*#' "$fields" | grep -E '=' >> "$tmp"
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
}

neofetch_configs() {
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s install neofetch config for root + /etc/skel + existing users\n' "$(_c "$C_GREY" "(dry-run)")"
    return 0
  fi
  local conf="$ETC_DIR/neofetch.conf" u home
  for home in /root /etc/skel $(awk -F: '($3>=1000)&&($7!~/nologin|false/){print $6}' /etc/passwd 2>/dev/null); do
    [ -d "$home" ] || continue
    mkdir -p "$home/.config/neofetch"
    cp "$conf" "$home/.config/neofetch/config.conf"
  done
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
mkdir_p_run() { for d in "$@"; do run_sh "mkdir -p '$d'"; done; }

write_regular_file() { # path content (0644)
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s write %s\n' "$(_c "$C_GREY" "(dry-run)")" "$1"; return 0
  fi
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; chmod 0644 "$1"
}

primary_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
    || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

main "$@"
