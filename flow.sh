#!/bin/bash

################################################################################
#
# Flow - Real-time Google Drive sync daemon for Unix systems
# Version: 1.0
# Author: Mateusz Słotwiński
# License: MIT
#
# A Bash daemon that automates real-time synchronization of local directories
# with Google Drive using inotify for file monitoring and rclone for cloud sync.
#
################################################################################

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Global Variables
# ─────────────────────────────────────────────────────────────────────────────

FLOW_VERSION="1.0"
FLOW_CONFIG="${FLOW_CONFIG:-$HOME/.flow.conf}"
FLOW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Default config values (can be overridden by config file)
WATCH_DIR=""
RCLONE_REMOTE=""
LOG_FILE=""
PID_FILE="/tmp/flow.pid"
MAX_FILE_SIZE_MB=100
IGNORED_EXTENSIONS=""
IGNORED_PATTERNS=""
SYNC_DELAY=2
RCLONE_RETRIES=3

# Runtime state
DAEMON_PID=""
IS_DAEMON=false

# ─────────────────────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────────────────────

# log <level> <message>
# Writes a timestamped log entry to both stdout (if interactive) and log file
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"

    # Write to stdout if interactive (not a daemon)
    if [[ "${IS_DAEMON}" != "true" ]]; then
        echo "$log_entry" >&2
    fi

    # Write to log file if configured
    if [[ -n "$LOG_FILE" ]]; then
        # Ensure log directory exists
        local log_dir=$(dirname "$LOG_FILE")
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || true
        fi

        # Append to log file (suppress errors if permission denied)
        echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# load_config
# Sources the configuration file and validates all required variables are set
load_config() {
    if [[ ! -f "$FLOW_CONFIG" ]]; then
        log "ERROR" "Configuration file not found: $FLOW_CONFIG"
        log "ERROR" "Copy the template: cp flow.conf.example ~/.flow.conf"
        return 1
    fi

    # Source the configuration file
    # Note: This happens in a subshell to catch errors, but we need it in current shell
    if ! source "$FLOW_CONFIG" 2>/dev/null; then
        log "ERROR" "Failed to parse configuration file: $FLOW_CONFIG"
        return 1
    fi

    # Validate required variables
    local required_vars=("WATCH_DIR" "RCLONE_REMOTE" "LOG_FILE" "PID_FILE")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log "ERROR" "Configuration variable '$var' not set in $FLOW_CONFIG"
            return 1
        fi
    done

    return 0
}

# check_dependencies
# Verifies that all required tools are installed
check_dependencies() {
    local missing_tools=()

    if ! command -v inotifywait &>/dev/null; then
        missing_tools+=("inotifywait (from inotify-tools package)")
    fi

    if ! command -v rclone &>/dev/null; then
        missing_tools+=("rclone")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            log "ERROR" "  - $tool"
        done
        return 1
    fi

    return 0
}

# check_network
# Tests connectivity to Google's servers
check_network() {
    # Try to reach Google's DNS first (fast)
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        return 0
    fi

    # Fallback: try HTTPS to Google
    if curl -s --connect-timeout 2 https://www.google.com > /dev/null 2>&1; then
        return 0
    fi

    log "WARN" "Network connectivity check failed. Will attempt sync anyway."
    return 0  # Don't fail completely, network might be restored by next event
}

# check_rclone_remote
# Verifies that the rclone remote is configured and accessible
check_rclone_remote() {
    local remote_name="${RCLONE_REMOTE%%:*}"

    if ! rclone listremotes 2>/dev/null | grep -q "^${remote_name}:$"; then
        log "ERROR" "rclone remote not configured: $remote_name"
        log "ERROR" "Run 'rclone config' to set up a Google Drive remote"
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Daemon Lifecycle Functions
# ─────────────────────────────────────────────────────────────────────────────

# is_daemon_running
# Checks if a daemon process is currently running by testing the PID
is_daemon_running() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 1  # PID file doesn't exist, daemon not running
    fi

    local pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -z "$pid" ]]; then
        return 1  # PID file is empty
    fi

    # Check if process with that PID is actually running
    if kill -0 "$pid" 2>/dev/null; then
        return 0  # Process is running
    else
        return 1  # Process is not running
    fi
}

