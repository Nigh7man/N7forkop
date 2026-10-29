#!/bin/sh
# Prepare a private, reversible NetShift 0.9.6 -> N7forkop preview.
# Never installs a package, changes the running config, or controls services.
set -eu
umask 077
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MIGRATOR="$BASE/forkop/files/usr/lib/config/netshift_migration.uc"
LIB="$BASE/forkop/files/usr/lib"
[ "$(id -u)" = "0" ] || { echo "Run as root on the OpenWrt router" >&2; exit 1; }
[ -r /etc/config/netshift ] || { echo "No /etc/config/netshift" >&2; exit 1; }
command -v ucode >/dev/null 2>&1 || { echo "ucode required" >&2; exit 1; }
command -v uci >/dev/null 2>&1 || { echo "uci required" >&2; exit 1; }

if command -v opkg >/dev/null 2>&1; then
  if ! opkg list-installed netshift 2>/dev/null | grep -Eq '^netshift - 0\.9\.6(-| |$)'; then
    echo "This migrator was tested for NetShift 0.9.6 only. Aborting." >&2
    exit 1
  fi
fi
STAGE=$(mktemp -d /root/n7forkop-netshift-XXXXXXXX)
chmod 0700 "$STAGE"
echo "Local staging directory: $STAGE"
if ! ucode -L "$LIB" "$MIGRATOR" plan >"$STAGE/plan.json"; then
  echo "Migration has BLOCKERS. View $STAGE/plan.json; nothing was modified." >&2
  exit 2
fi
if ! ucode -L "$LIB" "$MIGRATOR" render >"$STAGE/forkop.pending"; then
  rm -f "$STAGE/forkop.pending"
  echo "Render failed; nothing was modified." >&2
  exit 3
fi
mv "$STAGE/forkop.pending" "$STAGE/forkop"
# Parse test against generated package in a private temporary UCI directory.
if ! uci -c "$STAGE" -q show forkop >/dev/null; then
  echo "UCI parse failed; no live changes." >&2
  exit 3
fi
cp -p /etc/config/netshift "$STAGE/netshift.original"
[ ! -r /opt/zapret/config ] || cp -p /opt/zapret/config "$STAGE/zapret.original"
if [ -d /opt/zapret ]; then
  ZAPRET_PATHS="opt/zapret/config"
  for item in opt/zapret/ipset opt/zapret/ipset_def opt/zapret/files/fake; do
    [ ! -e "/$item" ] || ZAPRET_PATHS="$ZAPRET_PATHS $item"
  done
  # Unquoted list expansion is intentional: hardcoded, no user-provided paths.
  tar -czf "$STAGE/zapret-files.tar.gz" -C / $ZAPRET_PATHS
fi
if command -v nft >/dev/null 2>&1; then
  nft list ruleset > "$STAGE/nft-before.txt" 2>/dev/null || true
fi
if command -v sysupgrade >/dev/null 2>&1; then
  if ! sysupgrade -b "$STAGE/openwrt-backup.tar.gz" >/dev/null 2>&1; then
    echo "WARNING: sysupgrade backup failed; no cutover without full backup." >&2
    exit 3
  fi
fi
printf '%s\n' "STAGED; NetShift, Zapret, firewall, dnsmasq and sing-box are unchanged."
printf '%s\n' "PLAN=$STAGE/plan.json"
printf '%s\n' "PREVIEW=$STAGE/forkop"
printf '%s\n' "BACKUP=$STAGE/openwrt-backup.tar.gz"
printf '%s\n' "ZAPRET_BACKUP=$STAGE/zapret-files.tar.gz"
printf '%s\n' "Read docs/N7FORKOP-NETSHIFT-MIGRATION.md before any installation."
