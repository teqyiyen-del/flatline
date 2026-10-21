"""Checks the alert logic, the checks and config hardening. Runs anywhere, no Linux or internet needed:

    python3 agent/test_flatline.py
"""
import contextlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import threading

loader = importlib.machinery.SourceFileLoader("flatline", str(pathlib.Path(__file__).with_name("flatline")))
fl = importlib.util.module_from_spec(importlib.util.spec_from_loader("flatline", loader))
loader.exec_module(fl)

# config: bad numbers are clamped, unknown keys and broken regexes can't get in
with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
    f.write("INTERVAL=1\nDISK_MAX=abc\nRAM_MAX=nan\nIGNORE_UNITS=(\nEVIL=1\nNAME=web-1\nCERT_DAYS=999\nHTTP_ERRORS_MAX=0\n"
            "UNITS=nginx, -evil,foo@bar.service,docker.socket,my.app,a b,x;rm,--all,getty@\nMAINTENANCE=Nope\n")
fl.CONF = f.name
logged, real_log = [], fl.log
fl.log = logged.append
conf = fl.load_conf()
fl.log = real_log
os.unlink(f.name)
assert len(logged) == 9 and any("'x;rm'" in line for line in logged), logged  # bad values are logged, not silent
assert conf["INTERVAL"] == 10 and conf["DISK_MAX"] == conf["RAM_MAX"] == 90 and conf["NAME"] == "web-1", conf
assert "EVIL" not in conf and not conf["IGNORE_RE"].search("nginx.service")
assert conf["CERT_DAYS"] == 365 and conf["HTTP_ERRORS_MAX"] == 1 and conf["LOG_ERRORS_MAX"] == 0, conf
assert conf["MAINTENANCE"] is True and conf["ACCESS_LOG"] == conf["SEO_SITES"] == "", conf  # a typo keeps it on
# unit names can't turn into options, a template without its instance or anything else; a bare name means name.service
assert conf["UNIT_LIST"] == ["nginx.service", "foo@bar.service", "docker.socket", "my.app.service"], conf["UNIT_LIST"]

# nothing can smuggle extra config lines in through a token or chat id
assert fl.TOKEN_RE.fullmatch("123456789:" + "A" * 35)
assert not fl.TOKEN_RE.fullmatch("123456789:" + "A" * 35 + "\nHEARTBEAT_URL=http://evil")
assert not fl.CHAT_RE.fullmatch("1\nSITES=x")
try:
    fl.save_conf({"TELEGRAM_TOKEN": "x\nEVIL=1"})
    raise AssertionError("save_conf accepted a line break")
except ValueError:
    pass

# alerts: a one-off blip stays quiet, a problem seen twice alerts once, two clean checks announce the recovery
calls = []
real_tg = fl.tg
fl.tg = lambda token, method, **params: calls.append((method, params)) or {"ok": True}
fl.vitals = lambda: {"cpu": 5, "ram": 40, "disk": 50, "load": [0.1, 0.1, 0.1], "cores": 2, "uptime": 90000}
conf.update(TELEGRAM_TOKEN="t", TELEGRAM_CHAT_ID="1")
state = {}
for seen in [{"blip"}, set(), {"nginx.service failed"}, {"nginx.service failed"}, {"nginx.service failed"}, set(), set()]:
    fl.problems = lambda conf, v, seen=seen: sorted(seen)
    state = fl.tick(conf, state)
assert [p["text"] for _, p in calls] == ["🔴 web-1\n• nginx.service failed",
                                         "✅ web-1 recovered\n• nginx.service failed"], calls
assert state["alerted"] == [] and state["problems"] == []

# a flapping problem alerts once and recovers once, instead of on every flap
calls.clear()
for seen in [{"x"}, {"x"}, set(), {"x"}, set(), {"x"}, set(), set()]:
    fl.problems = lambda conf, v, seen=seen: sorted(seen)
    state = fl.tick(conf, state)
assert [p["text"] for _, p in calls] == ["🔴 web-1\n• x", "✅ web-1 recovered\n• x"], calls


# notes ride along in alerts, recoveries stay plain, and details are kept for the Mac app
def down_with_note(conf, v):
    v["services"] = [{"name": "nginx.service", "state": "active (running)", "restarts": 0}]
    return [fl.note(v, "site shop.example.com/en down", "HTTP 404"), "reboot required"]