# run_daemon
# Internal function that runs the daemon event loop
# This is called in the background by start_daemon
run_daemon() {
    # Set up signal handlers for clean shutdown
    trap 'kill %1 2>/dev/null; exit 0' SIGTERM SIGINT

    # Start the main event loop in the background
    inotifywait --monitor --quiet --recursive \
        -e CLOSE_WRITE -e MOVED_TO -e DELETE \
        "$WATCH_DIR" |
    while read -r directory event filename; do
        handle_event "$directory" "$event" "$filename"
    done &

    # Get the PID of the inotifywait process (the last background job's child)
    # We use a bit of a trick here: find the inotifywait process that we just started
    sleep 0.5
    local inotify_pid=$(pgrep -f "inotifywait.*$WATCH_DIR" | head -1)

    if [[ -n "$inotify_pid" ]]; then
        echo "$inotify_pid" > "$PID_FILE"
        log "INFO" "Daemon started (PID $inotify_pid)"
        log "INFO" "Watching: $WATCH_DIR → $RCLONE_REMOTE"
        log "INFO" "Event loop started"
    fi

    # Wait for the background process to finish (it won't, inotifywait runs forever)
    wait
}

# start_daemon
# Starts the Flow daemon with full validation
start_daemon() {
    # Pre-flight validation
    log "INFO" "Starting Flow daemon..."

    # 1. Load and validate configuration
    if ! load_config; then
        return 1
    fi

    # 2. Validate watch directory
    if [[ ! -d "$WATCH_DIR" ]]; then
        log "ERROR" "Watch directory does not exist: $WATCH_DIR"
        return 1
    fi

    if [[ ! -r "$WATCH_DIR" ]]; then
        log "ERROR" "Watch directory is not readable: $WATCH_DIR"
        return 1
    fi

    # 3. Validate log directory is writable
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            log "ERROR" "Cannot create log directory: $log_dir"
            return 1
        fi
    fi

    if [[ ! -w "$log_dir" ]]; then
        log "ERROR" "Log directory is not writable: $log_dir"
        return 1
    fi

    # 4. Check for required tools
    if ! check_dependencies; then
        return 1
    fi

    # 5. Verify rclone remote is configured
    if ! check_rclone_remote; then
        return 1
    fi

    # 6. Check network connectivity
    check_network

    # 7. Check if daemon is already running
    if is_daemon_running; then
        log "WARN" "Flow daemon is already running (PID: $(cat "$PID_FILE"))"
        return 0  # Not an error, just informational
    fi

    # 8. Clean up stale PID file if it exists
    if [[ -f "$PID_FILE" ]]; then
        rm -f "$PID_FILE" 2>/dev/null || true
    fi

    # 9. Fork to background and start the daemon
    (run_daemon) > /dev/null 2>&1 &
    local bg_pid=$!
    disown $bg_pid

    sleep 1  # Give daemon a moment to start and write PID file

    # Verify daemon actually started
    if is_daemon_running; then
        log "INFO" "Daemon is now running"
        return 0
    else
        log "ERROR" "Failed to start daemon"
        rm -f "$PID_FILE" 2>/dev/null || true
        return 1
    fi
}

# stop_daemon
# Gracefully stops the running daemon
stop_daemon() {
    # Load config first to get correct PID_FILE
    if ! load_config 2>/dev/null; then
        log "WARN" "Could not load config, trying default PID file"
    fi

    if ! is_daemon_running; then
        log "WARN" "Daemon is not running"
        return 0
    fi

    local pid=$(cat "$PID_FILE" 2>/dev/null)
    log "INFO" "Stopping Flow daemon (PID $pid)..."

    # Send SIGTERM to the daemon
    if kill -TERM "$pid" 2>/dev/null; then
        # Wait up to 5 seconds for graceful shutdown
        local count=0
        while [[ $count -lt 50 ]]; do
            if ! kill -0 "$pid" 2>/dev/null; then
                # Process has exited
                log "INFO" "Daemon stopped gracefully"
                rm -f "$PID_FILE" 2>/dev/null || true
                return 0
            fi
            sleep 0.1
            ((count++))
        done

        # If still running, kill forcefully
        log "WARN" "Daemon did not stop gracefully, forcing kill..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
    fi

    rm -f "$PID_FILE" 2>/dev/null || true
    log "INFO" "Daemon stopped"
    return 0
}

