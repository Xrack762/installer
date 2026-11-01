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

# ---- locate installer/support files -----------------------------------------
SELF_SRC="${BASH_SOURCE[0]:-$0}"
SELF_REAL="$(readlink -f "$SELF_SRC" 2>/dev/null || printf '%s' "$SELF_SRC")"
SCRIPT_DIR="$(cd "$(dirname "$SELF_REAL")" 2>/dev/null && pwd || printf '')"
MCR_SUITE_DIR="${MCR_SRC_DIR:-$SCRIPT_DIR}"
LIB_DIR=""
BRANDING_DIR=""

# Support both a complete source checkout and files already installed system-wide.
# This prevents failures such as "Missing /root/lib/distro.sh" when the libraries
# were previously installed in /usr/local/lib/mcrsoft.
resolve_support_files() {
  local candidate
  for candidate in "$MCR_SUITE_DIR/lib" "$SCRIPT_DIR/lib" /usr/local/lib/mcrsoft; do
    if [ -r "$candidate/ui.sh" ] && [ -r "$candidate/distro.sh" ]; then
      LIB_DIR="$candidate"
      break
    fi
  done

  for candidate in "$MCR_SUITE_DIR/branding" "$SCRIPT_DIR/branding" "$ETC_DIR/branding-src"; do
    if [ -d "$candidate" ] && [ -r "$candidate/logo.txt" ]; then
      BRANDING_DIR="$candidate"
      break
    fi
  done

  if [ -z "$LIB_DIR" ]; then
    echo "Cannot find ui.sh and distro.sh. Checked: $MCR_SUITE_DIR/lib, $SCRIPT_DIR/lib, /usr/local/lib/mcrsoft" >&2
    return 1
  fi
  return 0
}

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
# WordPress / MCR app deployment
OPT_SITE_URL=""
OPT_ADMIN_USER=""
OPT_ADMIN_PASS=""
OPT_ADMIN_EMAIL=""
OPT_SITE_TITLE=""

# Set when we generate an admin password (printed once in the summary, never logged).
GENERATED_ADMIN_USER=""
GENERATED_ADMIN_PASS=""

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
  --site-url <url>    Full site URL (default http://<server-ip>, https://<domain> if --domain)
  --site-title <t>    WordPress site title (default "MCR")
  --admin-user <u>    WP admin username (default admin)
  --admin-pass <p>    WP admin password (default: a strong random one, printed once)
  --admin-email <e>   WP admin email (default admin@<domain|example.com>)
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
      --site-url) OPT_SITE_URL="${2:-}"; shift 2 ;;
      --site-url=*) OPT_SITE_URL="${1#*=}"; shift ;;
      --site-title) OPT_SITE_TITLE="${2:-}"; shift 2 ;;
      --site-title=*) OPT_SITE_TITLE="${1#*=}"; shift ;;
      --admin-user) OPT_ADMIN_USER="${2:-}"; shift 2 ;;
      --admin-user=*) OPT_ADMIN_USER="${1#*=}"; shift ;;
      --admin-pass) OPT_ADMIN_PASS="${2:-}"; shift 2 ;;
      --admin-pass=*) OPT_ADMIN_PASS="${1#*=}"; shift ;;
      --admin-email) OPT_ADMIN_EMAIL="${2:-}"; shift 2 ;;
      --admin-email=*) OPT_ADMIN_EMAIL="${1#*=}"; shift ;;
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

  resolve_support_files || exit 1
  # shellcheck source=lib/ui.sh
  [ -r "$LIB_DIR/ui.sh" ] || { echo "Missing $LIB_DIR/ui.sh" >&2; exit 1; }
  # shellcheck source=lib/distro.sh
  [ -r "$LIB_DIR/distro.sh" ] || { echo "Missing $LIB_DIR/distro.sh" >&2; exit 1; }
  . "$LIB_DIR/ui.sh"
  . "$LIB_DIR/distro.sh"

  ui_init
  ui_log_init "${MCR_LOG_FILE:-$LOG_FILE}"
  _logline "===== MCR Server OS installer v$MCR_VERSION start (dry-run=$OPT_DRYRUN) ====="

  if [ -n "$BRANDING_DIR" ] && [ -r "$BRANDING_DIR/logo.txt" ]; then
    ui_banner "$BRANDING_DIR/logo.txt"
  else
    ui_note "Branding logo not found; continuing without the banner"
  fi
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

  ui_steps_total 11

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

  # ---- 6. WordPress + MCR app ----------------------------------------------
  ui_step_begin "Deploy WordPress + MCR app"
  do_deploy_wordpress || { ui_step_end 1; die "WordPress/app deployment failed"; }
  ui_step_end 0

  # ---- 7. web server vhost --------------------------------------------------
  ui_step_begin "Configure web server (vhost)"
  do_vhost || { ui_step_end 1; die "web server vhost configuration failed"; }
  ui_step_end 0

  # ---- 8. branding ----------------------------------------------------------
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
  local site; site="$(site_url)"
  ui_summary "Installation complete — MCRSOFT BY WOBOO.IO" \
    "Site URL     : $site" \
    "WP admin     : ${site%/}/wp-admin/" \
    "Web root     : $WWW_DIR" \
    "Secrets      : $SECRETS_ENV (chmod 600)" \
    "Admin CLI    : mcrctl status" \
    "Branding     : neofetch / fastfetch now show 'MCRSOFT BY WOBOO.IO'" \
    "Fleet agent  : systemctl status mcr-agent.timer" \
    "Install log  : ${MCR_LOG_FILE:-$LOG_FILE}"
  if [ -n "$GENERATED_ADMIN_PASS" ]; then
    ui_box "WordPress admin login (shown ONCE — save it now)" \
      "URL      : ${site%/}/wp-admin/" \
      "Username : $GENERATED_ADMIN_USER" \
      "Password : $GENERATED_ADMIN_PASS"
    ui_note "This password was generated and is NOT written to the install log. Store it securely."
  fi
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

  # Ensure the app/service user exists. The WordPress deploy step (next) lays
  # down WP + the MCR plugin/theme and sets final ownership.
  run_sh "id mcrsoft >/dev/null 2>&1 || useradd --system --home '$APP_ROOT' --shell /usr/sbin/nologin mcrsoft || true"
}

