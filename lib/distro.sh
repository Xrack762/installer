#!/usr/bin/env bash
# lib/distro.sh — universal distro detection + package name map.
# Sourced by install.sh / mcrctl / mcr-agent. No side effects on source.
#
# Exposes, after distro_detect():
#   DISTRO_ID        normalized family: debian|ubuntu|rhel|fedora|arch|suse|alpine
#   DISTRO_ID_RAW    the /etc/os-release ID
#   DISTRO_LIKE      /etc/os-release ID_LIKE
#   DISTRO_VERSION   VERSION_ID
#   PKG              package manager binary: apt-get|dnf|yum|zypper|pacman|apk
#   PKG_FAMILY       deb|rpm|arch|suse|alpine
#   ARCH             x86_64|aarch64
# And maps PKG_* install command + package name helpers.

# Allow a fake os-release for testing: MCR_OSRELEASE_FILE overrides the path.
_osrelease_file() { printf '%s' "${MCR_OSRELEASE_FILE:-/etc/os-release}"; }

distro_detect() {
  local osr; osr="$(_osrelease_file)"
  DISTRO_ID_RAW=""; DISTRO_LIKE=""; DISTRO_VERSION=""
  if [ -r "$osr" ]; then
    # Parse without sourcing (avoid executing arbitrary content).
    DISTRO_ID_RAW="$(_osr_get "$osr" ID)"
    DISTRO_LIKE="$(_osr_get "$osr" ID_LIKE)"
    DISTRO_VERSION="$(_osr_get "$osr" VERSION_ID)"
  fi

  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) : ;;  # unsupported arch handled by caller
  esac

  # Classify family by ID, then ID_LIKE, then package-manager probe.
  DISTRO_ID=""
  case "$DISTRO_ID_RAW" in
    debian) DISTRO_ID="debian" ;;
    ubuntu|linuxmint|pop|elementary|zorin|neon|raspbian|kali|devuan) DISTRO_ID="ubuntu" ;;
    fedora) DISTRO_ID="fedora" ;;
    rhel|centos|rocky|almalinux|ol|oracle|scientific|cloudlinux) DISTRO_ID="rhel" ;;
    arch|archarm|manjaro|manjaro-arm|endeavouros|garuda|artix) DISTRO_ID="arch" ;;
    opensuse*|sles|sled|suse|"opensuse-leap"|"opensuse-tumbleweed") DISTRO_ID="suse" ;;
    alpine) DISTRO_ID="alpine" ;;
    *) : ;;
  esac

  if [ -z "$DISTRO_ID" ]; then
    case " $DISTRO_LIKE " in
      *" debian "*|*" ubuntu "*) DISTRO_ID="debian" ;;
      *" fedora "*) DISTRO_ID="fedora" ;;
      *" rhel "*|*" centos "*|*"fedora"*) DISTRO_ID="rhel" ;;
      *" arch "*) DISTRO_ID="arch" ;;
      *" suse "*|*" opensuse "*) DISTRO_ID="suse" ;;
      *" alpine "*) DISTRO_ID="alpine" ;;
    esac
  fi

  # Probe package managers (PATH or test shim).
  PKG=""; PKG_FAMILY=""
  if _has apt-get; then PKG="apt-get"; PKG_FAMILY="deb";
  elif _has dnf; then PKG="dnf"; PKG_FAMILY="rpm";
  elif _has yum; then PKG="yum"; PKG_FAMILY="rpm";
  elif _has zypper; then PKG="zypper"; PKG_FAMILY="suse";
  elif _has pacman; then PKG="pacman"; PKG_FAMILY="arch";
  elif _has apk; then PKG="apk"; PKG_FAMILY="alpine";
  fi

  # If ID gave us a family but no PKG was found on PATH, derive the expected one
  # (keeps --dry-run working when shims are not present).
  if [ -z "$PKG" ] && [ -n "$DISTRO_ID" ]; then
    case "$DISTRO_ID" in
      debian|ubuntu) PKG="apt-get"; PKG_FAMILY="deb" ;;
      fedora) PKG="dnf"; PKG_FAMILY="rpm" ;;
      rhel) PKG="dnf"; PKG_FAMILY="rpm" ;;
      arch) PKG="pacman"; PKG_FAMILY="arch" ;;
      suse) PKG="zypper"; PKG_FAMILY="suse" ;;
      alpine) PKG="apk"; PKG_FAMILY="alpine" ;;
    esac
  fi

  # Last resort: infer ID from PKG.
  if [ -z "$DISTRO_ID" ] && [ -n "$PKG_FAMILY" ]; then
    case "$PKG_FAMILY" in
      deb) DISTRO_ID="debian" ;;
      rpm) DISTRO_ID="rhel" ;;
      arch) DISTRO_ID="arch" ;;
      suse) DISTRO_ID="suse" ;;
      alpine) DISTRO_ID="alpine" ;;
    esac
  fi

  [ -n "$DISTRO_ID" ] && [ -n "$PKG" ]
}