# restart_daemon
# Restarts the daemon (stop then start)
restart_daemon() {
    log "INFO" "Restarting Flow daemon..."
    stop_daemon
    sleep 1
    start_daemon
}

# show_status
# Displays the current status of the daemon
show_status() {
    # Load config first to get correct PID_FILE and other settings
    if ! load_config 2>/dev/null; then
        echo "○ Flow is not running"
        return 0
    fi

    if is_daemon_running; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)

        echo "● Flow is running"
        echo "  PID:       $pid"
        echo "  Watching:  $WATCH_DIR"
        echo "  Remote:    $RCLONE_REMOTE"
        echo "  Log file:  $LOG_FILE"
        return 0
    else
        echo "○ Flow is not running"
        return 0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Event Watching and Processing
# ─────────────────────────────────────────────────────────────────────────────

# declare -A for debounce tracking (Bash 4+ required)
declare -A LAST_SYNC_TIME

# should_ignore_file <filepath>
# Returns 0 (success) if file should be ignored, 1 otherwise
should_ignore_file() {
    local filepath="$1"
    local filename=$(basename "$filepath")

    # Check ignored patterns
    if [[ -n "$IGNORED_PATTERNS" ]]; then
        for pattern in $IGNORED_PATTERNS; do
            if [[ "$filename" == $pattern ]]; then
                log "WARN" "Ignoring $filename: matches pattern '$pattern'"
                return 0
            fi
        done
    fi

    # Check ignored extensions
    if [[ -n "$IGNORED_EXTENSIONS" ]]; then
        local ext="${filename##*.}"
        if [[ "$ext" != "$filename" ]]; then  # Has an extension
            for ignored_ext in $IGNORED_EXTENSIONS; do
                if [[ "$ext" == "$ignored_ext" ]]; then
                    log "WARN" "Ignoring $filename: has ignored extension '.$ext'"
                    return 0
                fi
            done
        fi
    fi

    # Check file size (only for regular files that exist)
    if [[ -f "$filepath" && "$MAX_FILE_SIZE_MB" -gt 0 ]]; then
        local size_bytes=$(stat --printf="%s" "$filepath" 2>/dev/null || echo 0)
        local max_bytes=$((MAX_FILE_SIZE_MB * 1024 * 1024))

        if [[ $size_bytes -gt $max_bytes ]]; then
            local size_mb=$((size_bytes / 1024 / 1024))
            log "WARN" "Ignoring $filename: exceeds MAX_FILE_SIZE_MB ($size_mb > $MAX_FILE_SIZE_MB)"
            return 0
        fi
    fi

    return 1  # Don't ignore this file
}

# should_debounce <filepath>
# Returns 0 (success) if event is within debounce window, 1 otherwise
should_debounce() {
    local filepath="$1"
    local current_time=$(date +%s)
    local last_sync=${LAST_SYNC_TIME[$filepath]:-0}
    local time_since_sync=$((current_time - last_sync))

    if [[ $time_since_sync -lt $SYNC_DELAY ]]; then
        return 0  # Still in debounce window
    fi

    return 1  # Debounce window has passed
}

