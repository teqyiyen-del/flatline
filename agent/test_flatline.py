"""Checks the alert logic and config hardening. Runs anywhere, no Linux or network needed:

    python3 agent/test_flatline.py
"""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile

loader = importlib.machinery.SourceFileLoader("flatline", str(pathlib.Path(__file__).with_name("flatline")))
fl = importlib.util.module_from_spec(importlib.util.spec_from_loader("flatline", loader))
loader.exec_module(fl)

# config: bad numbers are clamped, unknown keys and broken regexes can't get in
with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
    f.write("INTERVAL=1\nDISK_MAX=abc\nIGNORE_UNITS=(\nEVIL=1\nNAME=web-1\n")
fl.CONF = f.name
conf = fl.load_conf()
os.unlink(f.name)
assert conf["INTERVAL"] == 10 and conf["DISK_MAX"] == 90 and conf["NAME"] == "web-1", conf
assert "EVIL" not in conf and not conf["IGNORE_RE"].search("nginx.service")

# nothing can smuggle extra config lines in through a token or chat id
assert fl.TOKEN_RE.fullmatch("123456789:" + "A" * 35)
assert not fl.TOKEN_RE.fullmatch("123456789:" + "A" * 35 + "\nHEARTBEAT_URL=http://evil")
assert not fl.CHAT_RE.fullmatch("1\nSITES=x")
try:
    fl.save_conf({"TELEGRAM_TOKEN": "x\nEVIL=1"})
    raise AssertionError("save_conf accepted a line break")
except ValueError:
    pass

# alerts: a one-off blip stays quiet, a problem seen twice alerts once, recovery is announced
calls = []
real_tg = fl.tg
fl.tg = lambda token, method, **params: calls.append((method, params)) or {"ok": True}
fl.vitals = lambda: {"cpu": 5, "ram": 40, "disk": 50, "load": [0.1, 0.1, 0.1], "cores": 2, "uptime": 90000}
conf.update(TELEGRAM_TOKEN="t", TELEGRAM_CHAT_ID="1")
state = {}
for seen in [{"blip"}, set(), {"nginx.service failed"}, {"nginx.service failed"}, {"nginx.service failed"}, set()]:
    fl.problems = lambda conf, v, seen=seen: sorted(seen)
    state = fl.tick(conf, state)
assert [p["text"] for _, p in calls] == ["🔴 web-1\n• nginx.service failed",
                                         "✅ web-1 recovered\n• nginx.service failed"], calls
assert state["alerted"] == [] and state["problems"] == []

# a failed send is retried on the next check instead of being lost
fl.problems = lambda conf, v: ["x"]
replies = iter([{}, {"ok": True}])  # Telegram down, then back
sent = []
fl.tg = lambda token, method, **params: sent.append(params["text"]) or next(replies)
state = fl.tick(conf, {"problems": ["x"], "alerted": []})
assert state["alerted"] == [], state  # not marked as delivered
state = fl.tick(conf, state)
assert state["alerted"] == ["x"] and len(sent) == 2, (state, sent)

# pm2 and docker: problems for the alerts, details for the Mac app
pm2_out = ('[PM2] warning first\n[{"name":"api","pm2_env":{"status":"online","restart_time":0},"monit":{"cpu":3,"memory":104857600}},'
           '{"name":"worker","pm2_env":{"status":"errored","restart_time":15},"monit":{"cpu":0,"memory":0}}]')
docker_out = "web\trunning\tUp 2 hours (unhealthy)\ncache\trunning\tUp 2 hours\nloop\trestarting\tRestarting (1) 3 seconds ago\n"
real_run, fl.run = fl.run, (lambda *cmd, check=True: {"pm2": pm2_out, "docker": docker_out}.get(cmd[0], ""))
real_read, real_kill = fl.read, fl.os.kill
fl.read = lambda path, limit=1_000_000: "4242" if path.endswith("pm2.pid") else real_read(path, limit)
fl.os.kill = lambda pid, signal: None  # pretend the pm2 daemon is alive
v = {}
assert fl.pm2(conf, v) == ["pm2 worker down"], v
assert v["pm2"][0] == {"name": "api", "status": "online", "cpu": 3, "mem": 100, "restarts": 0}, v["pm2"]
assert fl.docker(conf, v) == ["docker web unhealthy", "docker loop unhealthy"]
assert [b["name"] for b in v["docker"]] == ["web", "cache", "loop"]
fl.os.kill = lambda pid, signal: (_ for _ in ()).throw(ProcessLookupError)  # daemon died, pid file left behind
assert fl.pm2(conf, {}) == ["pm2 daemon not running"]
fl.read, fl.os.kill, fl.run = real_read, real_kill, real_run

# no credentials in labels, and only http(s) is ever fetched
assert fl.site_label("https://admin:hunter2@example.com/health?key=s3cret") == "example.com/health"
assert fl.site("ftp://admin:hunter2@example.com/x") == "site example.com/x invalid url"

# a slow site can't freeze the agent: stragglers are reported once the deadline passes
import time as _time
fl.REMOTE_DEADLINE = 0.5
real_site, fl.site = fl.site, (lambda spec: _time.sleep(3))
fl.probe = lambda check, spec: check(spec)
started = _time.monotonic()
assert fl.remote({"SITES": "https://slow.example/x?token=1", "PEERS": ""}, {}) == ["site slow.example/x down"]
assert _time.monotonic() - started < 2
fl.site = real_site

# a command that fails is a failed check, not silence; a missing program stays quiet
assert fl.run("false-program-that-does-not-exist") == ""
try:
    fl.run("false")
    raise AssertionError("a failing command passed")
except RuntimeError:
    pass
assert fl.run("false", check=False) == ""

# Telegram answering with a list instead of an object doesn't crash anything
real_urlopen = fl.urllib.request.urlopen
class Reply:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self, n): return b"[1, 2]"
fl.urllib.request.urlopen = lambda *a, **k: Reply()
assert real_tg("t", "getMe") == {}
fl.urllib.request.urlopen = real_urlopen

# sharing: an invite works once, the guest gets status only, and access can be taken back
import io, sys as _sys
home = tempfile.mkdtemp()
os.makedirs(os.path.join(home, ".ssh"))
fl.SHARE_HOME, fl.require_root = home, lambda: None
invite_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI" + "A" * 43
guest_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI" + "B" * 43
fl.edit_keys(lambda lines: lines + [f'restrict,command="/usr/local/bin/flatline redeem 0123456789abcdef" {invite_key} flatline-invite-0123456789abcdef'])
_sys.stdin = io.StringIO(guest_key + "\npartner\n")
fl.redeem("0123456789abcdef")
keys = open(fl.keys_file()).read()
assert "flatline-invite" not in keys and 'restrict,command="/usr/local/bin/flatline status --json" ' + guest_key in keys, keys
_sys.stdin = io.StringIO(guest_key + "\nsomeone-else\n")
try:
    fl.redeem("0123456789abcdef")
    raise AssertionError("an invite worked twice")
except SystemExit:
    pass
_sys.stdin = io.StringIO("ssh-rsa AAAA evil\nx\n")
try:
    fl.redeem("0123456789abcdef")
    raise AssertionError("accepted a non-ed25519 key")
except SystemExit:
    pass
assert fl.guests() == ["partner"]
fl.revoke("partner")
assert fl.guests() == [] and oct(os.stat(fl.keys_file()).st_mode)[-3:] == "600"
print("ok")
