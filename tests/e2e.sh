#!/usr/bin/env bash
# End-to-end checks on a disposable Linux VM (never a real server): sudo bash tests/e2e.sh
# shellcheck disable=SC2015  # `check && ok || bad` is fine here: ok and bad never fail
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
checked() {  # wait for a check that finishes after now
  local t; t=$(date +%s)
  for _ in $(seq 1 40); do
    sleep 1
    [ "$(python3 -c 'import json; print(json.load(open("/var/lib/flatline/state.json"))["time"])')" -gt "$t" ] && return
  done
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

echo "== must-run services and their logs"
printf '[Service]\nExecStart=/bin/sleep infinity\n' > /etc/systemd/system/e2e-must.service
printf '[Unit]\nStartLimitIntervalSec=0\n[Service]\nExecStart=/bin/false\nRestart=always\nRestartSec=1\n' > /etc/systemd/system/e2e-loop.service
printf '[Service]\nExecStart=/bin/sh -c "while true; do echo ERROR e2e broke; sleep 1; done"\n' > /etc/systemd/system/e2e-noisy.service
systemctl daemon-reload
conf "UNITS=e2e-must"; expect yes "service e2e-must.service not running" "stopped must-run service"
flatline status --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["services"][0]["state"] != "inactive (dead)")' && ok "its state is shown in the app" || bad "service details"
systemctl start e2e-must; expect no "e2e-must" "recovers when the service runs"
systemctl start e2e-loop; conf "UNITS=e2e-loop"; expect yes "service e2e-loop.service restarting" "restart-looping service"
printf '[Service]\nExecStart=/bin/sleep infinity\n' > /etc/systemd/system/e2e-loop.service
systemctl daemon-reload; systemctl restart e2e-loop; expect no "e2e-loop" "recovers when it stops restarting"
systemctl start e2e-noisy; conf "UNITS=e2e-noisy" "LOG_ERRORS_MAX=3"; expect yes "service e2e-noisy.service logging errors" "service logging error lines"
systemctl stop e2e-noisy; expect no "e2e-noisy.service logging errors" "recovers when the errors stop"
systemctl stop e2e-must e2e-loop
rm -f /etc/systemd/system/e2e-must.service /etc/systemd/system/e2e-loop.service /etc/systemd/system/e2e-noisy.service
systemctl daemon-reload

echo "== access log"
log=/var/log/e2e-access.log
install -m 640 -o www-data -g adm /dev/null "$log"  # how Debian and Ubuntu keep web server logs
conf "ACCESS_LOG=$log" "HTTP_ERRORS_MAX=5"; checked
expect no "access" "an empty access log is quiet"
(for _ in $(seq 1 400); do
  printf '%s\n' '127.0.0.1 - - [20/Oct/2026:10:00:00 +0000] "GET /e2e HTTP/1.1" 502 12 "-" "e2e"' \
    '127.0.0.1 - - [20/Oct/2026:10:00:00 +0000] "GET /e2e HTTP/1.1" 429 12 "-" "e2e"' >> "$log"
  sleep 0.5
done) &
writer=$!
expect yes "access log 5xx above 5" "5xx lines in a www-data:adm 0640 log, read through the adm group"
expect yes "access log 429 above 5" "429 lines in the access log"
kill $writer; expect no "access log" "recovers when the errors stop"
rm -f "$log"; mkfifo "$log"  # a pipe with no writer would hang a plain open() for good
conf "ACCESS_LOG=$log"; expect yes "access_log check failed" "a pipe as the access log is loud, not a frozen agent"
rm -f "$log"; conf

echo "== sites"
web=$(mktemp -d)
printf '<html><head><meta content="noindex, nofollow" name="robots"></head></html>\n' > "$web/index.html"
printf 'User-agent: *\nDisallow: /\n' > "$web/robots.txt"
python3 -m http.server --bind 127.0.0.1 --directory "$web" 8098 >/dev/null 2>&1 &
srv=$!
conf "SITES=http://127.0.0.1:8098/missing"; expect yes "site 127.0.0.1/missing down" "a 404 page is down"
flatline status --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["sites"][0]["status"] != "HTTP 404")' && ok "its HTTP status is shown in the app" || bad "site details"
touch "$web/missing"; expect no "127.0.0.1/missing" "recovers when the page is back"
conf "SEO_SITES=http://127.0.0.1:8098/"
expect yes "site 127.0.0.1/ noindex" "noindex page"
expect yes "site 127.0.0.1/ robots.txt blocks crawlers" "robots.txt that blocks every crawler"
expect yes "site 127.0.0.1/ sitemap missing" "missing sitemap"
printf '<html></html>\n' > "$web/index.html"
printf 'User-agent: *\nDisallow:\nSitemap: http://127.0.0.1:8098/sitemap.xml\n' > "$web/robots.txt"
touch "$web/sitemap.xml"
conf "SEO_SITES=http://127.0.0.1:8098/"  # a restart looks again instead of waiting half an hour
expect no "site 127.0.0.1/" "recovers when search engines are welcome again (and plain http isn't asked for HSTS)"
kill $srv; rm -rf "$web"; conf

echo "== pm2 and docker"
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

echo "== maintenance"
if [ -e /run/reboot-required ]; then
  echo "  skip  this VM already needs a reboot"
else
  printf 'linux-image-e2e\n' > /run/reboot-required.pkgs; touch /run/reboot-required
  expect yes "reboot required" "reboot required"
  rm -f /run/reboot-required /run/reboot-required.pkgs; expect no "reboot required" "recovers after the reboot"
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
