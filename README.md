# Flatline

**Know before your server flatlines.**

![Flatline in the menu bar, watching ten servers](docs/flatline.png)

Flatline watches your Linux servers and pings your Telegram the moment something breaks. A tiny menu bar app on your Mac shows every server's pulse at a glance, whether you run one server or twenty.

- 💓 **Pulse:** CPU, RAM, disk and uptime for every server, with a CPU sparkline
- 🔍 **Server pages:** click a server for its CPU history, memory and disk in GB, load, OS, pm2 apps, Docker containers and one-click SSH
- 🚨 **Telegram alerts** when a systemd service fails, a pm2 app or Docker container dies, a disk fills up or a site goes down. Another message arrives when it recovers.
- 🫀 **Heartbeat:** servers can watch each other, and an optional dead man's switch catches a server that dies completely
- 📌 **Live dashboard** pinned in your Telegram chat, kept fresh by the Mac app
- 🤝 **Share a server** with a partner through a one-time invite: they can see it, never log in
- 🫥 **No-install mode:** without the agent, the app reads a server once over SSH and writes nothing to it
- 🔒 **No open ports:** the Mac app reaches your servers over the SSH you already use, and the agent never listens for connections

Click a server to look inside. When something breaks, the art turns red and stops beating:

<p><img src="docs/flatline-detail.png" width="49%" alt="A healthy server's page"> <img src="docs/flatline-alert.png" width="49%" alt="A server in trouble"></p>

## 1. Get the Mac app

Download **Flatline.dmg** from the [latest release](https://github.com/teqyiyen-del/flatline/releases/latest), open it and drag Flatline into Applications. You need macOS 14 or later, on Apple silicon or Intel.

Flatline isn't notarized by Apple yet, so the first time you open it macOS says it can't check it. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

Then click the pulse icon in the menu bar and the gear in the top-right corner:

- **Servers:** add each server as an SSH destination, like `root@203.0.113.10` or an alias from `~/.ssh/config`. The app uses the SSH keys you already have.
- **Telegram:** open [@BotFather](https://t.me/BotFather) in Telegram, send `/newbot` and paste the token into Flatline. Send your new bot any message, then press **Connect**. Flatline finds your chat, keeps the token in your macOS Keychain and hands it to every server, so alerts keep coming even when your Mac is off. Give Flatline its own bot: two programs reading the same bot get in each other's way.

## 2. Install the agent on each server

```sh
curl -fsSL https://github.com/teqyiyen-del/flatline/releases/latest/download/install.sh | sudo bash
```

The installer downloads the agent from the same release, checks it against the release's SHA256 checksum and starts the `flatline` systemd service. You need Linux with systemd and Python 3.8 or newer (Ubuntu and Debian ship both). Run the same line again to update; your config is kept. To pin a version, put `FLATLINE_VERSION=v0.2.0` after `sudo`.

You can also connect Telegram on the server itself with `sudo flatline setup`.

## Share a server

Open a server in the app and create an invite. It works once and expires after 24 hours. Your partner pastes it into their own Flatline (gear → "Paste an invite") and the server shows up next to theirs.

Behind the scenes the invite holds a throwaway key that can only trade itself for your partner's own key. That key lands on the server as one line in the `flatline` account's `authorized_keys`, locked to a single command:

```
restrict,command="flatline status --json" ssh-ed25519 AAAA… partner
```

`restrict` turns off shells, terminals and tunnels, and `command=` means any other command still just prints the status. List and revoke access from the server's page, or with `sudo flatline access` and `sudo flatline revoke NAME`.

## No-install mode and removal

If a server has no agent, the app runs the same check once over SSH (`python3 - status --json --live`, fed from the app) and writes nothing to the server. You only give up alerts while your Mac is off.

To remove Flatline from a server, remove the server in the app and choose "Remove from server too", or run `sudo flatline uninstall`. It deletes the program, its service, its settings, its state and the sharing account.

## Configuration

Each server keeps its settings in `/etc/flatline.conf`. After editing, apply them with `sudo systemctl restart flatline`.

| Key | Default | What it does |
|---|---|---|
| `NAME` | hostname | Name shown in alerts and in the app |
| `DISK_MAX`, `RAM_MAX` | `90` | Alert when usage reaches this percentage |
| `INTERVAL` | `60` | Seconds between checks (10 to 3600) |
| `SITES` | | URLs to check, comma separated. A 5xx answer, a timeout or a certificate error counts as down |
| `PEERS` | | Other servers to watch, comma separated `name=host:port` |
| `HEARTBEAT_URL` | | Pinged on every check: [healthchecks.io](https://healthchecks.io), an Uptime Kuma push monitor, etc. |
| `IGNORE_UNITS` | `motd-news` | Failed systemd units to ignore (regex) |

A problem has to show up on two checks in a row before you get an alert, so short blips stay quiet. If a check itself breaks, you get an alert about that too, never silence. pm2 and Docker are checked when they're installed; pm2 needs to be on the system `PATH`.

## Security

- **No listener.** The agent opens no ports and accepts no connections. It only reads system state and makes outgoing requests to Telegram, the sites you list and your heartbeat URL. It never runs a shell and uses nothing outside the Python standard library.
- **Sandboxed.** systemd runs it with no capabilities, a read-only file system apart from its own state folder, private `/tmp` and `/dev`, a system call filter and locked kernel settings. `systemd-analyze security flatline` rates it 2.0 (OK).
- **Secrets stay put.** The bot token lives in `/etc/flatline.conf` (root only, mode 600) on servers and in the Keychain on your Mac. It never appears on a command line: the Mac app hands it over through SSH's standard input.
- **Strict input.** Tokens and chat IDs must match exact formats, config values can't contain line breaks, unknown config keys are ignored and numbers are clamped to safe ranges.
- **Two fixed commands.** Over SSH the app only ever runs `flatline status --json` and `flatline telegram`.
- **Verifiable releases.** Every release is built on GitHub from a tagged commit. Check what you downloaded:

  ```sh
  shasum -a 256 -c SHA256SUMS
  gh attestation verify Flatline.dmg --repo teqyiyen-del/flatline
  ```

- **Read before you run.** Rather not pipe into bash? Download `install.sh` and `flatline` from the release, read them (a few hundred lines), then run `sudo bash install.sh` next to them.

Found a security issue? Please report it privately, as described in [SECURITY.md](SECURITY.md).

## Commands

```sh
flatline status           # vitals and current problems
flatline status --json    # the same, for the app
sudo flatline setup       # connect Telegram from the server
journalctl -u flatline    # logs
```

## Uninstall

On a server, `sudo flatline uninstall`. On your Mac, quit Flatline from its settings and drag it from Applications to the Trash.

## Building from source

```sh
python3 agent/test_flatline.py   # alert logic and config hardening, runs anywhere
sudo bash tests/e2e.sh           # breaks things for real on a throwaway Linux VM, never a real server
./app/build.sh                   # the Mac app, needs the Xcode Command Line Tools
./app/make-dmg.sh                # the disk image, needs: pip install dmgbuild
```

Flatline doesn't accept pull requests; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. The bundled Geist Mono font is licensed under the SIL Open Font License 1.1 (`app/Fonts/OFL-GeistMono.txt`).
