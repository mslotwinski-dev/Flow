# Flow

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)
![Platform: Linux](https://img.shields.io/badge/Platform-Linux%20%2F%20Unix-lightgrey.svg)

> **Real-time Google Drive sync daemon for Unix systems — set it and forget it.**

Flow is an advanced Bash shell daemon that automates the real-time synchronization of local directories with Google Drive. It eliminates the need for manual backups by silently watching your filesystem for changes and pushing them to the cloud the moment they happen, keeping your data safe without interrupting your workflow.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [User Manual](#user-manual)
  - [Starting the Daemon](#starting-the-daemon)
  - [Stopping the Daemon](#stopping-the-daemon)
  - [Restarting the Daemon](#restarting-the-daemon)
  - [Checking Status](#checking-status)
  - [Viewing Logs](#viewing-logs)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Project Specification](#project-specification)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

Flow bridges the gap between your local filesystem and Google Drive by running invisibly in the background as a **Unix daemon**. Unlike scheduled backup tools, Flow reacts to filesystem events *as they occur*, ensuring your cloud storage is always up to date with minimal latency.

The project is built entirely in Bash and relies on two battle-tested tools:

| Tool | Purpose |
|---|---|
| **inotifywait** (part of `inotify-tools`) | Watches directories for filesystem events at the kernel level |
| **rclone** | Transfers files to and from Google Drive using its API |

---

## Features

- 🔄 **Real-time sync** — Changes are detected and uploaded within seconds using Linux kernel `inotify` events
- 🛡️ **Daemon management** — Full `start` / `stop` / `restart` / `status` control via PID files
- ⚙️ **External configuration** — All parameters (paths, exclusions, size limits) live in a single config file
- ✅ **Pre-flight validation** — Checks for required tools, network connectivity, and valid arguments before taking any action
- 📝 **Detailed logging** — Every operation, warning, and error is written to a timestamped log file
- 🚫 **Ignore rules** — Skip files by extension, name pattern, or file size threshold
- 🔌 **Network-aware** — Gracefully handles offline conditions; retries when connectivity is restored
- 🧩 **Modular codebase** — Clean, well-commented functions using `if`, `while`, `for`, and `case` constructs

---

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                        Flow Daemon                           │
│                                                              │
│  1. inotifywait monitors the configured local directory      │
│          │                                                   │
│          ▼  (file created / modified / deleted)              │
│  2. Validation layer                                         │
│     ├── Is rclone installed?                                 │
│     ├── Is inotifywait installed?                            │
│     ├── Is the network reachable?                            │
│     └── Is the file on the ignore list?                      │
│          │                                                   │
│          ▼  (all checks pass)                                │
│  3. rclone copies / syncs the change to Google Drive         │
│          │                                                   │
│          ▼                                                   │
│  4. Event is written to the log file with a timestamp        │
└──────────────────────────────────────────────────────────────┘
```

The daemon runs as a background process. Its PID is stored in a lock file so that `stop` and `restart` commands can find and signal the process reliably.

---

## Prerequisites

Before installing Flow, make sure the following are available on your system:

| Requirement | Version | Notes |
|---|---|---|
| Bash | ≥ 4.0 | Pre-installed on most Linux distributions |
| inotify-tools | latest | Provides `inotifywait`; install via package manager |
| rclone | latest | Cloud sync tool; see [rclone.org](https://rclone.org) |
| Google Drive remote | configured | An `rclone` remote must be set up before first use |

### Installing Dependencies

**Debian / Ubuntu:**
```bash
sudo apt update
sudo apt install inotify-tools
```

**Fedora / RHEL / CentOS:**
```bash
sudo dnf install inotify-tools
```

**Arch Linux:**
```bash
sudo pacman -S inotify-tools
```

**Install rclone:**
```bash
curl https://rclone.org/install.sh | sudo bash
```

### Configuring rclone with Google Drive

Run the interactive setup wizard and follow the prompts to authorise rclone with your Google account:

```bash
rclone config
```

Choose `n` (new remote), name it (e.g. `gdrive`), select **Google Drive** as the storage type, and complete the OAuth flow. The remote name you choose here must match the `RCLONE_REMOTE` value in Flow's configuration file.

---

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/mslotwinski-dev/Flow.git
cd Flow

# 2. Make the script executable
chmod +x flow.sh

# 3. Copy the default configuration file to your home directory
cp flow.conf.example ~/.flow.conf

# 4. Edit the configuration file to match your environment
nano ~/.flow.conf

# 5. (Optional) Install system-wide
sudo cp flow.sh /usr/local/bin/flow
```

---

## Configuration

Flow reads all its settings from a configuration file. By default it looks for `~/.flow.conf`, but you can point it at any file by setting the `FLOW_CONFIG` environment variable.

### Configuration File Reference

```bash
# ─────────────────────────────────────────────
#  Flow Configuration File  (~/.flow.conf)
# ─────────────────────────────────────────────

# Absolute path to the local directory you want to keep synced.
WATCH_DIR="$HOME/Documents"

# rclone remote name and destination folder on Google Drive.
# Format: <remote-name>:<path-on-drive>
RCLONE_REMOTE="gdrive:Backups/Flow"

# Path to the log file. The directory must exist and be writable.
LOG_FILE="$HOME/.local/share/flow/flow.log"

# Path to the PID file used for daemon management.
PID_FILE="/tmp/flow.pid"

# Maximum file size (in megabytes) to sync. Files larger than this
# value are skipped and a warning is written to the log.
MAX_FILE_SIZE_MB=100

# Space-separated list of file extensions to ignore (without the dot).
# Example: "tmp swp bak"
IGNORED_EXTENSIONS="tmp swp bak log"

# Space-separated list of filename patterns to ignore (glob syntax).
# Example: ".git* *~"
IGNORED_PATTERNS=".git* *~ *.part"

# Delay in seconds between detecting a change and triggering a sync.
# A short debounce prevents a burst of events from causing many uploads.
SYNC_DELAY=2

# Number of times rclone will retry a failed transfer before giving up.
RCLONE_RETRIES=3
```

### Configuration Tips

- Use **absolute paths** for `WATCH_DIR` and `LOG_FILE` to avoid issues when the daemon is started from different working directories.
- A good `SYNC_DELAY` value is 1–5 seconds. A lower value is more responsive but may cause redundant uploads during rapid saves (e.g. text editors that write temporary files).
- Add large binary or build-artifact directories to `IGNORED_PATTERNS` (e.g. `node_modules .git`) to avoid unnecessary uploads.

---

## User Manual

Once the configuration file is in place, all interaction with Flow happens through a single command with subcommands.

### Synopsis

```
flow <command> [options]
```

---

### Starting the Daemon

```bash
flow start
```

Starts the Flow daemon in the background. It will:

1. Validate the configuration and all required tools.
2. Check network connectivity to Google Drive.
3. Fork to the background and write its PID to `PID_FILE`.
4. Begin watching `WATCH_DIR` for filesystem events.
5. Log the startup message to `LOG_FILE`.

**Expected output:**
```
[INFO] Flow daemon started (PID 12345)
[INFO] Watching: /home/user/Documents -> gdrive:Backups/Flow
```

> **Note:** If the daemon is already running, `start` will print a warning and exit without starting a second instance.

---

### Stopping the Daemon

```bash
flow stop
```

Gracefully stops the running daemon by sending `SIGTERM` to the process recorded in `PID_FILE`. The PID file is removed upon successful shutdown.

**Expected output:**
```
[INFO] Stopping Flow daemon (PID 12345)...
[INFO] Flow daemon stopped.
```

---

### Restarting the Daemon

```bash
flow restart
```

Equivalent to running `flow stop` followed by `flow start`. Useful after modifying the configuration file.

---

### Checking Status

```bash
flow status
```

Displays whether the daemon is currently running, its PID, and the directory being watched.

**Example output (running):**
```
● Flow is running
  PID:       12345
  Watching:  /home/user/Documents
  Remote:    gdrive:Backups/Flow
  Log file:  /home/user/.local/share/flow/flow.log
```

**Example output (stopped):**
```
○ Flow is not running
```

---

### Viewing Logs

Flow does not provide a dedicated log command, but since all output goes to a plain text file you can use standard Unix tools:

```bash
# Follow the log in real time
tail -f ~/.local/share/flow/flow.log

# Show the last 50 lines
tail -n 50 ~/.local/share/flow/flow.log

# Search for errors
grep '\[ERROR\]' ~/.local/share/flow/flow.log

# Search for a specific filename
grep 'report.pdf' ~/.local/share/flow/flow.log
```

### Log Format

Each log entry follows this format:

```
[YYYY-MM-DD HH:MM:SS] [LEVEL] Message
```

| Level | Meaning |
|---|---|
| `INFO` | Normal operation (file synced, daemon started/stopped) |
| `WARN` | Non-fatal issue (file skipped due to size/ignore rule, retry attempt) |
| `ERROR` | Sync failure or unrecoverable condition |

**Example log entries:**
```
[2026-03-15 09:12:04] [INFO]  Daemon started. Watching /home/user/Documents
[2026-03-15 09:13:22] [INFO]  MODIFY event: report.pdf — syncing to gdrive:Backups/Flow
[2026-03-15 09:13:24] [INFO]  Sync successful: report.pdf (245 KB, 1.8s)
[2026-03-15 09:15:01] [WARN]  Skipping archive.zip: exceeds MAX_FILE_SIZE_MB (100 MB)
[2026-03-15 09:20:33] [ERROR] Network unreachable. Will retry in 30s.
[2026-03-15 09:21:03] [INFO]  Network restored. Resuming sync.
```

---

## Examples

### Sync your Documents folder to Google Drive

```bash
# ~/.flow.conf
WATCH_DIR="$HOME/Documents"
RCLONE_REMOTE="gdrive:Backups/Documents"
```

```bash
flow start
# → Daemon starts watching ~/Documents
```

### Sync a project directory, ignoring build artefacts

```bash
# ~/.flow.conf
WATCH_DIR="$HOME/projects/my-app"
RCLONE_REMOTE="gdrive:Dev/my-app"
IGNORED_PATTERNS=".git* node_modules dist build *.log"
```

### Auto-start Flow on login (systemd user service)

Create `~/.config/systemd/user/flow.service`:

```ini
[Unit]
Description=Flow Google Drive Sync Daemon
After=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/flow start
ExecStop=/usr/local/bin/flow stop
Restart=on-failure

[Install]
WantedBy=default.target
```

Enable and start:

```bash
systemctl --user enable flow
systemctl --user start flow
```

---

## Troubleshooting

### Daemon fails to start

| Symptom | Likely cause | Fix |
|---|---|---|
| `command not found: inotifywait` | `inotify-tools` not installed | Install it via your package manager (see [Prerequisites](#prerequisites)) |
| `command not found: rclone` | `rclone` not installed | Follow the rclone installation steps |
| `rclone remote not configured` | rclone has no Google Drive remote | Run `rclone config` and set up a remote |
| `WATCH_DIR does not exist` | Path in config is wrong or missing | Correct `WATCH_DIR` in `~/.flow.conf` and create the directory if needed |
| `PID file already exists` | A previous instance did not shut down cleanly | Delete the stale PID file: `rm /tmp/flow.pid`, then retry |

### Files are not being synced

- Check the log file for `[WARN]` or `[ERROR]` entries.
- Verify your rclone remote works independently: `rclone lsd gdrive:`
- Ensure the file is not matched by `IGNORED_EXTENSIONS` or `IGNORED_PATTERNS`.
- Confirm the file is smaller than `MAX_FILE_SIZE_MB`.

### High CPU usage

- Increase `SYNC_DELAY` to reduce the frequency of rclone invocations.
- Add high-churn directories (e.g. `node_modules`, `.git`) to `IGNORED_PATTERNS`.

### Log file grows too large

You can rotate the log manually or set up **logrotate**:

```
# /etc/logrotate.d/flow
/home/YOUR_USER/.local/share/flow/flow.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

---

## Project Specification

### Technical Architecture

| Component | Description |
|---|---|
| **Daemon core** | A Bash script that forks into the background using `&` and `disown`, stores its PID, and traps `SIGTERM`/`SIGINT` for clean shutdown |
| **Filesystem watcher** | `inotifywait` in monitor mode (`--monitor`) watches for `CLOSE_WRITE`, `MOVED_TO`, and `DELETE` events |
| **Sync engine** | `rclone copy` / `rclone delete` called per-file for fine-grained control; `rclone sync` is available as an optional full-sync mode |
| **Configuration loader** | Sources the config file with Bash `source` after validating that all required variables are set |
| **Validation layer** | Pre-start checks using `command -v`, `ping`/`curl`, and `[[ -d ]]` / `[[ -f ]]` guards |
| **Logger** | A `log()` function that writes to both `stdout` (when interactive) and the log file with ISO 8601 timestamps |

### Code Structure

```
Flow/
├── flow.sh           # Main entry point; parses the command argument
├── flow.conf.example # Annotated configuration template
├── LICENSE           # MIT License
└── README.md         # This file
```

### Internal Function Overview

| Function | Responsibility |
|---|---|
| `load_config()` | Sources and validates the configuration file |
| `check_dependencies()` | Verifies that `inotifywait` and `rclone` are installed |
| `check_network()` | Tests connectivity to Google's servers before attempting a sync |
| `start_daemon()` | Forks the watcher loop to the background and records the PID |
| `stop_daemon()` | Reads the PID file and sends `SIGTERM` to the daemon process |
| `restart_daemon()` | Calls `stop_daemon()` then `start_daemon()` |
| `show_status()` | Reads the PID file and reports whether the process is alive |
| `watch_loop()` | The main event loop driven by `inotifywait` output |
| `handle_event()` | Applies ignore rules and invokes rclone for a single event |
| `sync_file()` | Wraps `rclone copy` with retry logic |
| `log()` | Formats and writes a timestamped log entry |

### Design Decisions

- **PID-file daemon pattern** rather than systemd integration keeps the tool dependency-free and portable across any Unix system with Bash ≥ 4.
- **Per-file sync** (`rclone copy <file>`) rather than a full `rclone sync` avoids overwriting remote changes and is significantly faster for large directories.
- **Debounce delay** (`SYNC_DELAY`) prevents a flood of uploads when editors create temporary files during a save operation.
- **No background threads** — the single event loop processes events sequentially, which is simpler to reason about and avoids race conditions.

---

## Contributing

Contributions, bug reports, and feature requests are welcome!

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-improvement`
3. Commit your changes: `git commit -m "Add my improvement"`
4. Push to the branch: `git push origin feature/my-improvement`
5. Open a Pull Request

Please follow the existing code style (4-space indentation, lowercase variable names, comments above each function) and test your changes on a real Linux system before submitting.

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

Copyright © 2026 [Mateusz Słotwiński](https://github.com/mslotwinski-dev)