# =============================================================================
#  WordPress + MCR app deployment
# =============================================================================
# site_url : the canonical site URL. --site-url wins; else https://<domain>
# (unless --no-tls) ; else http://<primary-ip>.
site_url() {
  if [ -n "$OPT_SITE_URL" ]; then printf '%s' "$OPT_SITE_URL"; return 0; fi
  if [ -n "$OPT_DOMAIN" ]; then
    if [ "$OPT_NO_TLS" != "1" ]; then printf 'https://%s' "$OPT_DOMAIN"; else printf 'http://%s' "$OPT_DOMAIN"; fi
    return 0
  fi
  printf 'http://%s' "$(primary_ip)"
}

# wp_cmd : wp-cli invocation for our web root, allow-root (we run as root then chown).
WP() { run wp --path="$WWW_DIR" "$@" --allow-root; }

# wp_done <cmd...> : true if an idempotency check passes. In --dry-run it always
# returns false so the full deploy flow is exercised/printed.
wp_done() {
  [ "$OPT_DRYRUN" = "1" ] && return 1
  "$@" >/dev/null 2>&1
}

# resolve_bundle : echo the app bundle path/URL to use, or empty.
resolve_bundle() {
  local b="${MCR_APP_BUNDLE:-}"
  if [ -z "$b" ]; then
    local src="${MCR_SRC_DIR:-$SCRIPT_DIR}" cand
    for cand in "$src/mcr-app.tar.gz" "$src/../mcr-app.tar.gz" "./mcr-app.tar.gz"; do
      [ -f "$cand" ] && { b="$cand"; break; }
    done
  fi
  printf '%s' "$b"
}

