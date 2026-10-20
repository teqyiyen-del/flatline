#!/usr/bin/env bash
# Flatline agent installer. On each server:
#   curl -fsSL https://github.com/teqyiyen-del/flatline/releases/latest/download/install.sh | sudo bash
# Run it again to update; your config is kept. Pin a release with FLATLINE_VERSION=v0.2.0
set -euo pipefail

main() {  # everything runs from here, so a half-downloaded script can't run half the steps
  local repo="${FLATLINE_REPO:-teqyiyen-del/flatline}" version="${FLATLINE_VERSION:-latest}" src="${BASH_SOURCE[0]:-}"
  local base="https://github.com/$repo/releases/download/$version"
  [ "$version" = latest ] && base="https://github.com/$repo/releases/latest/download"
  [ "$(id -u)" -eq 0 ] || fail "run as root: curl -fsSL $base/install.sh | sudo bash"
  command -v systemctl >/dev/null || fail "needs systemd"
  command -v python3 >/dev/null || fail "needs python3 (apt install python3)"
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || fail "needs python3 3.8 or newer"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  local here="" local_agent=""
  [ -n "$src" ] && here="$(cd "$(dirname "$src")" && pwd)"
  if [ -n "$here" ] && [ -f "$here/flatline" ]; then local_agent="$here/flatline"      # next to a downloaded agent
  elif [ -n "$here" ] && [ -f "$here/agent/flatline" ]; then local_agent="$here/agent/flatline"  # from a clone
  fi
  if [ -n "$local_agent" ]; then
    trusted "$local_agent"  # it is about to run as root
    cp "$local_agent" "$tmp/flatline"
    if [ -f "$here/SHA256SUMS" ]; then
      cp "$here/SHA256SUMS" "$tmp/"
      (cd "$tmp" && grep ' flatline$' SHA256SUMS | sha256sum -c --quiet) || fail "checksum mismatch, nothing changed"
    fi
  else  # piped from curl: take the agent from the same release and check it against the release's checksums
    fetch "$base/flatline" "$tmp/flatline"
    fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
    (cd "$tmp" && grep ' flatline$' SHA256SUMS | sha256sum -c --quiet) || fail "checksum mismatch, nothing changed"
  fi
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$tmp/flatline" || fail "the agent is broken, nothing changed"
  install -m 755 -o root -g root "$tmp/flatline" /usr/local/bin/flatline

  write_unit
  [ -f /etc/flatline.conf ] || flatline setup || echo "Telegram skipped. Connect it later: sudo flatline setup"
  systemctl daemon-reload
  systemctl enable --quiet flatline
  systemctl restart flatline
  echo "flatline $(flatline --version) is running. Check: flatline status · Config: /etc/flatline.conf · Logs: journalctl -u flatline"
}

fail() {
  echo "flatline: $*" >&2
  exit 1
}

trusted() {  # refuse files that another user could have swapped, e.g. anything under /tmp
  local path
  path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  while [ "$path" != "/" ]; do
    if [ -n "$(find "$path" -maxdepth 0 \( -perm -0002 -o \( -perm -0020 ! -group root \) \) 2>/dev/null)" ]; then
      fail "$path can be changed by other users; move the files somewhere private and try again"
    fi
    path="$(dirname "$path")"
  done
}

fetch() {  # HTTPS only, redirects included
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2"
}

write_unit() {  # read-only sandbox: the agent can't change the system even if something goes wrong
  cat > /etc/systemd/system/flatline.service <<'EOF'
[Unit]
Description=Flatline server monitor
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/flatline watch
Environment=HOME=/root
Restart=always
RestartSec=10
StateDirectory=flatline
UMask=0077
CapabilityBoundingSet=
AmbientCapabilities=
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectProc=invisible
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
}

main "$@"