calls.clear()
for check in [down_with_note, down_with_note, lambda conf, v: [], lambda conf, v: []]:
    fl.problems = check
    state = fl.tick(conf, state)
    if check is down_with_note:
        assert state["details"] == {"services": [{"name": "nginx.service", "state": "active (running)", "restarts": 0}]}
assert [p["text"] for _, p in calls] == ["🔴 web-1\n• reboot required\n• site shop.example.com/en down · HTTP 404",
                                         "✅ web-1 recovered\n• reboot required\n• site shop.example.com/en down"], calls

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

# pm2 error logs: the first check only notes where a log ends, then new error lines are counted, never shown
errlog = os.path.join(tempfile.mkdtemp(), "api-error.log")
with open(errlog, "w") as f:
    f.write("Error: old news\n" * 5)
jlist = json.dumps([{"name": "api", "pm2_env": {"status": "online", "pm_err_log_path": errlog}},
                    {"name": "api", "pm2_env": {"status": "online", "pm_err_log_path": errlog}},  # a second instance
                    {"name": "quiet", "pm2_env": {"status": "online", "pm_err_log_path": "/dev/null"}}])
fl.run = lambda *cmd, check=True: jlist
noisy = dict(conf, LOG_ERRORS_MAX=2)
assert fl.pm2(noisy, {}) == []
with open(errlog, "a") as f:
    f.write("Error: db gone\nall fine\nUnhandled exception\nPANIC: out of memory\nno errors here\n")
v = {}
assert fl.pm2(noisy, v) == ["pm2 api logging errors"] and v["notes"] == {"pm2 api logging errors": "3 lines"}, v
assert fl.pm2(noisy, {}) == []  # nothing new since
with open(errlog, "w") as f:  # pm2 flush: a shrunk log is read from its start
    f.write("Error\n" * 3)
assert fl.pm2(noisy, {}) == ["pm2 api logging errors"]
assert fl.pm2(conf, {}) == []  # LOG_ERRORS_MAX=0 turns it off
fl.run = lambda *cmd, check=True: jlist.replace("/dev/null", errlog + ".new")
assert fl.pm2(noisy, {}) == []  # a log pm2 hasn't written yet is fine
if os.geteuid() != 0:  # a log Flatline can't read is a failed check, never silence
    os.chmod(errlog, 0)
    try:
        fl.pm2(noisy, {})
        raise AssertionError("an unreadable pm2 error log passed")
    except PermissionError:
        pass
    os.chmod(errlog, 0o644)

fl.os.kill = lambda pid, signal: (_ for _ in ()).throw(ProcessLookupError)  # daemon died, pid file left behind
assert fl.pm2(conf, {}) == ["pm2 daemon not running"]
fl.read, fl.os.kill, fl.run = real_read, real_kill, real_run

# no credentials in labels, and only http(s) is ever fetched
assert fl.site_label("https://admin:hunter2@example.com/health?key=s3cret") == "example.com/health"
assert fl.site("ftp://admin:hunter2@example.com/x", conf)[1] == {"site example.com/x invalid url": ""}

# a slow site can't freeze the agent: stragglers are reported once the deadline passes
import time as _time
real_deadline, fl.REMOTE_DEADLINE = fl.REMOTE_DEADLINE, 0.5
real_site, fl.site = fl.site, (lambda *args: _time.sleep(3))
started = _time.monotonic()
v = {}
assert fl.remote({"SITES": "https://slow.example/x?token=1", "SEO_SITES": "", "PEERS": ""}, v) == ["site slow.example/x down"]
assert _time.monotonic() - started < 2
assert v["sites"] == [{"site": "slow.example/x", "ok": False, "status": "timeout", "cert_days": None}], v
assert v["notes"] == {"site slow.example/x down": "timeout"}


def late_extras(url, conf, seo, deadline, early):  # the page answered, then robots.txt or the sitemap dragged on
    early[url] = ({"site": "shop.example/", "ok": True, "status": "HTTP 200", "cert_days": 30}, {})
    _time.sleep(3)


fl.site, v = late_extras, {}
assert fl.remote({"SITES": "https://shop.example/", "SEO_SITES": "", "PEERS": ""}, v) == []  # still up, not "down"
assert v["sites"] == [{"site": "shop.example/", "ok": True, "status": "HTTP 200", "cert_days": 30}], v
fl.site, fl.REMOTE_DEADLINE = real_site, real_deadline