# _osr_get <file> <KEY> : read KEY=value from os-release, strip quotes.
_osr_get() {
  local f="$1" k="$2" line val
  line="$(grep -E "^${k}=" "$f" 2>/dev/null | head -n1)"
  val="${line#*=}"
  # strip surrounding single/double quotes
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

_has() { command -v "$1" >/dev/null 2>&1; }

# distro_supported : 0 if DISTRO_ID + ARCH are supported.
distro_supported() {
  case "$ARCH" in x86_64|aarch64) : ;; *) return 1 ;; esac
  case "$DISTRO_ID" in debian|ubuntu|rhel|fedora|arch|suse|alpine) return 0 ;; *) return 1 ;; esac
}

# distro_human : friendly name
distro_human() {
  printf '%s (%s) %s on %s' "${DISTRO_ID_RAW:-unknown}" "${DISTRO_ID:-?}" \
    "${DISTRO_VERSION:-}" "${ARCH:-?}"
}

# -------------------------------------------------------------------
# Package name map: given a logical component, print the package list
# for the detected family. Components:
#   web-nginx web-apache php phpfpm mariadb tools fetch firewall certbot
# -------------------------------------------------------------------
pkg_names() { # pkg_names <component>
  local comp="$1"
  case "$PKG_FAMILY:$comp" in
    # ---- nginx / apache ----
    deb:web-nginx)    echo "nginx" ;;
    rpm:web-nginx)    echo "nginx" ;;
    suse:web-nginx)   echo "nginx" ;;
    arch:web-nginx)   echo "nginx" ;;
    alpine:web-nginx) echo "nginx" ;;

    deb:web-apache)    echo "apache2 libapache2-mod-php" ;;
    rpm:web-apache)    echo "httpd" ;;
    suse:web-apache)   echo "apache2" ;;
    arch:web-apache)   echo "apache" ;;
    alpine:web-apache) echo "apache2 apache2-proxy" ;;

    # ---- php + fpm + extensions (>=8.1 from distro default) ----
    deb:php)    echo "php-fpm php-cli php-mysql php-gd php-curl php-mbstring php-xml php-zip php-intl php-bcmath" ;;
    rpm:php)    echo "php-fpm php-cli php-mysqlnd php-gd php-curl php-mbstring php-xml php-json php-intl php-bcmath" ;;
    suse:php)   echo "php8 php8-fpm php8-cli php8-mysql php8-gd php8-curl php8-mbstring php8-xml php8-zip php8-intl php8-bcmath" ;;
    arch:php)   echo "php php-fpm php-gd" ;;
    alpine:php) echo "php82 php82-fpm php82-cli php82-mysqli php82-gd php82-curl php82-mbstring php82-xml php82-zip php82-intl php82-bcmath php82-session php82-openssl php82-phar php82-ctype php82-dom php82-fileinfo php82-tokenizer" ;;

    # ---- database (MariaDB) ----
    deb:mariadb)    echo "mariadb-server mariadb-client" ;;
    rpm:mariadb)    echo "mariadb-server mariadb" ;;
    suse:mariadb)   echo "mariadb mariadb-client" ;;
    arch:mariadb)   echo "mariadb" ;;
    alpine:mariadb) echo "mariadb mariadb-client" ;;

    # ---- base tools ----
    deb:tools)    echo "unzip curl git ca-certificates openssl rsync tar gzip" ;;
    rpm:tools)    echo "unzip curl git ca-certificates openssl rsync tar gzip" ;;
    suse:tools)   echo "unzip curl git ca-certificates openssl rsync tar gzip" ;;
    arch:tools)   echo "unzip curl git ca-certificates openssl rsync tar gzip" ;;
    alpine:tools) echo "unzip curl git ca-certificates openssl rsync tar gzip bash coreutils" ;;

    # ---- fastfetch (fallback neofetch handled at runtime) ----
    deb:fetch)    echo "fastfetch" ;;
    rpm:fetch)    echo "fastfetch" ;;
    suse:fetch)   echo "fastfetch" ;;
    arch:fetch)   echo "fastfetch" ;;
    alpine:fetch) echo "fastfetch" ;;

    deb:fetch-fallback)    echo "neofetch" ;;
    rpm:fetch-fallback)    echo "neofetch" ;;
    suse:fetch-fallback)   echo "neofetch" ;;
    arch:fetch-fallback)   echo "neofetch" ;;
    alpine:fetch-fallback) echo "neofetch" ;;

    # ---- firewall ----
    deb:firewall)    echo "ufw" ;;
    rpm:firewall)    echo "firewalld" ;;
    suse:firewall)   echo "firewalld" ;;
    arch:firewall)   echo "ufw" ;;
    alpine:firewall) echo "" ;;  # Alpine uses iptables/awall; skip auto

    # ---- certbot ----
    deb:certbot)    echo "certbot python3-certbot-nginx" ;;
    rpm:certbot)    echo "certbot python3-certbot-nginx" ;;
    suse:certbot)   echo "certbot python3-certbot-nginx" ;;
    arch:certbot)   echo "certbot certbot-nginx" ;;
    alpine:certbot) echo "certbot certbot-nginx" ;;

    *) echo "" ;;
  esac
}

