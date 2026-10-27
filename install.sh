#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install (or remove) huawei-turbo-charge: the command, a udev rule that fires
# on charger plug-in, and a systemd unit that also runs at boot and on resume.
#
# Usage: sudo ./install.sh [--dry-run] [--no-start] [--uninstall]
# Env:   PREFIX (default /usr/local), DESTDIR (staged install for packaging;
#        skips every systemctl/udevadm action).
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
BINDIR=$PREFIX/bin
RULE=/etc/udev/rules.d/60-huawei-turbo-charge.rules
UNIT=/etc/systemd/system/huawei-turbo-charge.service

dry_run=0
start=1
uninstall=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --no-start) start=0 ;;
    --uninstall) uninstall=1 ;;
    -h | --help)
      sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

run() {
  if ((dry_run)); then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

if ((!dry_run && EUID != 0)); then
  echo "must run as root (try: sudo $0 $*)" >&2
  exit 1
fi

system_actions() { [[ -z $DESTDIR ]]; }

if ((uninstall)); then
  if system_actions; then
    run systemctl disable --now huawei-turbo-charge.service || true
  fi
  run rm -f "$DESTDIR$BINDIR/huawei-turbo-charge" "$DESTDIR$RULE" "$DESTDIR$UNIT"
  if system_actions; then
    run systemctl daemon-reload
    run udevadm control --reload
  fi
  echo "huawei-turbo-charge removed"
  exit 0
fi

run install -d -m 0755 "$DESTDIR$BINDIR" "$DESTDIR$(dirname "$RULE")" "$DESTDIR$(dirname "$UNIT")"
run install -o root -g root -m 0755 "$here/huawei-turbo-charge" "$DESTDIR$BINDIR/huawei-turbo-charge"
run install -o root -g root -m 0644 "$here/60-huawei-turbo-charge.rules" "$DESTDIR$RULE"
if ((dry_run)); then
  printf '[dry-run] render unit with BINDIR=%s -> %s\n' "$BINDIR" "$DESTDIR$UNIT"
else
  sed "s|@BINDIR@|$BINDIR|g" "$here/huawei-turbo-charge.service" |
    install -o root -g root -m 0644 /dev/stdin "$DESTDIR$UNIT"
fi

if system_actions; then
  run systemctl daemon-reload
  run udevadm control --reload
  run systemctl enable huawei-turbo-charge.service
  if ((start)); then
    run systemctl start huawei-turbo-charge.service
  fi
fi
echo "huawei-turbo-charge installed (command: $BINDIR/huawei-turbo-charge)"