do_deploy_wordpress() {
  local bundle; bundle="$(resolve_bundle)"
  local site; site="$(site_url)"

  ensure_wp_cli || { ui_warn "could not install wp-cli; skipping WordPress deploy"; return 0; }

  # 1. WordPress core files
  if wp_done test -f "$WWW_DIR/wp-load.php"; then
    ui_note "WordPress core already present; skipping download"
  else
    WP core download --locale=fr_FR || WP core download || { ui_error "wp core download failed"; return 1; }
  fi

  # 2. wp-config.php from secrets.env (DB creds + salts never logged/printed)
  write_wp_config "$site" || return 1

  # 3. MCR plugin + theme from the bundle
  if [ -n "$bundle" ]; then
    deploy_bundle "$bundle" "${MCR_APP_BUNDLE_SHA256:-}" || return 1
    # safety net: if the plugin vendor/ is missing, build it
    if [ "$OPT_DRYRUN" != "1" ] && [ ! -f "$WWW_DIR/wp-content/plugins/mcr-rental-core/vendor/autoload.php" ]; then
      ui_warn "plugin vendor/ missing from bundle; running composer install (safety net)"
      ensure_composer && run_sh "cd '$WWW_DIR/wp-content/plugins/mcr-rental-core' && composer install --no-dev --prefer-dist --no-interaction" \
        || ui_warn "composer fallback failed; mPDF/PDF export may not work"
    fi
  else
    ui_warn "No app bundle (MCR_APP_BUNDLE / ./mcr-app.tar.gz); installing vanilla WordPress only"
  fi

  # 4. Install WordPress (admin password never logged)
  do_wp_install "$site" || { ui_error "wp core install failed"; return 1; }

  # 5. Activate + configure (tolerant: warn and continue on any sub-step)
  local title="${OPT_SITE_TITLE:-MCR}"
  if [ -n "$bundle" ]; then
    WP theme activate mcr-premium || ui_warn "could not activate theme mcr-premium"
    WP plugin activate mcr-rental-core || ui_warn "could not activate plugin mcr-rental-core"
  fi
  WP rewrite structure '/%postname%/' --hard || ui_warn "could not set permalinks"
  WP rewrite flush --hard || ui_warn "could not flush rewrite rules"
  WP option update timezone_string 'Africa/Casablanca' || ui_warn "could not set timezone"
  WP language core install fr_FR || ui_note "fr_FR language may already be installed"
  WP site switch-language fr_FR || ui_warn "could not switch site language to fr_FR"
  WP option update blogname "$title" || ui_warn "could not set site title"
  # MCR pages/menus (command provided by the plugin's includes/class-cli.php)
  if [ -n "$bundle" ]; then
    WP mcr setup-pages || ui_warn "wp mcr setup-pages failed (run manually later)"
  fi

  # 6. Ownership: php-fpm user owns the tree (WP writes uploads; web server
  # reads static files via o+rx). MCR_PRIVATE_DIR lives outside the web root.
  local wu; wu="$(web_runtime_user "$OPT_WEB")"
  mkdir_p_run "$DATA_DIR/private"
  run_sh "chown -R '$wu':'$wu' '$WWW_DIR' 2>/dev/null || true"
  run_sh "chown -R '$wu':'$wu' '$DATA_DIR/private' 2>/dev/null || true"
  run_sh "chmod 2775 '$WWW_DIR' 2>/dev/null || true"
  ui_note "web root owned by '$wu' (php-fpm user); private dir at $DATA_DIR/private"
  return 0
}

ensure_wp_cli() {
  if wp_done command -v wp; then ui_note "wp-cli already installed"; return 0; fi
  run_sh "curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp"
  run_sh "chmod 0755 /usr/local/bin/wp"
}

ensure_composer() {
  if wp_done command -v composer; then return 0; fi
  run_sh "curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer && rm -f /tmp/composer-setup.php"
}