# pkg_install_cmd : print the non-interactive install command prefix for the family.
pkg_install_cmd() {
  case "$PKG_FAMILY" in
    deb)   echo "apt-get install -y --no-install-recommends" ;;
    rpm)   if [ "$PKG" = "dnf" ]; then echo "dnf install -y"; else echo "yum install -y"; fi ;;
    suse)  echo "zypper --non-interactive install --no-recommends" ;;
    arch)  echo "pacman -S --needed --noconfirm" ;;
    alpine) echo "apk add --no-progress" ;;
    *) echo "" ;;
  esac
}

# pkg_update_cmd : refresh repo metadata command.
pkg_update_cmd() {
  case "$PKG_FAMILY" in
    deb)   echo "apt-get update -y" ;;
    rpm)   if [ "$PKG" = "dnf" ]; then echo "dnf makecache -y"; else echo "yum makecache -y"; fi ;;
    suse)  echo "zypper --non-interactive refresh" ;;
    arch)  echo "pacman -Sy --noconfirm" ;;
    alpine) echo "apk update" ;;
    *) echo "" ;;
  esac
}

# svc_name : map a logical service to the distro unit name.
svc_name() { # svc_name <web-nginx|web-apache|phpfpm|mariadb|firewall>
  local s="$1"
  case "$PKG_FAMILY:$s" in
    *:web-nginx) echo "nginx" ;;
    deb:web-apache) echo "apache2" ;;
    rpm:web-apache) echo "httpd" ;;
    suse:web-apache) echo "apache2" ;;
    arch:web-apache) echo "httpd" ;;
    alpine:web-apache) echo "apache2" ;;
    deb:phpfpm) echo "php-fpm" ;;        # Debian aliases to versioned unit
    rpm:phpfpm) echo "php-fpm" ;;
    suse:phpfpm) echo "php-fpm" ;;
    arch:phpfpm) echo "php-fpm" ;;
    alpine:phpfpm) echo "php-fpm82" ;;
    *:mariadb) echo "mariadb" ;;
    deb:firewall) echo "ufw" ;;
    *:firewall) echo "firewalld" ;;
    *) echo "$s" ;;
  esac
}
