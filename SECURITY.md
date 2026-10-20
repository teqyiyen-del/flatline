# Security

Please don't report security problems in public issues. Use GitHub's private reporting instead: open the **Security** tab of this repository and choose **Report a vulnerability**.

Only the latest release gets security fixes.

## What Flatline does and doesn't do

- The agent opens no network ports and accepts no connections. It only reads system state and makes outgoing requests: to Telegram, to the sites you list and to your heartbeat URL.
- It runs inside a systemd sandbox with no capabilities and a read-only file system apart from its own state folder.
- The Telegram bot token is stored in `/etc/flatline.conf` (root only, mode 600) on servers and in the macOS Keychain on your Mac. It never appears on a command line.
- Shared access is one line in the `flatline` account's `authorized_keys`, locked with `restrict` and `command="flatline status --json"`: no shell, no terminal, no tunnels, no other command. Invites work once and expire after 24 hours.
- `flatline uninstall` removes everything Flatline created, including the sharing account.
- Every release is built on GitHub from a tagged commit. Check a download with `shasum -a 256 -c SHA256SUMS` and `gh attestation verify <file> --repo <owner>/flatline`.