# write_wp_config <site-url> : generate wp-config.php from secrets.env.
# DB credentials and salts are NEVER echoed to stdout or the install log.
write_wp_config() {
  local site="$1" cfg="$WWW_DIR/wp-config.php"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s write %s from %s (DB creds + salts redacted; WP_HOME/WP_SITEURL=%s; MCR_PRIVATE_DIR=%s)\n' \
      "$(_c "$C_GREY" "(dry-run)")" "$cfg" "$SECRETS_ENV" "$site" "$DATA_DIR/private"
    _logline "WRITE wp-config.php from secrets.env [db creds + salts redacted]"
    return 0
  fi
  [ -r "$SECRETS_ENV" ] || { ui_error "secrets.env missing; cannot write wp-config.php"; return 1; }
  # shellcheck disable=SC1090
  . "$SECRETS_ENV"
  local k_auth k_sauth k_login k_nonce s_auth s_sauth s_login s_nonce
  k_auth="$(rand_secret 64)";  k_sauth="$(rand_secret 64)"
  k_login="$(rand_secret 64)"; k_nonce="$(rand_secret 64)"
  s_auth="$(rand_secret 64)";  s_sauth="$(rand_secret 64)"
  s_login="$(rand_secret 64)"; s_nonce="$(rand_secret 64)"
  ( umask 027
    cat > "$cfg" <<PHP
<?php
/* MCR Server OS — generated wp-config.php. DB creds come from $SECRETS_ENV. */
define( 'DB_NAME', '${MCR_DB_NAME}' );
define( 'DB_USER', '${MCR_DB_USER}' );
define( 'DB_PASSWORD', '${MCR_DB_PASS}' );
define( 'DB_HOST', '${MCR_DB_HOST:-127.0.0.1}' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define( 'AUTH_KEY',         '${k_auth}' );
define( 'SECURE_AUTH_KEY',  '${k_sauth}' );
define( 'LOGGED_IN_KEY',    '${k_login}' );
define( 'NONCE_KEY',        '${k_nonce}' );
define( 'AUTH_SALT',        '${s_auth}' );
define( 'SECURE_AUTH_SALT', '${s_sauth}' );
define( 'LOGGED_IN_SALT',   '${s_login}' );
define( 'NONCE_SALT',       '${s_nonce}' );

\$table_prefix = 'wp_';

define( 'WP_HOME', '${site}' );
define( 'WP_SITEURL', '${site}' );

/* MCR: private documents live OUTSIDE the web root. Standalone web mode:
   MCR_APP is intentionally NOT defined, so the plugin licence gate runs
   unlocked (not enforcing) for this deployment. */
define( 'MCR_PRIVATE_DIR', '${DATA_DIR}/private' );

define( 'WP_DEBUG', false );
define( 'FS_METHOD', 'direct' );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP
  )
  chmod 0640 "$cfg"
  _logline "WRITE wp-config.php (DB creds + salts redacted)"
  ui_note "wrote wp-config.php (DB creds from secrets.env; salts generated; both redacted)"
}

# do_wp_install <site-url> : wp core install. Admin password is never logged.
do_wp_install() {
  local site="$1"
  if wp_done wp --path="$WWW_DIR" core is-installed --allow-root; then
    ui_note "WordPress already installed; skipping core install"
    return 0
  fi
  local title="${OPT_SITE_TITLE:-MCR}"
  local user="${OPT_ADMIN_USER:-admin}"
  local email="${OPT_ADMIN_EMAIL:-admin@${OPT_DOMAIN:-example.com}}"
  local pass="$OPT_ADMIN_PASS"
  if [ -z "$pass" ]; then
    pass="$(rand_secret 20)"
    GENERATED_ADMIN_USER="$user"
    GENERATED_ADMIN_PASS="$pass"
  fi
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s wp core install --url=%s --title=%s --admin_user=%s --admin_password=<redacted> --admin_email=%s\n' \
      "$(_c "$C_GREY" "(dry-run wp)")" "$site" "$title" "$user" "$email"
    _logline "RUN wp core install --url=$site (admin_password redacted)"
    return 0
  fi
  _logline "RUN wp core install --url=$site (admin_password redacted)"
  wp --path="$WWW_DIR" core install \
    --url="$site" --title="$title" \
    --admin_user="$user" --admin_password="$pass" --admin_email="$email" \
    --skip-email --allow-root
}

# deploy_bundle <path-or-url> <sha256> : unpack the MCR plugin+theme bundle into
# wp-content. Supports .tar.gz (preferred) and .zip. sha256-verified when given.
deploy_bundle() {
  local src="$1" want="$2" tmp="/tmp/mcr-bundle.$$" ext="tar.gz"
  case "$src" in *.zip) ext="zip" ;; esac
  mkdir_p_run "$tmp"
  case "$src" in
    http://*|https://*) run_sh "curl -fsSL '$src' -o '$tmp/bundle.$ext'" ;;
    *) run_sh "cp '$src' '$tmp/bundle.$ext'" ;;
  esac
  if [ -n "$want" ]; then
    if [ "$OPT_DRYRUN" = "1" ]; then
      ui_note "(dry-run) would verify sha256=$want"
    else
      local got; got="$(sha256sum "$tmp/bundle.$ext" | awk '{print $1}')"
      if [ "$got" != "$want" ]; then
        ui_error "Bundle sha256 mismatch (want $want got $got)"; return 1
      fi
      ui_note "bundle sha256 verified"
    fi
  else
    ui_warn "No sha256 given for bundle; cannot verify integrity"
  fi
  mkdir_p_run "$WWW_DIR/wp-content/plugins" "$WWW_DIR/wp-content/themes" "$tmp/x"
  if [ "$ext" = "zip" ]; then
    run_sh "unzip -oq '$tmp/bundle.$ext' -d '$tmp/x'"
  else
    run_sh "tar -xzf '$tmp/bundle.$ext' -C '$tmp/x'"
  fi
  # Bundle layout: plugins/<slug>/..., themes/<slug>/...
  run_sh "cp -a '$tmp/x/plugins/.' '$WWW_DIR/wp-content/plugins/' 2>/dev/null || true"
  run_sh "cp -a '$tmp/x/themes/.'  '$WWW_DIR/wp-content/themes/'  2>/dev/null || true"
  run_sh "rm -rf '$tmp'"
  ui_note "deployed MCR plugin + theme into wp-content"
}

