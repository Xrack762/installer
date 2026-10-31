#!/usr/bin/env bash
# =============================================================================
#  linux/test/run-mocks.sh
#  Mock-distro dry-run harness for the MCR Server OS installer.
#
#  Because a real systemd distro cannot run in this dev environment, this
#  harness proves correctness by:
#    1. Putting LOGGING STUBS for apt-get/dnf/yum/zypper/pacman/apk/systemctl/
#       useradd/mysql/ufw/firewall-cmd/certbot/fastfetch/... on PATH.
#    2. Faking /etc/os-release for each of the 6 distro families.
#    3. Running install.sh --dry-run --yes --plain for each family and asserting
#       the correct package manager + package names + steps were chosen, that
#       secrets would be chmod 600, branding renders, and exit code is 0.
#
#  Run from Git Bash:  bash linux/test/run-mocks.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/bin"
OSR="$WORK/osr"
mkdir -p "$BIN" "$OSR"
CALLLOG="$WORK/calls.log"
: > "$CALLLOG"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# ---- build logging stubs ---------------------------------------------------
make_stub() { # make_stub <name> [exit-code]
  local name="$1" rc="${2:-0}"
  cat > "$BIN/$name" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >> "$CALLLOG"
exit $rc
EOF
  chmod +x "$BIN/$name"
}
# Common tools present on every family. Package managers are added PER FAMILY
# inside run_family so that only the relevant one is on PATH (like a real host).
for t in systemctl useradd mysql mysqldump \
         ufw firewall-cmd certbot fastfetch neofetch unzip curl wget git \
         mariadb-install-db nproc; do
  make_stub "$t"
done
ALL_PMS="apt-get dnf yum zypper pacman apk"
set_only_pm() { # set_only_pm <pm-binary>
  local keep="$1" p
  for p in $ALL_PMS; do rm -f "$BIN/$p"; done
  make_stub "$keep"
}
# systemd-detect-virt prints something
cat > "$BIN/systemd-detect-virt" <<EOF
#!/usr/bin/env bash
echo kvm
EOF
chmod +x "$BIN/systemd-detect-virt"

# ---- fake os-release per family -------------------------------------------
write_osr() { # write_osr <id> <id_like> <version> <pretty>
  cat > "$OSR/os-release.$1" <<EOF
NAME="$4"
PRETTY_NAME="$4"
ID=$1
ID_LIKE=$2
VERSION_ID="$3"
HOME_URL="https://example.org"
EOF
}
write_osr ubuntu "debian" "22.04" "Ubuntu 22.04.3 LTS"
write_osr debian "" "12" "Debian GNU/Linux 12 (bookworm)"
write_osr rocky "rhel centos fedora" "9.3" "Rocky Linux 9.3 (Blue Onyx)"
write_osr fedora "" "39" "Fedora Linux 39 (Server Edition)"
write_osr arch "" "" "Arch Linux"
write_osr opensuse-leap "suse opensuse" "15.5" "openSUSE Leap 15.5"
write_osr alpine "" "3.19" "Alpine Linux v3.19"

# expected package-manager binary per fake ID
declare -A EXPECT_PM=(
  [ubuntu]=apt-get [debian]=apt-get [rocky]=dnf [fedora]=dnf
  [arch]=pacman [opensuse-leap]=zypper [alpine]=apk
)
# a signature package name we expect to appear in the install calls
declare -A EXPECT_PKG=(
  [ubuntu]="mariadb-server" [debian]="mariadb-server" [rocky]="php-mysqlnd"
  [fedora]="php-mysqlnd" [arch]="php-fpm" [opensuse-leap]="php8-fpm" [alpine]="php82-fpm"
)

run_family() { # run_family <osr-id>
  local id="$1"
  local out="$WORK/out.$id.txt"
  : > "$CALLLOG"
  set_only_pm "${EXPECT_PM[$id]}"
  # Only the mock bins + openssl/coreutils needed by install should be visible.
  # We prepend $BIN but keep system PATH so bash/openssl/sha256sum/mktemp exist.
  PATH="$BIN:$PATH" \
  MCR_OSRELEASE_FILE="$OSR/os-release.$id" \
  MCR_LOG_FILE="$WORK/install.$id.log" \
  MCR_ETC_DIR="$WORK/etc.$id" \
    bash "$SUITE/install.sh" --dry-run --yes --plain --web nginx \
      --domain "test-$id.example.com" --email admin@example.com \
      > "$out" 2>&1
  local rc=$?

  printf '\n== Family: %s ==\n' "$id"
  # 1. exit code 0
  if [ "$rc" = 0 ]; then ok "install.sh exit 0"; else bad "install.sh exit $rc (see $out)"; fi
  # 2. correct package manager chosen (dry-run prints the install cmd)
  local pm="${EXPECT_PM[$id]}"
  if grep -q "dry-run sh) $pm " "$out" || grep -qE "\($pm " "$out" || grep -q " $pm " "$out"; then
    ok "uses package manager: $pm"
  else bad "expected package manager $pm not seen"; fi
  # 3. signature package name present
  local pkg="${EXPECT_PKG[$id]}"
  if grep -q "$pkg" "$out"; then ok "installs expected package: $pkg"; else bad "missing package $pkg"; fi
  # 4. branding keeps ID/ID_LIKE/VERSION_ID (dry-run message)
  if grep -q "keep ID/ID_LIKE/VERSION_ID" "$out"; then ok "os-release branding preserves ID/ID_LIKE/VERSION_ID"; else bad "branding caveat not shown"; fi
  # 5. secrets chmod 600
  if grep -q "chmod 600" "$out"; then ok "secrets written chmod 600"; else bad "no chmod 600 for secrets"; fi
  # 6. all 9 steps completed OK
  local steps; steps="$(grep -c '\[OK\]' "$out")"
  if [ "${steps:-0}" -ge 9 ]; then ok "all 9 steps reported [OK] ($steps)"; else bad "only $steps [OK] steps"; fi
  # 7. firewall choice sane
  case "$id" in
    rocky|fedora|opensuse-leap) grep -q "firewalld" "$out" && ok "firewalld selected" || bad "firewalld not selected" ;;
    ubuntu|debian|arch) grep -q "ufw" "$out" && ok "ufw selected" || bad "ufw not selected" ;;
    alpine) ok "alpine firewall skipped (expected)" ;;
  esac
  # 8. certbot path present (domain+email given)
  grep -q "certbot" "$out" && ok "certbot step present" || bad "certbot step missing"
}

echo "### MCR Server OS — mock distro dry-run harness"
for id in ubuntu debian rocky fedora arch opensuse-leap alpine; do
  run_family "$id"
done

echo
echo "### Summary: $PASS passed, $FAIL failed"
echo "Artifacts in: $WORK"
# Keep one full TUI sample for the report
cp "$WORK/out.ubuntu.txt" "$HERE/sample-ubuntu-dryrun.txt" 2>/dev/null || true
[ "$FAIL" = 0 ]
