#!/usr/bin/env bash
# Installs gpu-rebar.sh and the systemd service. Run as root.
set -eu

[[ $EUID -eq 0 ]] || { echo "Must be run as root" >&2; exit 1; }
SRC=$(dirname "$(readlink -f "$0")")

install -m 0755 "$SRC/gpu-rebar.sh"      /usr/local/sbin/gpu-rebar.sh
install -m 0644 "$SRC/gpu-rebar.service" /etc/systemd/system/gpu-rebar.service
# Do not overwrite an existing config
[[ -e /etc/default/gpu-rebar ]] || install -m 0644 "$SRC/gpu-rebar.default" /etc/default/gpu-rebar

systemctl daemon-reload
systemctl enable gpu-rebar.service

cat <<MSG
Installed. Next steps:
  1. Edit DEFAULT_DEVICES in /usr/local/sbin/gpu-rebar.sh (or set GPU_REBAR_ARGS in /etc/default/gpu-rebar)
  2. Dry run:   gpu-rebar.sh -n
  3. Test now:  systemctl start gpu-rebar.service && journalctl -u gpu-rebar.service -b --no-pager
  4. Reboot and verify:  journalctl -u gpu-rebar.service -b
MSG