# =============================================================================
#  Web server vhost (serves WordPress + PHP via php-fpm)
# =============================================================================
# install_vhost_file <path> <content> : write a vhost. In --dry-run it prints
# the full rendered config (so tests can grep directives + the fastcgi target).
install_vhost_file() {
  local path="$1" content="$2"
  if [ "$OPT_DRYRUN" = "1" ]; then
    printf '      %s vhost -> %s\n' "$(_c "$C_GREY" "(dry-run)")" "$path"
    printf '%s\n' "$content" | sed 's/^/        | /'
    _logline "WRITE vhost $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod 0644 "$path"
}

do_vhost() {
  local server_name="${OPT_DOMAIN:-$(primary_ip)}"
  if [ "$OPT_WEB" = "apache" ]; then
    vhost_apache "$server_name"
  else
    vhost_nginx "$server_name"
  fi
}

vhost_nginx() {
  local server_name="$1" listen conf content
  listen="$(php_fpm_listen)"
  content="$(cat <<EOF
# MCR Server OS — WordPress vhost (nginx + php-fpm)
server {
    listen 80;
    listen [::]:80;
    server_name $server_name;
    root $WWW_DIR;
    index index.php index.html;

    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass $listen;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }
    location ~* /\.(?!well-known).* { deny all; }
    location ~* /wp-content/.*\.php\$ { deny all; }
}
EOF
)"
  case "$PKG_FAMILY" in
    deb)
      conf="/etc/nginx/sites-available/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      run_sh "ln -sf '$conf' /etc/nginx/sites-enabled/mcrsoft.conf"
      run_sh "rm -f /etc/nginx/sites-enabled/default"
      ;;
    *)
      conf="/etc/nginx/conf.d/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      # neutralise the distro default server block if present
      run_sh "[ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled || true"
      ;;
  esac
  ui_note "nginx vhost written to $conf (fastcgi_pass $listen)"
  run nginx -t || ui_warn "nginx -t reported a problem; review $conf"
  run systemctl reload "$(svc_name web-nginx)" || run systemctl restart "$(svc_name web-nginx)" || ui_note "reload nginx manually"
}

vhost_apache() {
  local server_name="$1" listen conf content proxy
  listen="$(php_fpm_listen)"
  # Apache proxies .php to php-fpm (SetHandler). For unix sockets use the
  # unix:/path|fcgi://localhost form; for host:port use fcgi://host:port.
  case "$listen" in
    unix:*) proxy="unix:${listen#unix:}|fcgi://localhost" ;;
    *)      proxy="fcgi://$listen" ;;
  esac
  content="$(cat <<EOF
# MCR Server OS — WordPress vhost (apache + php-fpm via mod_proxy_fcgi)
<VirtualHost *:80>
    ServerName $server_name
    DocumentRoot $WWW_DIR
    DirectoryIndex index.php index.html

    <Directory $WWW_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php\$>
        SetHandler "proxy:$proxy"
    </FilesMatch>

    <FilesMatch "^\.ht">
        Require all denied
    </FilesMatch>