# sites, against a tiny local web server: an answer of 400 or more is down, except login walls
routes = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code, headers, body = routes.get(self.path, (404, {}, b""))
        self.send_response(code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"
routes.update({"/ok": (200, {}, b"hi"), "/login": (401, {}, b""), "/staff": (403, {}, b""), "/boom": (502, {}, b""),
               "/moved": (301, {"Location": "/ok"}, b""), "/ftp": (302, {"Location": "ftp://127.0.0.1/x"}, b"")})
real_sleep, fl.time.sleep = fl.time.sleep, (lambda seconds: None)  # skip the 3 s second look
for path, ok, status in [("/ok", True, "HTTP 200"), ("/login", True, "HTTP 401"), ("/staff", True, "HTTP 403"),
                         ("/missing", False, "HTTP 404"), ("/boom", False, "HTTP 502"), ("/moved", True, "HTTP 200")]:
    detail, found = fl.site(base + path, conf)
    assert detail == {"site": "127.0.0.1" + path, "ok": ok, "status": status, "cert_days": None}, detail
    assert found == ({} if ok else {f"site 127.0.0.1{path} down": status}), found
assert fl.answer(base + "/ftp")[0] == "HTTP 302"  # only http(s) is ever followed
assert fl.answer("http://127.0.0.1:1/") == ("no answer", None)

# what went wrong becomes the note: timeout, no answer, certificate error
real_fetch = fl.fetch
for error, status in [(fl.socket.timeout(), "timeout"), (fl.urllib.error.URLError(fl.socket.timeout()), "timeout"),
                      (fl.urllib.error.URLError(fl.ssl.SSLCertVerificationError()), "certificate error"),
                      (fl.urllib.error.URLError(ConnectionRefusedError()), "no answer"),
                      (fl.http.client.BadStatusLine("x"), "no answer")]:
    fl.fetch = lambda *args, error=error, **kwargs: (_ for _ in ()).throw(error)
    assert fl.answer("https://x.example/") == (status, None), status
    if status == "certificate error":
        assert fl.site("https://x.example/", conf)[1] == {"site x.example/ certificate error": ""}
fl.fetch = real_fetch


# certificates: whole days left, rounded down; remembered for half an hour, a failed read is not
class FakeTLS:
    def __init__(self, days):
        self.days = days

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def wrap_socket(self, raw, server_hostname):
        assert server_hostname == "example.com"
        return self

    def getpeercert(self):
        return {"notAfter": _time.strftime("%b %d %H:%M:%S %Y GMT", _time.gmtime(_time.time() + self.days * 86400))}


real_connect, real_context = fl.socket.create_connection, fl.ssl.create_default_context
fl.socket.create_connection = lambda address, timeout: FakeTLS(0)
for left, days in [(10.5, 10), (13.99, 13), (0.5, 0), (-0.5, -1)]:
    fl.SEEN.clear()
    fl.ssl.create_default_context = lambda left=left: FakeTLS(left)
    assert fl.cert_days("example.com", 443) == days, (left, days)
fl.ssl.create_default_context = lambda: FakeTLS(200)
assert fl.cert_days("example.com", 443) == -1  # still the remembered answer
fl.SEEN.clear()
fl.socket.create_connection = lambda address, timeout: (_ for _ in ()).throw(ConnectionRefusedError())
assert fl.cert_days("example.com", 443) is None and not fl.SEEN
fl.socket.create_connection, fl.ssl.create_default_context = real_connect, real_context

real_answer, real_cert = fl.answer, fl.cert_days
fl.answer = lambda url, limit=0: ("HTTP 200", ("https://shop.example/", fl.http.client.HTTPMessage(), b""))
fl.cert_days = lambda host, port: 5
assert fl.site("https://shop.example/", dict(conf, CERT_DAYS=14)) == (
    {"site": "shop.example/", "ok": True, "status": "HTTP 200", "cert_days": 5},
    {"site shop.example/ certificate expires soon": "in 5 days"})
assert fl.site("https://shop.example/", dict(conf, CERT_DAYS=5))[1] == {}
assert fl.site("https://shop.example/", dict(conf, CERT_DAYS=0))[0]["cert_days"] is None  # 0 turns it off
fl.answer, fl.cert_days = real_answer, real_cert

# robots.txt: only "Disallow: /" in a group for every crawler blocks; the first http(s) Sitemap is the one checked
origin = "https://shop.example"
for text, blocked, sitemap in [
    ("User-agent: *\nDisallow: /\n", True, origin + "/sitemap.xml"),
    ("user-agent: bingbot\nUSER-AGENT: *\ndisallow: /   # closed for now\n", True, origin + "/sitemap.xml"),
    ("User-agent: *\nDisallow:\n", False, origin + "/sitemap.xml"),  # empty Disallow allows everything
    ("User-agent: *\nDisallow: /admin\n", False, origin + "/sitemap.xml"),
    ("User-agent: Googlebot\nDisallow: /\n", False, origin + "/sitemap.xml"),
    ("User-agent: *\nAllow: /\n\nUser-agent: BadBot\nDisallow: /\n", False, origin + "/sitemap.xml"),
    ("# User-agent: *\n# Disallow: /\n", False, origin + "/sitemap.xml"),
    ("Sitemap: https://cdn.example/a.xml\nSitemap: https://cdn.example/b.xml\n", False, "https://cdn.example/a.xml"),
    ("Sitemap: ftp://cdn.example/a.xml\n", False, origin + "/sitemap.xml"),
    ("Sitemap: /relative.xml\n", False, origin + "/sitemap.xml"),
    ("User-agent: *\nDisallow: /\nSitemap: https://[shop.example/s.xml\n", True, origin + "/sitemap.xml"),  # broken
    ("", False, origin + "/sitemap.xml"),
]:
    assert fl.robots(text, origin) == (blocked, sitemap), text


# noindex: an X-Robots-Tag header, or a robots/googlebot meta tag in either attribute order and any case
def headers(**pairs):
    h = fl.http.client.HTTPMessage()
    for key, value in pairs.items():
        h[key.replace("_", "-")] = value
    return h


for h, html, blocked in [
    (headers(X_Robots_Tag="noindex, nofollow"), "", True),
    (headers(X_Robots_Tag="googlebot: none"), "", True),
    (headers(X_Robots_Tag="nofollow, noimageindex"), "", False),
    (headers(X_Robots_Tag="max-image-preview:none"), "", False),  # "none" for image previews only
    (headers(), '<meta name="robots" content="noindex">', True),
    (headers(), "<META CONTENT='NOINDEX,FOLLOW' NAME='Robots'>", True),
    (headers(), '<meta name="googlebot" content="none" />', True),
    (headers(), '<meta name="robots" content="index, follow">', False),
    (headers(), '<meta name="robots" content="index, follow, max-image-preview:none">', False),
    (headers(), "<meta name=robots content=noindex>", True),  # minified, no quotes
    (headers(), "<meta content=noindex,nofollow name=robots>", True),
    (headers(), '<meta name="description" content="noindex is a word">', False),
    (headers(), '<meta data-name="robots" content="noindex">', False),
]:
    assert fl.noindex(h, html) == blocked, (dict(h), html)
started = _time.monotonic()
assert not fl.noindex(headers(), "<meta" * 100_000)  # 500 KB of unfinished tags takes a blink, not minutes
assert _time.monotonic() - started < 1

# HSTS is only asked of https pages; an extra request that fails is unknown, not a problem
hsts = headers(Strict_Transport_Security="max-age=63072000")
far = float("inf")
assert fl.search_guard("https://a.example/", "https://127.0.0.1:1/", headers(), b"", far) == ({"site a.example/ no HSTS": ""}, False)
assert fl.search_guard("https://a.example/", "https://127.0.0.1:1/", hsts, b"", far) == ({}, False)
assert fl.search_guard("http://a.example/", "http://127.0.0.1:1/", headers(), b"", far) == ({}, False)
assert fl.search_guard("http://a.example/", base + "/", headers(), b"", _time.monotonic()) == ({}, False)  # no time left

# the whole search-engine guard against the local server, remembered for half an hour in watch mode
fl.SEEN.clear()
routes.update({"/": (200, {}, b'<html><meta content="noindex" name="robots"></html>'),
               "/robots.txt": (200, {}, b"\xef\xbb\xbfUser-agent: *\nDisallow: /\n")})
found = {"site 127.0.0.1/ noindex": "", "site 127.0.0.1/ robots.txt blocks crawlers": "",
         "site 127.0.0.1/ sitemap missing": "HTTP 404"}
assert fl.site(base + "/", conf, seo=True)[1] == found
routes.update({"/": (200, {}, b"<html></html>"), "/robots.txt": (200, {}, f"Sitemap: {base}/maps/a.xml\n".encode()),
               "/maps/a.xml": (200, {}, b"<urlset/>")})
assert fl.site(base + "/", conf, seo=True)[1] == found  # remembered
fl.SEEN.clear()  # a restart, or a one-off --live read, looks again
assert fl.site(base + "/", conf, seo=True)[1] == {}
del routes["/robots.txt"]  # no robots.txt at all is fine, and then /sitemap.xml is the one checked
fl.SEEN.clear()
assert fl.site(base + "/", conf, seo=True)[1] == {"site 127.0.0.1/ sitemap missing": "HTTP 404"}
fl.SEEN[("seo", base + "/")] = (0, {"site 127.0.0.1/ robots.txt blocks crawlers": ""})  # stale
fl.fetch = lambda url, limit=0, timeout=10: (_ for _ in ()).throw(TimeoutError()) if url.endswith("/robots.txt") \
    else real_fetch(url, limit, timeout)
assert fl.site(base + "/", conf, seo=True)[1] == {"site 127.0.0.1/ robots.txt blocks crawlers": ""}  # unknown keeps it
fl.SEEN[("seo", base + "/")] = (0, {"site 127.0.0.1/ noindex": ""})  # since then noindex came off the page
early = {}
assert fl.site(base + "/", conf, seo=True, early=early)[1] == {}  # read off the page again, so it recovers
assert fl.SEEN[("seo", base + "/")] == (0, {}), fl.SEEN  # robots.txt still unanswered: looks again next check
# the page's verdict, with the last look, is ready before the extras in case they run late
assert early == {base + "/": ({"site": "127.0.0.1/", "ok": True, "status": "HTTP 200", "cert_days": None},
                              {"site 127.0.0.1/ noindex": ""})}, early
fl.fetch = real_fetch

# a site listed in SITES and SEO_SITES is checked once, and each problem keeps its note
v = {}
assert fl.remote(dict(conf, SITES=f"{base}/missing,{base}/", SEO_SITES=f"{base}/", PEERS=""), v) == [
    "site 127.0.0.1/missing down", "site 127.0.0.1/ sitemap missing"]
assert [d["site"] for d in v["sites"]] == ["127.0.0.1/missing", "127.0.0.1/"], v["sites"]
assert v["notes"]["site 127.0.0.1/missing down"] == "HTTP 404"
fl.time.sleep = real_sleep
server.shutdown()

# must-run services: one systemctl call with "--" before the names, failed units left to the units check
show = ["LoadState=loaded\nActiveState=active\nSubState=running\nNRestarts=0",
        "LoadState=loaded\nActiveState=inactive\nSubState=dead\nNRestarts=0",
        "LoadState=loaded\nActiveState=activating\nSubState=auto-restart\nNRestarts=2",
        "LoadState=loaded\nActiveState=failed\nSubState=failed\nNRestarts=5",
        "LoadState=not-found\nActiveState=inactive\nSubState=dead\nNRestarts=0"]
argv = []
fl.run = lambda *cmd, check=True: argv.append(cmd) or "\n\n".join(show) + "\n"
must = dict(conf, UNIT_LIST=["web.service", "db.service", "worker.service", "cron.service", "ghost.service"])
fl.SEEN.clear()
v = {}
assert fl.services(must, v) == ["service db.service not running", "service worker.service not running",
                                "service ghost.service not running"], v
assert argv[0][3:] == ("--", "web.service", "db.service", "worker.service", "cron.service", "ghost.service"), argv
assert v["notes"] == {"service db.service not running": "inactive (dead)",
                      "service worker.service not running": "activating (auto-restart)",
                      "service ghost.service not running": "not found"}, v["notes"]
assert v["services"][0] == {"name": "web.service", "state": "active (running)", "restarts": 0}, v["services"]
v = {}  # ...unless IGNORE_UNITS hides it there: a must-run service never goes unreported
assert "service cron.service not running" in fl.services(dict(must, IGNORE_RE=fl.re.compile("cro")), v)
assert v["notes"]["service cron.service not running"] == "failed (failed)", v
# restarts: the first check only notes the counts, then a count that went up is a problem
show[0] = show[0].replace("NRestarts=0", "NRestarts=3")
v = {}
assert "service web.service restarting" in fl.services(must, v) and v["notes"]["service web.service restarting"] == "3 restarts"
assert not [p for p in fl.services(must, {}) if "restarting" in p]  # no new restarts since
fl.run = lambda *cmd, check=True: "LoadState=loaded\n"
try:
    fl.services(must, {})
    raise AssertionError("a short systemctl answer passed")
except ValueError:
    pass

# error lines in a service's journal: error priority or worse, or an error word; only the count leaves
entries = [{"PRIORITY": "3", "MESSAGE": "oops"}, {"PRIORITY": "6", "MESSAGE": "Traceback (most recent call last):"},
           {"PRIORITY": "6", "MESSAGE": "FATAL: role missing"}, {"PRIORITY": "2"}, {"PRIORITY": "6", "MESSAGE": "no errors"},
           {"PRIORITY": "6", "MESSAGE": [104, 105]}, {"PRIORITY": "4", "MESSAGE": "slow query"}]
argv.clear()
fl.run = lambda *cmd, check=True: argv.append(cmd) or "".join(json.dumps(e) + "\n" for e in entries)
v = {}
assert fl.journal(dict(must, UNIT_LIST=["db.service"], LOG_ERRORS_MAX=3), v) == ["service db.service logging errors"]
assert v["notes"] == {"service db.service logging errors": "4 lines"}, v
assert argv[0][:3] == ("journalctl", "--unit=db.service", "--since=-10s"), argv
assert fl.journal(dict(must, UNIT_LIST=["db.service"], LOG_ERRORS_MAX=4), {}) == []
argv.clear()
assert fl.journal(dict(must, LOG_ERRORS_MAX=0), {}) == [] and argv == []  # 0 turns it off
fl.run = real_run

# access log: the first check starts at the end, then only new lines count; rotation and half-written lines too
fl.SEEN.clear()
log = os.path.join(tempfile.mkdtemp(), "access.log")
line = '203.0.113.9 - - [20/Oct/2026:10:00:00 +0000] "GET /cart?id=7 HTTP/1.1" {} 512 "-" "Mozilla/5.0"\n'.format
with open(log, "w") as f:
    f.write(line(500) * 50)  # old news
web = dict(conf, ACCESS_LOG=log, HTTP_ERRORS_MAX=2)
assert fl.access_log(web, {}) == []
with open(log, "a") as f:
    f.write(line(500) * 2 + line(502) + line(200) + line(404) + line(429) * 3 + line(503)[:30])  # last one half written
v = {}
assert fl.access_log(web, v) == ["access log 5xx above 2", "access log 429 above 2"], v
assert v["notes"] == {"access log 5xx above 2": "3 in the last check", "access log 429 above 2": "3 in the last check"}
with open(log, "a") as f:
    f.write(line(503)[30:] + line(500) * 2)  # the half line is finished: 3 more
assert fl.access_log(web, {}) == ["access log 5xx above 2"]
assert fl.access_log(web, {}) == []  # quiet since
with open(log, "a") as f:  # Apache writes a quote inside the request as \", so a client can't fake a status
    f.write('203.0.113.9 - - [20/Oct/2026:10:00:00 +0000] "GET /x\\" 500 y HTTP/1.1" 400 0 "-" "-"\n' * 3)
assert fl.access_log(web, {}) == []
with open(log, "a") as f:  # about 2 MB at once is read 1 MB at a time, lines across the cut included
    f.write(line(500) * 20000)
v = {}
assert fl.access_log(web, v) == ["access log 5xx above 2"]
assert v["notes"]["access log 5xx above 2"] == "20000 in the last check", v
os.rename(log, log + ".1")  # rotated: the new log counts from its start
with open(log, "w") as f:
    f.write(line(500) * 3)
assert fl.access_log(web, {}) == ["access log 5xx above 2"]
with open(log, "w") as f:  # copytruncate: a shrunk log is read from its start
    f.write(line(500) * 2)
assert fl.access_log(dict(web, HTTP_ERRORS_MAX=1), {}) == ["access log 5xx above 1"]
if os.geteuid() != 0:  # an unreadable log is a failed check, never silence
    os.chmod(log, 0)
    try:
        fl.access_log(web, {})
        raise AssertionError("an unreadable access log passed")
    except PermissionError:
        pass
try:
    fl.access_log(dict(web, ACCESS_LOG="access.log"), {})
    raise AssertionError("a relative ACCESS_LOG passed")
except ValueError:
    pass
fifo = os.path.join(tempfile.mkdtemp(), "access.log")
os.mkfifo(fifo)  # opened the plain way, a FIFO with no writer would freeze every check from then on
try:
    fl.access_log(dict(web, ACCESS_LOG=fifo), {})
    raise AssertionError("a FIFO passed")
except ValueError:
    pass

# maintenance: Ubuntu's wording for security updates varies, and a missing file is unknown, not zero
files = {}
real_exists = fl.os.path.exists
fl.read = lambda path, limit=1_000_000: files.get(path, "")
fl.os.path.exists = lambda path: path in files
on = dict(conf, MAINTENANCE=True)
for text, count in [
    ("\n50 updates can be applied immediately.\n44 of these updates are standard security updates.\n"
     "To see these additional updates run: apt list --upgradable\n", 44),
    ("1 update can be applied immediately.\n1 of these updates is a standard security update.\n", 1),
    ("12 packages can be updated.\n3 updates are security updates.\n", 3),
    ("1 package can be updated.\n1 update is a security update.\n", 1),
    ("12 updates can be applied immediately.\n12 of these updates are ESM Infra security updates.\n", 12),
    ("5 updates can be applied immediately.\n1 of these updates is an ESM Apps security update.\n"
     "2 of these updates are ESM Infra security updates.\n2 of these updates are standard security updates.\n", 5),
    ("0 updates can be applied immediately.\n7 additional security updates can be applied with ESM Apps.\n", 0),
]:
    files = {"/var/lib/update-notifier/updates-available": text}
    v = {}
    assert fl.maintenance(on, v) == (["security updates pending"] if count else []), text
    assert v["updates"] == count and v["reboot"] is False and v.get("notes", {}).get("security updates pending") == (
        f"{count} updates" if count else None), (text, v)
files = {"/run/reboot-required": "*** System restart required ***\n",
         "/run/reboot-required.pkgs": "linux-image-6.8.0-45-generic\nlinux-base\nlinux-base\nlibc6\ndbus\n"}
v = {}
assert fl.maintenance(on, v) == ["reboot required"] and v["reboot"] is True and "updates" not in v, v
assert v["notes"] == {"reboot required": "linux-image-6.8.0-45-generic, linux-base, libc6"}, v
v = {}
assert fl.maintenance(dict(conf, MAINTENANCE=False), v) == [] and v == {}
fl.read, fl.os.path.exists = real_read, real_exists

# live mode (status --live) is one check with nothing remembered: restarts, pm2 logs and access logs need
# history, so they stay quiet; details land at the top level and notes stay out
fl.SEEN.clear()
fl.run = lambda *cmd, check=True: "\n\n".join(show) + "\n"
assert not [p for p in fl.services(must, {}) if "restarting" in p]
with open(log + ".2", "w") as f:
    f.write(line(500) * 100)
assert fl.access_log(dict(web, ACCESS_LOG=log + ".2"), {}) == []
fl.run, fl.os.kill = (lambda *cmd, check=True: jlist), (lambda pid, signal: None)
fl.read = lambda path, limit=1_000_000: "4242" if path.endswith("pm2.pid") else real_read(path, limit)
assert fl.pm2(noisy, {}) == []
fl.read, fl.os.kill, fl.run = real_read, real_kill, real_run


def live_problems(conf, v):
    v["sites"] = [{"site": "a.example/", "ok": False, "status": "HTTP 404", "cert_days": None}]
    return [fl.note(v, "site a.example/ down", "HTTP 404")]


fl.load_conf, fl.problems = (lambda: dict(conf)), live_problems
out = io.StringIO()
with contextlib.redirect_stdout(out):
    fl.status(True, live=True)
shown = json.loads(out.getvalue())
assert shown["sites"][0]["status"] == "HTTP 404" and shown["problems"] == ["site a.example/ down"], shown
assert "notes" not in shown and shown["agent"] is False, shown

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
