#!/usr/bin/env bash
# End-to-end checks on a disposable Linux VM (never a real server): sudo bash tests/e2e.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

conf() { (umask 077; printf '%s\n' "NAME=$(hostname)" "INTERVAL=10" "$@" > /etc/flatline.conf); systemctl restart flatline; }
# wait until `flatline status --json` problems do (or don't) mention $2
expect() {
  local want=$1 text=$2 label=$3
  for _ in $(seq 1 30); do
    if flatline status --json | python3 -c "import json,sys; p=' | '.join(json.load(sys.stdin)['problems']); sys.exit(0 if (sys.argv[1] in p) == (sys.argv[2] == 'yes') else 1)" "$text" "$want"; then
      ok "$label"; return
    fi
    sleep 3
  done
  bad "$label (problems: $(flatline status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["problems"])'))"
}

echo "== install"
bash "$REPO/install.sh" >/dev/null 2>&1 && ok "installs from a clone" || bad "installs from a clone"
d=$(mktemp -d /tmp/fl.XXXX) && chmod 1777 "$d" && cp "$REPO/install.sh" "$REPO/agent/flatline" "$d/"
if bash "$d/install.sh" >/dev/null 2>&1; then bad "refuses an agent others can swap"; else ok "refuses an agent others can swap"; fi
rm -rf "$d"
conf
expect no "failed" "healthy baseline has no problems"

echo "== failures"
systemd-run --quiet --unit=e2e-crash /bin/false; expect yes "e2e-crash.service failed" "crashed systemd service"
systemctl reset-failed e2e-crash.service; expect no "e2e-crash" "recovers when the service is cleared"

conf "DISK_MAX=5"; expect yes "disk above 5%" "disk over the threshold"
conf; expect no "disk above" "recovers when the threshold is back"

conf "PEERS=ghost=10.255.255.1:22,self=[::1]:22"; expect yes "peer ghost unreachable" "unreachable peer (and IPv6 peer parses)"
conf; expect no "peer" "recovers when the peer is removed"

python3 - <<'PY' &
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 8099)); s.listen(5)
while True:  # a server that trickles one byte every 5 s and never finishes the response
    c, _ = s.accept()
    for _ in range(40):
        try: c.send(b"H"); time.sleep(5)
        except OSError: break
PY
slow=$!
conf "SITES=http://user:secret@127.0.0.1:8099/health?token=abc"
expect yes "site 127.0.0.1/health down" "slow site is reported, not a frozen agent"
flatline status --json | grep -q secret && bad "credentials leak into state" || ok "no credentials in the state"
before=$(python3 -c 'import json; print(json.load(open("/var/lib/flatline/state.json"))["time"])'); sleep 45
after=$(python3 -c 'import json; print(json.load(open("/var/lib/flatline/state.json"))["time"])')
[ "$after" -gt "$before" ] && ok "checks keep running during the slow site" || bad "checks stalled"
kill $slow; conf

if command -v pm2 >/dev/null; then
  pm2 start /bin/false --name e2e-worker --interpreter none >/dev/null 2>&1
  expect yes "pm2 e2e-worker down" "crashed pm2 app"
  pm2 delete e2e-worker >/dev/null 2>&1; expect no "e2e-worker" "recovers when the app is gone"
fi

if command -v docker >/dev/null; then
  docker run -d --name e2e-sick --health-cmd=false --health-interval=2s --health-retries=1 busybox sleep 1d >/dev/null
  expect yes "docker e2e-sick unhealthy" "unhealthy container"
  docker rm -f e2e-sick >/dev/null; expect no "e2e-sick" "recovers when the container is gone"
  systemctl stop docker.socket docker >/dev/null 2>&1
  expect yes "docker check failed" "docker itself stopped is loud, not silent"
  systemctl start docker >/dev/null 2>&1; expect no "docker check failed" "recovers when docker is back"
fi

echo "== no install, and nothing left behind"
out=$(python3 - status --json --live < "$REPO/agent/flatline")
echo "$out" | grep -q '"agent": false' && ok "reads a server once with nothing installed" || bad "live read"
flatline uninstall >/dev/null
left=$(for p in /usr/local/bin/flatline /etc/flatline.conf /etc/systemd/system/flatline.service /var/lib/flatline /var/lib/flatline-share; do [ -e "$p" ] && echo "$p"; done; id flatline >/dev/null 2>&1 && echo "user flatline")
[ -z "$left" ] && ok "uninstall leaves nothing behind" || bad "uninstall left: $left"
bash "$REPO/install.sh" >/dev/null 2>&1; conf

echo "== resilience and sandbox"
pid=$(systemctl show -p MainPID --value flatline); kill -9 "$pid"; sleep 14
[ "$(systemctl is-active flatline)" = active ] && [ "$(systemctl show -p MainPID --value flatline)" != "$pid" ] && ok "restarts after being killed" || bad "did not restart"
pid=$(systemctl show -p MainPID --value flatline)
ss -Hltnup | grep -q "pid=$pid," && bad "listens on a port" || ok "listens on no port"
[ "$(stat -c %a /etc/flatline.conf)" = 600 ] && ok "config is root-only" || bad "config permissions"
echo "  info  $(systemd-analyze security flatline.service 2>/dev/null | tail -1)"
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