# handle_event <directory> <event> <filename>
# Processes a single filesystem event
# Note: event may be comma-separated (e.g., "CLOSE_WRITE,CLOSE"); directory may have trailing slash
handle_event() {
    local directory="$1"
    local event="$2"
    local filename="$3"
    
    # Remove trailing slash from directory if present
    directory="${directory%/}"
    
    local filepath="$directory/$filename"

    # Check if file should be ignored
    if should_ignore_file "$filepath"; then
        return 0
    fi

    # Determine event type by checking if event string contains various event types
    # Note: inotifywait can report multiple events (e.g., "CLOSE_WRITE,CLOSE")
    #       We check for the primary event type we care about
    
    if [[ "$event" == *"DELETE"* ]]; then
        # This is a DELETE event
        sync_file_delete "$filepath"
    elif [[ "$event" == *"CLOSE_WRITE"* ]] || [[ "$event" == *"MOVED_TO"* ]]; then
        # Check debounce window for creation/modification events only
        if ! should_debounce "$filepath"; then
            sync_file_copy "$filepath"
            LAST_SYNC_TIME[$filepath]=$(date +%s)
        fi
    else
        # Unknown or unhandled event type
        log "WARN" "Unhandled event for $filename: $event"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud Sync Functions (Phase 4)
# ─────────────────────────────────────────────────────────────────────────────

# sync_file_copy <filepath>
# Uploads or updates a file to rclone remote with retry logic
sync_file_copy() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    local start_time=$(date +%s%N)

    # Get file size for logging
    local size_bytes=$(stat --printf="%s" "$filepath" 2>/dev/null || echo 0)
    local size_kb=$((size_bytes / 1024))

    log "INFO" "Syncing: $filename ($size_kb KB)"

    # Build rclone command (copy single file)
    # rclone copy <source> <dest:<path>>
    # We need to copy just this file to the remote

    local retry_count=0
    while [[ $retry_count -le $RCLONE_RETRIES ]]; do
        if rclone copy "$filepath" "$RCLONE_REMOTE" --progress=false 2>/dev/null; then
            # Success
            local end_time=$(date +%s%N)
            local duration_ms=$(( (end_time - start_time) / 1000000 ))
            local duration_s=$(echo "scale=2; $duration_ms / 1000" | bc 2>/dev/null || echo "0")

            log "INFO" "✓ Synced: $filename ($size_kb KB in ${duration_s}s)"
            return 0
        fi

        # Retry logic
        ((retry_count++))
        if [[ $retry_count -le $RCLONE_RETRIES ]]; then
            local wait_time=$((2 ** retry_count))  # Exponential backoff: 2, 4, 8, 16...
            log "WARN" "Sync failed for $filename, retry $retry_count/$RCLONE_RETRIES (waiting ${wait_time}s)"
            sleep "$wait_time"
        fi
    done

    # All retries exhausted
    log "ERROR" "Failed to sync $filename after $RCLONE_RETRIES retries"
    return 1
}

# sync_file_delete <filepath>
# Deletes a file from the rclone remote with retry logic
sync_file_delete() {
    local filepath="$1"
    local filename=$(basename "$filepath")

    log "INFO" "Deleting: $filename"

    local retry_count=0
    while [[ $retry_count -le $RCLONE_RETRIES ]]; do
        # rclone delete <remote>/<path>
        # Extract just the filename for the remote path
        if rclone delete "$RCLONE_REMOTE/$filename" --progress=false 2>/dev/null; then
            log "INFO" "✓ Deleted: $filename"
            return 0
        fi

        # Retry logic
        ((retry_count++))
        if [[ $retry_count -le $RCLONE_RETRIES ]]; then
            local wait_time=$((2 ** retry_count))
            log "WARN" "Delete failed for $filename, retry $retry_count/$RCLONE_RETRIES (waiting ${wait_time}s)"
            sleep "$wait_time"
        fi
    done

    # All retries exhausted
    log "ERROR" "Failed to delete $filename after $RCLONE_RETRIES retries"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Command Routing and Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────

# show_usage
# Displays help text
show_usage() {
    cat << EOF
Usage: $FLOW_SCRIPT_NAME [COMMAND] [OPTIONS]

Commands:
    start           Start the Flow daemon
    stop            Stop the Flow daemon
    restart         Restart the Flow daemon
    status          Show the status of the daemon
    --help, -h      Show this help message
    --version, -v   Show version information

Examples:
    $FLOW_SCRIPT_NAME start
    $FLOW_SCRIPT_NAME stop
    $FLOW_SCRIPT_NAME status

Configuration:
    By default, Flow reads from ~/.flow.conf
    Override with: export FLOW_CONFIG=/path/to/config

For more information, see: https://github.com/mslotwinski-dev/Flow

EOF
}

# show_version
# Displays version information
show_version() {
    cat << EOF
Flow v$FLOW_VERSION
Real-time Google Drive sync daemon for Unix systems

Copyright © 2026 Mateusz Słotwiński
Licensed under the MIT License
EOF
}

# Main entry point
main() {
    local command="${1:-help}"

    case "$command" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            restart_daemon
            ;;
        status)
            show_status
            ;;
        --version|-v)
            show_version
            ;;
        --help|-h|help)
            show_usage
            ;;
        "")
            show_usage
            exit 0
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Only run main if this script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