</VirtualHost>
EOF
)"
  case "$PKG_FAMILY" in
    deb)
      conf="/etc/apache2/sites-available/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      run_sh "a2enmod proxy proxy_fcgi rewrite >/dev/null 2>&1 || true"
      run_sh "a2ensite mcrsoft >/dev/null 2>&1 || ln -sf '$conf' /etc/apache2/sites-enabled/mcrsoft.conf"
      run_sh "a2dissite 000-default >/dev/null 2>&1 || rm -f /etc/apache2/sites-enabled/000-default.conf"
      ;;
    suse)
      conf="/etc/apache2/vhosts.d/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      ;;
    arch)
      conf="/etc/httpd/conf/extra/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      run_sh "grep -q 'extra/mcrsoft.conf' /etc/httpd/conf/httpd.conf 2>/dev/null || printf '\nInclude conf/extra/mcrsoft.conf\n' >> /etc/httpd/conf/httpd.conf"
      ;;
    *)
      conf="/etc/httpd/conf.d/mcrsoft.conf"
      install_vhost_file "$conf" "$content"
      ;;
  esac
  ui_note "apache vhost written to $conf (php-fpm $listen)"
  run "$(svc_name web-apache)" -t 2>/dev/null || run apachectl configtest || ui_warn "apache config test reported a problem; review $conf"
  run systemctl reload "$(svc_name web-apache)" || run systemctl restart "$(svc_name web-apache)" || ui_note "reload apache manually"
}

do_branding() {
  local required
  install_mcrctl_now
  if [ -z "$BRANDING_DIR" ]; then
    ui_warn "Branding assets were not found; skipping branding instead of aborting installation"
    return 0
  fi
  for required in logo.txt mcrsoft-release fastfetch.jsonc neofetch.conf motd profile.d-mcrsoft.sh os-release.fields; do
    if [ ! -r "$BRANDING_DIR/$required" ]; then
      ui_warn "Branding asset $required is missing; skipping branding"
      return 0
    fi
  done
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
  local src="$MCR_SUITE_DIR"
  install_mcrctl_now

  # Keep an already-installed agent if this is a partial installer directory.
  if [ -r "$src/mcr-agent" ]; then
    run_sh "install -m 0755 '$src/mcr-agent' /usr/local/bin/mcr-agent"
  elif [ ! -x /usr/local/bin/mcr-agent ] && [ "$OPT_DRYRUN" != "1" ]; then
    ui_warn "mcr-agent source and installed binary are both missing; skipping agent install"
  fi

  write_regular_file "$ETC_DIR/fleet.pub" "$MCR_FLEET_PUBKEY_DEFAULT"

  if [ -d "$src/systemd" ]; then
    [ ! -r "$src/systemd/mcr-agent.service" ] || run_sh "install -m 0644 '$src/systemd/mcr-agent.service' /etc/systemd/system/mcr-agent.service"
    [ ! -r "$src/systemd/mcr-agent.timer" ] || run_sh "install -m 0644 '$src/systemd/mcr-agent.timer' /etc/systemd/system/mcr-agent.timer"
    [ ! -r "$src/systemd/mcr-web.service" ] || run_sh "install -m 0644 '$src/systemd/mcr-web.service' /etc/systemd/system/mcr-web.service"
    run systemctl daemon-reload || true
    if [ -r "$src/systemd/mcr-agent.timer" ]; then
      run systemctl enable --now mcr-agent.timer || ui_note "enable mcr-agent.timer later (needs enrollment)"
    fi
  else
    ui_note "No systemd unit directory in source; keeping any existing units"
  fi
  return 0
}

install_mcrctl_now() {
  local src="$MCR_SUITE_DIR"
  if [ ! -x /usr/local/bin/mcrctl ]; then
    if [ -r "$src/mcrctl" ]; then
      run_sh "install -m 0755 '$src/mcrctl' /usr/local/bin/mcrctl"
    elif [ "$OPT_DRYRUN" != "1" ]; then
      ui_warn "mcrctl source is missing and /usr/local/bin/mcrctl is not installed"
    fi
  fi

  # Make the selected libraries and branding available to system tools.
  mkdir_p_run /usr/local/lib/mcrsoft "$ETC_DIR"
  if [ -n "$LIB_DIR" ]; then
    run_sh "install -m 0644 '$LIB_DIR/ui.sh' '$LIB_DIR/distro.sh' /usr/local/lib/mcrsoft/"
  fi
  if [ -n "$BRANDING_DIR" ] && [ -d "$BRANDING_DIR" ]; then
    run_sh "mkdir -p '$ETC_DIR/branding-src' && cp -a '$BRANDING_DIR/.' '$ETC_DIR/branding-src/'"
  fi
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
