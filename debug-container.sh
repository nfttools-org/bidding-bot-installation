#!/bin/bash

# =============================================================================
# Docker Container Debug Script
# =============================================================================
# This script helps diagnose issues with the bidding-bot Docker containers
# including crashes, restarts, OOM kills, and performance issues.
#
# Usage: ./debug-container.sh [command]
# Commands:
#   status      - Show container status and health
#   logs        - Show recent container logs
#   events      - Show Docker events (restarts, OOM, etc.)
#   inspect     - Detailed container inspection
#   resources   - Show resource usage (CPU, memory)
#   lifecycle   - Show process lifecycle logs
#   redis       - Redis connection and memory diagnostics
#   mongodb     - MongoDB connection pool and query diagnostics
#   health      - Application health endpoint checks
#   memory      - Node.js heap and memory analysis
#   network     - DNS resolution and API connectivity
#   queue       - BullMQ queue and worker diagnostics
#   crash       - Analyze recent crash/restart
#   all         - Run all diagnostics
#   watch       - Live monitoring mode
#   export      - Export all debug info to file (with optional HTTP serve)
#   snapshot    - Take immediate diagnostic snapshot
#   monitor     - Start periodic snapshot daemon (hourly)
#   crashes     - Watch for crashes and auto-capture snapshots
#   snapshots   - List saved snapshots
#   stop-monitor - Stop monitoring daemons
#   download    - Create zip and serve via HTTP for easy download
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Container names
SERVER_CONTAINER="nft-bidding-bot-server-1"
CLIENT_CONTAINER="nft-bidding-bot-client-1"
REDIS_CONTAINER="redis"
MONGO_CONTAINER="mongodb_container"

# Alternative container name patterns (docker compose may use different naming)
get_container_name() {
    local pattern=$1
    local name=$(docker ps -a --format '{{.Names}}' | grep -E "$pattern" | head -1)
    echo "${name:-$pattern}"
}

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

# =============================================================================
# STATUS - Container status and health
# =============================================================================
show_status() {
    print_header "CONTAINER STATUS"

    echo -e "\n${YELLOW}All Containers:${NC}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(bidding|redis|mongo|NAMES)" || echo "No containers found"

    print_subheader "Health Checks"
    for container in $(docker ps --format '{{.Names}}' | grep -E "(bidding|redis|mongo)"); do
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no healthcheck")
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        restarts=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "0")

        if [ "$status" = "running" ] && [ "$health" != "unhealthy" ]; then
            echo -e "${GREEN}✓${NC} $container: $status (health: $health, restarts: $restarts)"
        else
            echo -e "${RED}✗${NC} $container: $status (health: $health, restarts: $restarts)"
        fi
    done

    print_subheader "Server Container Details"
    SERVER=$(get_container_name "server")
    if docker ps -a --format '{{.Names}}' | grep -q "$SERVER"; then
        docker inspect "$SERVER" --format '
Container ID: {{.Id}}
Created: {{.Created}}
Started: {{.State.StartedAt}}
Restart Count: {{.RestartCount}}
Exit Code: {{.State.ExitCode}}
OOM Killed: {{.State.OOMKilled}}
Error: {{.State.Error}}
' 2>/dev/null || echo "Could not inspect server container"
    else
        echo "Server container not found"
    fi
}

# =============================================================================
# LOGS - Recent container logs
# =============================================================================
show_logs() {
    local lines=${1:-100}

    print_header "CONTAINER LOGS (last $lines lines)"

    print_subheader "Server Logs"
    SERVER=$(get_container_name "server")
    docker logs --tail "$lines" "$SERVER" 2>&1 || echo "Could not get server logs"

    print_subheader "Server Errors Only"
    docker logs "$SERVER" 2>&1 | grep -iE "(error|exception|crash|oom|kill|fatal)" | tail -20 || echo "No errors found"
}

# =============================================================================
# EVENTS - Docker events (restarts, OOM, etc.)
# =============================================================================
show_events() {
    print_header "DOCKER EVENTS (last 24 hours)"

    local since=$(date -d '24 hours ago' --iso-8601=seconds 2>/dev/null || date -v-24H '+%Y-%m-%dT%H:%M:%S')

    echo -e "${YELLOW}Container Events:${NC}"
    docker events --since "$since" --until "$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" \
        --filter 'type=container' \
        --filter 'event=die' \
        --filter 'event=kill' \
        --filter 'event=oom' \
        --filter 'event=restart' \
        --filter 'event=start' \
        --filter 'event=stop' \
        --format '{{.Time}} {{.Actor.Attributes.name}}: {{.Action}} (exit={{.Actor.Attributes.exitCode}})' 2>/dev/null \
        | grep -E "(bidding|server)" | tail -50 || echo "No recent events found"

    print_subheader "Restart History"
    SERVER=$(get_container_name "server")
    if docker ps -a --format '{{.Names}}' | grep -q "$SERVER"; then
        restarts=$(docker inspect --format='{{.RestartCount}}' "$SERVER" 2>/dev/null || echo "0")
        last_start=$(docker inspect --format='{{.State.StartedAt}}' "$SERVER" 2>/dev/null || echo "unknown")
        oom=$(docker inspect --format='{{.State.OOMKilled}}' "$SERVER" 2>/dev/null || echo "false")

        echo "Total Restarts: $restarts"
        echo "Last Started: $last_start"
        echo "OOM Killed: $oom"

        if [ "$oom" = "true" ]; then
            echo -e "${RED}⚠️  Container was killed due to Out Of Memory!${NC}"
        fi
    fi
}

# =============================================================================
# INSPECT - Detailed container inspection
# =============================================================================
show_inspect() {
    print_header "DETAILED CONTAINER INSPECTION"

    SERVER=$(get_container_name "server")

    print_subheader "Container State"
    docker inspect "$SERVER" --format '
Status: {{.State.Status}}
Running: {{.State.Running}}
Paused: {{.State.Paused}}
Restarting: {{.State.Restarting}}
OOMKilled: {{.State.OOMKilled}}
Dead: {{.State.Dead}}
Pid: {{.State.Pid}}
ExitCode: {{.State.ExitCode}}
Error: {{.State.Error}}
StartedAt: {{.State.StartedAt}}
FinishedAt: {{.State.FinishedAt}}
' 2>/dev/null || echo "Could not inspect container"

    print_subheader "Memory Limits"
    docker inspect "$SERVER" --format '
Memory Limit: {{.HostConfig.Memory}}
Memory Swap: {{.HostConfig.MemorySwap}}
Memory Reservation: {{.HostConfig.MemoryReservation}}
OOM Kill Disable: {{.HostConfig.OomKillDisable}}
' 2>/dev/null || echo "Could not get memory config"

    print_subheader "Restart Policy"
    docker inspect "$SERVER" --format '
Restart Policy: {{.HostConfig.RestartPolicy.Name}}
Max Retry Count: {{.HostConfig.RestartPolicy.MaximumRetryCount}}
' 2>/dev/null || echo "Could not get restart policy"

    print_subheader "Volume Mounts"
    docker inspect "$SERVER" --format '{{range .Mounts}}
Type: {{.Type}}
Source: {{.Source}}
Destination: {{.Destination}}
{{end}}' 2>/dev/null || echo "Could not get mounts"

    print_subheader "Environment Variables (non-sensitive)"
    docker inspect "$SERVER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep -vE "(PASSWORD|SECRET|KEY|TOKEN)" \
        | head -20 || echo "Could not get env vars"
}

# =============================================================================
# RESOURCES - Resource usage
# =============================================================================
show_resources() {
    print_header "RESOURCE USAGE"

    print_subheader "Current Resource Usage"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" \
        | grep -E "(bidding|redis|mongo|NAME)" || echo "No containers running"

    print_subheader "Host System Memory"
    free -h 2>/dev/null || echo "free command not available"

    print_subheader "Host System Disk"
    df -h / 2>/dev/null | head -2 || echo "df command not available"

    print_subheader "Docker Disk Usage"
    docker system df 2>/dev/null || echo "Could not get Docker disk usage"
}

# =============================================================================
# LIFECYCLE - Process lifecycle logs
# =============================================================================
show_lifecycle() {
    print_header "PROCESS LIFECYCLE LOGS"

    # Check if volume is mounted and accessible
    SERVER=$(get_container_name "server")

    print_subheader "Checking for lifecycle logs in container"
    docker exec "$SERVER" ls -la /app/debug-logs/ 2>/dev/null | head -20 || echo "Could not list debug-logs directory"

    print_subheader "Recent Lifecycle Events"
    docker exec "$SERVER" sh -c 'cat /app/debug-logs/process-lifecycle-*.log 2>/dev/null | tail -50' 2>/dev/null \
        || echo "No lifecycle logs found (this is expected on first run)"

    print_subheader "Startup Logs"
    docker exec "$SERVER" sh -c 'cat /app/debug-logs/startup-*.log 2>/dev/null | tail -30' 2>/dev/null \
        || echo "No startup logs found"

    print_subheader "Error Logs (last 20 lines)"
    docker exec "$SERVER" sh -c 'cat /app/debug-logs/error-*.log 2>/dev/null | tail -20' 2>/dev/null \
        || echo "No error logs found"
}

# =============================================================================
# REDIS - Redis connection and memory diagnostics
# =============================================================================
show_redis() {
    print_header "REDIS DIAGNOSTICS"

    print_subheader "Redis Connection Status"
    docker exec redis redis-cli PING 2>/dev/null || echo "Redis not responding"

    print_subheader "Redis Memory Stats"
    docker exec redis redis-cli INFO memory 2>/dev/null | grep -E "(used_memory_human|used_memory_peak_human|maxmemory_human|mem_fragmentation_ratio)" || echo "Could not get memory stats"

    print_subheader "Redis Client Connections"
    docker exec redis redis-cli INFO clients 2>/dev/null | grep -E "(connected_clients|blocked_clients|tracking_clients)" || echo "Could not get client stats"
    echo ""
    docker exec redis redis-cli CLIENT LIST 2>/dev/null | wc -l | xargs echo "Total connected clients:"

    print_subheader "BullMQ Lock Keys (active jobs)"
    docker exec redis redis-cli KEYS "*:lock" 2>/dev/null | wc -l | xargs echo "Active job locks:"

    print_subheader "Queue Sizes"
    for queue in "BIDDING_BOT" "BLUR_BIDDING_QUEUE"; do
        waiting=$(docker exec redis redis-cli LLEN "bull:${queue}:wait" 2>/dev/null || echo "0")
        active=$(docker exec redis redis-cli LLEN "bull:${queue}:active" 2>/dev/null || echo "0")
        delayed=$(docker exec redis redis-cli ZCARD "bull:${queue}:delayed" 2>/dev/null || echo "0")
        failed=$(docker exec redis redis-cli ZCARD "bull:${queue}:failed" 2>/dev/null || echo "0")
        echo "${queue}: waiting=${waiting}, active=${active}, delayed=${delayed}, failed=${failed}"
    done

    print_subheader "Redis Slowlog (last 5 slow commands)"
    docker exec redis redis-cli SLOWLOG GET 5 2>/dev/null || echo "Could not get slowlog"
}

# =============================================================================
# MONGODB - MongoDB connection pool and query diagnostics
# =============================================================================
show_mongodb() {
    print_header "MONGODB DIAGNOSTICS"

    print_subheader "MongoDB Connection Status"
    docker exec mongodb_container mongosh --eval "db.adminCommand('ping')" --quiet 2>/dev/null && echo "MongoDB: OK" || echo "MongoDB not responding"

    print_subheader "Connection Pool Stats"
    docker exec mongodb_container mongosh --eval "db.serverStatus().connections" --quiet 2>/dev/null || echo "Could not get connection stats"

    print_subheader "Current Operations (long-running > 5s)"
    docker exec mongodb_container mongosh --eval "db.currentOp({'secs_running': {\$gte: 5}}).inprog.length" --quiet 2>/dev/null | xargs echo "Long-running operations:" || echo "Could not get current ops"

    print_subheader "Database Stats"
    docker exec mongodb_container mongosh BIDDING_BOT --eval "const s = db.stats(); print('Collections: ' + s.collections + ', Data Size: ' + (s.dataSize/1024/1024).toFixed(2) + ' MB, Index Size: ' + (s.indexSize/1024/1024).toFixed(2) + ' MB')" --quiet 2>/dev/null || echo "Could not get db stats"

    print_subheader "Collection Document Counts"
    docker exec mongodb_container mongosh BIDDING_BOT --eval "db.getCollectionNames().forEach(c => print(c + ': ' + db[c].countDocuments()))" --quiet 2>/dev/null | head -10 || echo "Could not get collection counts"
}

# =============================================================================
# HEALTH - Application health endpoint checks
# =============================================================================
show_health() {
    print_header "APPLICATION HEALTH"

    print_subheader "Server Health Endpoint"
    health_response=$(curl -s --max-time 5 http://localhost:3003/health 2>/dev/null)
    if [ -z "$health_response" ]; then
        echo -e "${RED}Health endpoint not responding (timeout or error)${NC}"
    else
        echo "$health_response" | jq '.' 2>/dev/null || echo "$health_response"
    fi

    print_subheader "Redis Health via API"
    curl -s --max-time 5 http://localhost:3003/api/health/redis 2>/dev/null | jq '.' 2>/dev/null || echo "Redis health endpoint not responding"

    print_subheader "Worker Metrics"
    curl -s --max-time 5 http://localhost:3003/metrics 2>/dev/null | jq '.workers' 2>/dev/null || echo "Metrics endpoint not responding"

    print_subheader "Queue Job Counts (from health endpoint)"
    echo "$health_response" | jq '.metrics.queue' 2>/dev/null || echo "Could not get queue counts"
}

# =============================================================================
# MEMORY - Node.js heap and memory analysis
# =============================================================================
show_memory() {
    print_header "MEMORY ANALYSIS"

    SERVER=$(get_container_name "server")

    print_subheader "Node.js Heap Usage (from health endpoint)"
    curl -s --max-time 5 http://localhost:3003/health 2>/dev/null | jq '.metrics.memory' 2>/dev/null || echo "Could not get memory metrics"

    print_subheader "Container Memory Usage"
    docker stats --no-stream --format "{{.Name}}: {{.MemUsage}} ({{.MemPerc}} of limit)" "$SERVER" 2>/dev/null || echo "Could not get container stats"

    print_subheader "Memory Limit Configuration"
    mem_limit=$(docker inspect "$SERVER" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
    if [ "$mem_limit" = "0" ]; then
        echo "Memory Limit: No limit set (container can use all host memory)"
    else
        echo "Memory Limit: $((mem_limit / 1024 / 1024)) MB"
    fi
    NODE_OPTS=$(docker inspect "$SERVER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep NODE_OPTIONS || echo "NODE_OPTIONS not set")
    echo "$NODE_OPTS"

    print_subheader "Process Memory Details (from container)"
    docker exec "$SERVER" sh -c 'cat /proc/1/status 2>/dev/null | grep -E "(VmRSS|VmSize|VmPeak|VmHWM)"' 2>/dev/null || echo "Could not get process memory"

    print_subheader "Memory Trend (last 10 lifecycle logs)"
    docker exec "$SERVER" sh -c 'grep -h "MEMORY_USAGE\|heapUsed" /app/debug-logs/process-lifecycle-*.log 2>/dev/null | tail -10' 2>/dev/null || echo "No memory logs found"
}

# =============================================================================
# NETWORK - DNS resolution and API connectivity
# =============================================================================
show_network() {
    print_header "NETWORK DIAGNOSTICS"

    SERVER=$(get_container_name "server")

    print_subheader "DNS Resolution Test"
    docker exec "$SERVER" sh -c 'getent hosts api.opensea.io >/dev/null 2>&1 && echo "OpenSea DNS: OK" || echo "OpenSea DNS: FAILED"' 2>/dev/null
    docker exec "$SERVER" sh -c 'getent hosts api.reservoir.tools >/dev/null 2>&1 && echo "Reservoir DNS: OK" || echo "Reservoir DNS: FAILED"' 2>/dev/null
    docker exec "$SERVER" sh -c 'getent hosts nfttools-ws-proxy.nfttools.io >/dev/null 2>&1 && echo "WebSocket Proxy DNS: OK" || echo "WebSocket Proxy DNS: FAILED"' 2>/dev/null

    print_subheader "External API Connectivity"
    docker exec "$SERVER" sh -c 'curl -s --max-time 5 -o /dev/null -w "OpenSea API: HTTP %{http_code} (%{time_total}s)\n" https://api.opensea.io/api/v2/collections/doodles-official 2>/dev/null' || echo "OpenSea API: UNREACHABLE"

    print_subheader "Open Network Connections"
    docker exec "$SERVER" sh -c 'cat /proc/net/sockstat 2>/dev/null | grep -E "(sockets|TCP)"' 2>/dev/null || echo "Could not get socket stats"

    print_subheader "WebSocket Status (from logs)"
    docker exec "$SERVER" sh -c 'grep -h "WebSocket\|WS\|websocket" /app/debug-logs/websocket-*.log 2>/dev/null | tail -10' 2>/dev/null || echo "No WebSocket logs found"

    print_subheader "Recent Network Errors"
    docker exec "$SERVER" sh -c 'grep -hiE "(ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|socket hang up)" /app/debug-logs/*.log 2>/dev/null | tail -10' 2>/dev/null || echo "No recent network errors"
}

# =============================================================================
# QUEUE - BullMQ queue and worker diagnostics
# =============================================================================
show_queue() {
    print_header "QUEUE & WORKER DIAGNOSTICS"

    SERVER=$(get_container_name "server")

    print_subheader "BullMQ Queue Counts (from health endpoint)"
    curl -s --max-time 5 http://localhost:3003/health 2>/dev/null | jq '.metrics.queue' 2>/dev/null || echo "Could not get queue counts"

    print_subheader "Stalled Jobs"
    stalled_main=$(docker exec redis redis-cli SCARD "bull:BIDDING_BOT:stalled" 2>/dev/null || echo "0")
    stalled_blur=$(docker exec redis redis-cli SCARD "bull:BLUR_BIDDING_QUEUE:stalled" 2>/dev/null || echo "0")
    echo "BIDDING_BOT stalled: $stalled_main"
    echo "BLUR_BIDDING_QUEUE stalled: $stalled_blur"
    if [ "$stalled_main" != "0" ] || [ "$stalled_blur" != "0" ]; then
        echo -e "${RED}⚠️  Stalled jobs detected! Workers may be hanging.${NC}"
    fi

    print_subheader "Failed Jobs Count"
    failed_main=$(docker exec redis redis-cli ZCARD "bull:BIDDING_BOT:failed" 2>/dev/null || echo "0")
    failed_blur=$(docker exec redis redis-cli ZCARD "bull:BLUR_BIDDING_QUEUE:failed" 2>/dev/null || echo "0")
    echo "BIDDING_BOT failed: $failed_main"
    echo "BLUR_BIDDING_QUEUE failed: $failed_blur"

    print_subheader "Active Jobs (may be stuck if running too long)"
    active_jobs=$(docker exec redis redis-cli LRANGE "bull:BIDDING_BOT:active" 0 9 2>/dev/null)
    if [ -z "$active_jobs" ]; then
        echo "No active jobs"
    else
        echo "Checking first 10 active jobs..."
        echo "$active_jobs" | while read -r jobId; do
            if [ ! -z "$jobId" ]; then
                started=$(docker exec redis redis-cli HGET "bull:BIDDING_BOT:$jobId" "processedOn" 2>/dev/null)
                name=$(docker exec redis redis-cli HGET "bull:BIDDING_BOT:$jobId" "name" 2>/dev/null)
                if [ ! -z "$started" ] && [ "$started" != "" ]; then
                    now_ms=$(($(date +%s) * 1000))
                    age_sec=$(( (now_ms - started) / 1000 ))
                    if [ "$age_sec" -gt 300 ]; then
                        echo -e "${RED}Job $jobId ($name): running for ${age_sec}s - POSSIBLY STUCK${NC}"
                    else
                        echo "Job $jobId ($name): running for ${age_sec}s"
                    fi
                fi
            fi
        done
    fi

    print_subheader "Worker Errors (from logs)"
    docker exec "$SERVER" sh -c 'grep -hiE "\[Worker\].*error|\[BullMQ\].*error|could not renew lock" /app/debug-logs/*.log 2>/dev/null | tail -10' 2>/dev/null || echo "No worker errors found"

    print_subheader "Job Processing Rate (from scheduler logs)"
    docker exec "$SERVER" sh -c 'grep -h "completed\|processed" /app/debug-logs/scheduler-*.log 2>/dev/null | tail -5' 2>/dev/null || echo "No scheduler logs found"
}

# =============================================================================
# ALL - Run all diagnostics
# =============================================================================
show_all() {
    show_status
    show_health
    show_redis
    show_mongodb
    show_memory
    show_network
    show_queue
    show_events
    show_resources
    show_lifecycle
    show_logs 50
    show_inspect
    analyze_crash
}

# =============================================================================
# WATCH - Live monitoring
# =============================================================================
watch_containers() {
    print_header "LIVE MONITORING (Ctrl+C to exit)"
    echo "Monitoring container stats and events..."
    echo ""

    # Start events monitor in background
    docker events --filter 'type=container' \
        --format '{{.Time}} [EVENT] {{.Actor.Attributes.name}}: {{.Action}}' &
    EVENTS_PID=$!

    # Trap to cleanup background process
    trap "kill $EVENTS_PID 2>/dev/null; exit" INT TERM

    # Show stats
    docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
}

# =============================================================================
# EXPORT - Export all debug info to file (with optional HTTP download)
# =============================================================================
export_debug() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="debug_export_${timestamp}.txt"
    local serve_http=${1:-false}
    local port=${2:-8888}
    local timeout_sec=${3:-300}

    print_header "EXPORTING DEBUG INFO"
    echo "Writing to: $output_file"

    {
        echo "Debug Export - $(date)"
        echo "=============================================="
        show_all
    } > "$output_file" 2>&1

    local file_size=$(du -h "$output_file" | cut -f1)
    echo -e "${GREEN}✓ Debug info exported to: $output_file ($file_size)${NC}"

    if [ "$serve_http" = "true" ] || [ "$serve_http" = "serve" ]; then
        # Get server IP
        local server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -z "$server_ip" ]; then
            server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_VPS_IP")
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  Download URL: http://${server_ip}:${port}/${output_file}${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "From your local machine, run:"
        echo -e "  ${YELLOW}curl -O http://${server_ip}:${port}/${output_file}${NC}"
        echo "  or open the URL in your browser"
        echo ""
        echo "Server will auto-stop after ${timeout_sec} seconds or press Ctrl+C"
        echo ""

        # Use Python's built-in HTTP server
        if command -v python3 &> /dev/null; then
            timeout "$timeout_sec" python3 -m http.server "$port" --bind 0.0.0.0 2>/dev/null || true
        elif command -v python &> /dev/null; then
            timeout "$timeout_sec" python -m SimpleHTTPServer "$port" 2>/dev/null || true
        else
            echo -e "${RED}Python not found. Manual download required:${NC}"
            echo "  scp root@${server_ip}:$(pwd)/${output_file} ./"
        fi
    else
        echo ""
        echo "You can share this file for troubleshooting."
        echo ""
        echo "To download via HTTP, run:"
        echo -e "  ${YELLOW}./debug-container.sh export serve${NC}"
    fi
}

# =============================================================================
# SNAPSHOT - Take diagnostic snapshot
# =============================================================================
take_snapshot() {
    local trigger="${1:-manual}"
    local snapshot_dir="./debug-snapshots"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="${snapshot_dir}/snapshot_${timestamp}.txt"

    mkdir -p "$snapshot_dir"

    {
        echo "=== DIAGNOSTIC SNAPSHOT ==="
        echo "Timestamp: $(date)"
        echo "Trigger: ${trigger}"
        echo ""
        show_all
    } > "$output_file" 2>&1

    echo "$output_file"
}

# =============================================================================
# CRASH SNAPSHOT - Take snapshot on crash detection
# =============================================================================
take_crash_snapshot() {
    local exit_code="${1:-unknown}"
    local action="${2:-unknown}"
    local snapshot_dir="./debug-snapshots"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="${snapshot_dir}/crash_${timestamp}_exit${exit_code}.txt"

    mkdir -p "$snapshot_dir"

    {
        echo "=== CRASH DIAGNOSTIC SNAPSHOT ==="
        echo "Timestamp: $(date)"
        echo "Trigger: crash"
        echo "Action: $action"
        echo "Exit Code: $exit_code"
        echo ""
        show_all
    } > "$output_file" 2>&1

    echo "$output_file"
}

# =============================================================================
# MONITOR - Periodic snapshot daemon
# =============================================================================
start_monitor() {
    local interval=${1:-3600}  # Default 1 hour
    local snapshot_dir="./debug-snapshots"

    mkdir -p "$snapshot_dir"

    echo "Starting diagnostic monitor (interval: ${interval}s)"
    echo "Snapshots saved to: $snapshot_dir"
    echo "PID: $$"
    echo $$ > "${snapshot_dir}/.monitor.pid"

    while true; do
        # Check if server container is running
        if docker ps --format '{{.Names}}' | grep -q "server"; then
            local output=$(take_snapshot "periodic")
            echo "[$(date)] Snapshot saved: $output"
        else
            echo "[$(date)] Server container not running, skipping snapshot"
        fi

        # Cleanup old snapshots (keep last 168 = 1 week at hourly)
        ls -t "${snapshot_dir}"/snapshot_*.txt 2>/dev/null | tail -n +169 | xargs rm -f 2>/dev/null
        ls -t "${snapshot_dir}"/crash_*.txt 2>/dev/null | tail -n +169 | xargs rm -f 2>/dev/null

        sleep "$interval"
    done
}

# =============================================================================
# CRASHES - Watch for container crashes
# =============================================================================
watch_crashes() {
    local snapshot_dir="./debug-snapshots"
    mkdir -p "$snapshot_dir"

    echo "Watching for container crashes..."
    echo "Snapshots will be saved on crash detection"
    echo "PID: $$"
    echo $$ > "${snapshot_dir}/.crashwatch.pid"

    docker events --filter 'type=container' \
        --filter 'event=die' \
        --filter 'event=oom' \
        --format '{{.Actor.Attributes.name}} {{.Action}} {{.Actor.Attributes.exitCode}}' \
    | while read -r name action exit_code; do
        if echo "$name" | grep -qE "(server|bidding)"; then
            echo "[$(date)] CRASH DETECTED: $name $action (exit=$exit_code)"

            # Capture snapshot immediately (before container restarts)
            local output=$(take_crash_snapshot "$exit_code" "$action")
            echo "[$(date)] Snapshot saved: $output"
        fi
    done
}

# =============================================================================
# SNAPSHOTS - List saved snapshots
# =============================================================================
list_snapshots() {
    local snapshot_dir="./debug-snapshots"

    print_header "DIAGNOSTIC SNAPSHOTS"

    if [ ! -d "$snapshot_dir" ]; then
        echo "No snapshots directory found"
        echo "Run './debug-container.sh snapshot' to create one"
        return
    fi

    print_subheader "Crash Snapshots (newest first)"
    local crash_count=$(ls -1 "${snapshot_dir}"/crash_*.txt 2>/dev/null | wc -l)
    if [ "$crash_count" -gt 0 ]; then
        ls -lt "${snapshot_dir}"/crash_*.txt 2>/dev/null | head -10 | while read -r line; do
            file=$(echo "$line" | awk '{print $NF}')
            exit_code=$(basename "$file" | sed 's/.*_exit\([0-9]*\)\.txt/\1/')
            echo -e "  ${RED}$(basename "$file")${NC} - Exit code: $exit_code"
        done
        echo ""
        echo "Total crash snapshots: $crash_count"
    else
        echo "  No crash snapshots found"
    fi

    print_subheader "Periodic Snapshots (newest first)"
    local snapshot_count=$(ls -1 "${snapshot_dir}"/snapshot_*.txt 2>/dev/null | wc -l)
    if [ "$snapshot_count" -gt 0 ]; then
        ls -lt "${snapshot_dir}"/snapshot_*.txt 2>/dev/null | head -10 | while read -r line; do
            file=$(echo "$line" | awk '{print $NF}')
            trigger=$(head -5 "$file" 2>/dev/null | grep "Trigger:" | cut -d: -f2- | tr -d ' ')
            echo "  $(basename "$file") - Trigger: $trigger"
        done
        echo ""
        echo "Total periodic snapshots: $snapshot_count"
    else
        echo "  No periodic snapshots found"
    fi

    print_subheader "Monitor Status"
    if [ -f "${snapshot_dir}/.monitor.pid" ]; then
        local pid=$(cat "${snapshot_dir}/.monitor.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${GREEN}Monitor running (PID: $pid)${NC}"
        else
            echo -e "${YELLOW}Monitor not running (stale PID file)${NC}"
        fi
    else
        echo "Monitor not running"
    fi

    if [ -f "${snapshot_dir}/.crashwatch.pid" ]; then
        local pid=$(cat "${snapshot_dir}/.crashwatch.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${GREEN}Crash watcher running (PID: $pid)${NC}"
        else
            echo -e "${YELLOW}Crash watcher not running (stale PID file)${NC}"
        fi
    else
        echo "Crash watcher not running"
    fi

    echo ""
    echo "To view a snapshot: cat ${snapshot_dir}/<filename>"
}

# =============================================================================
# STOP MONITOR - Stop monitoring daemons
# =============================================================================
stop_monitor() {
    local snapshot_dir="./debug-snapshots"

    print_header "STOPPING MONITORS"

    if [ -f "${snapshot_dir}/.monitor.pid" ]; then
        local pid=$(cat "${snapshot_dir}/.monitor.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid" 2>/dev/null
            echo -e "${GREEN}Stopped monitor (PID: $pid)${NC}"
        else
            echo "Monitor was not running"
        fi
        rm -f "${snapshot_dir}/.monitor.pid"
    else
        echo "No monitor PID file found"
    fi

    if [ -f "${snapshot_dir}/.crashwatch.pid" ]; then
        local pid=$(cat "${snapshot_dir}/.crashwatch.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid" 2>/dev/null
            echo -e "${GREEN}Stopped crash watcher (PID: $pid)${NC}"
        else
            echo "Crash watcher was not running"
        fi
        rm -f "${snapshot_dir}/.crashwatch.pid"
    else
        echo "No crash watcher PID file found"
    fi

    echo ""
    echo "Note: If running via systemd, use:"
    echo "  sudo systemctl stop debug-monitor"
    echo "  sudo systemctl stop debug-crashwatch"
}

# =============================================================================
# DOWNLOAD - Create zip and serve via HTTP for download
# =============================================================================
download_snapshots() {
    local snapshot_dir="./debug-snapshots"
    local port=${1:-8888}
    local timeout_sec=${2:-300}  # 5 minutes default

    print_header "SNAPSHOT DOWNLOAD"

    if [ ! -d "$snapshot_dir" ] || [ -z "$(ls -A "$snapshot_dir" 2>/dev/null)" ]; then
        echo -e "${RED}No snapshots found in $snapshot_dir${NC}"
        echo "Run './debug-container.sh snapshot' to create one first"
        return 1
    fi

    # Count files
    local file_count=$(ls -1 "$snapshot_dir"/*.txt 2>/dev/null | wc -l)
    echo "Found $file_count snapshot files"

    # Create zip file
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local zip_file="snapshots_${timestamp}.zip"

    echo -e "${YELLOW}Creating zip archive...${NC}"
    if command -v zip &> /dev/null; then
        zip -r "$zip_file" "$snapshot_dir" >/dev/null 2>&1
    else
        # Fallback to tar if zip not available
        zip_file="snapshots_${timestamp}.tar.gz"
        tar -czf "$zip_file" "$snapshot_dir" 2>/dev/null
    fi

    if [ ! -f "$zip_file" ]; then
        echo -e "${RED}Failed to create archive${NC}"
        return 1
    fi

    local file_size=$(du -h "$zip_file" | cut -f1)
    echo -e "${GREEN}Created: $zip_file ($file_size)${NC}"

    # Get server IP
    local server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_VPS_IP")
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Download URL: http://${server_ip}:${port}/${zip_file}${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "From your local machine, run:"
    echo -e "  ${YELLOW}curl -O http://${server_ip}:${port}/${zip_file}${NC}"
    echo "  or open the URL in your browser"
    echo ""
    echo "Server will auto-stop after ${timeout_sec} seconds or press Ctrl+C"
    echo ""

    # Use Python's built-in HTTP server (available on most systems)
    if command -v python3 &> /dev/null; then
        timeout "$timeout_sec" python3 -m http.server "$port" --bind 0.0.0.0 2>/dev/null || true
    elif command -v python &> /dev/null; then
        timeout "$timeout_sec" python -m SimpleHTTPServer "$port" 2>/dev/null || true
    else
        echo -e "${RED}Python not found. Manual download required:${NC}"
        echo "  scp root@${server_ip}:$(pwd)/${zip_file} ./"
        echo ""
        echo "Press Enter when done to cleanup..."
        read -r
    fi

    # Cleanup
    echo ""
    echo -e "${YELLOW}Cleaning up zip file...${NC}"
    rm -f "$zip_file"
    echo -e "${GREEN}Done!${NC}"
}

# =============================================================================
# CRASH ANALYSIS - Analyze recent crashes
# =============================================================================
analyze_crash() {
    print_header "CRASH ANALYSIS"

    SERVER=$(get_container_name "server")

    print_subheader "Last Exit Information"
    docker inspect "$SERVER" --format '
Exit Code: {{.State.ExitCode}}
OOM Killed: {{.State.OOMKilled}}
Error: {{.State.Error}}
Finished At: {{.State.FinishedAt}}
' 2>/dev/null

    # Interpret exit codes
    exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$SERVER" 2>/dev/null || echo "unknown")
    oom_killed=$(docker inspect --format='{{.State.OOMKilled}}' "$SERVER" 2>/dev/null || echo "false")

    print_subheader "Exit Code Analysis"
    case "$exit_code" in
        0)
            echo -e "${GREEN}Exit code 0: Clean shutdown${NC}"
            ;;
        1)
            echo -e "${YELLOW}Exit code 1: General error (check logs for details)${NC}"
            ;;
        137)
            echo -e "${RED}Exit code 137: SIGKILL - Process was forcefully killed${NC}"
            if [ "$oom_killed" = "true" ]; then
                echo -e "${RED}  ⚠️  Cause: Out of Memory (OOM) Kill${NC}"
                echo "  Recommendation: Increase container memory limit or reduce NODE_OPTIONS --max-old-space-size"
            else
                echo "  Possible causes: docker kill, docker stop timeout, or system OOM killer"
            fi
            ;;
        139)
            echo -e "${RED}Exit code 139: Segmentation fault${NC}"
            echo "  Recommendation: Check for native module issues or memory corruption"
            ;;
        143)
            echo -e "${YELLOW}Exit code 143: SIGTERM - Graceful termination requested${NC}"
            echo "  This is typically from docker stop or system shutdown"
            ;;
        *)
            echo -e "${YELLOW}Exit code $exit_code: Unknown${NC}"
            ;;
    esac

    print_subheader "Memory at Time of Exit"
    # Show current memory for comparison
    docker stats --no-stream --format "{{.Name}}: {{.MemUsage}} ({{.MemPerc}})" \
        | grep -E "(bidding|server)" || echo "Container not running"

    print_subheader "Recommendations"
    if [ "$oom_killed" = "true" ] || [ "$exit_code" = "137" ]; then
        echo "1. Check NODE_OPTIONS --max-old-space-size in compose.yaml"
        echo "2. Consider increasing Docker memory limits"
        echo "3. Check for memory leaks in recent code changes"
        echo "4. Review the debug-logs for memory usage patterns before crash"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    case "${1:-status}" in
        status)
            show_status
            ;;
        logs)
            show_logs "${2:-100}"
            ;;
        events)
            show_events
            ;;
        inspect)
            show_inspect
            ;;
        resources)
            show_resources
            ;;
        lifecycle)
            show_lifecycle
            ;;
        redis)
            show_redis
            ;;
        mongodb)
            show_mongodb
            ;;
        health)
            show_health
            ;;
        memory)
            show_memory
            ;;
        network)
            show_network
            ;;
        queue)
            show_queue
            ;;
        all)
            show_all
            ;;
        watch)
            watch_containers
            ;;
        export)
            export_debug "${2:-false}" "${3:-8888}" "${4:-300}"
            ;;
        crash)
            analyze_crash
            ;;
        snapshot)
            output=$(take_snapshot "${2:-manual}")
            echo -e "${GREEN}Snapshot saved: $output${NC}"
            ;;
        monitor)
            start_monitor "${2:-3600}"
            ;;
        crashes)
            watch_crashes
            ;;
        snapshots)
            list_snapshots
            ;;
        stop-monitor)
            stop_monitor
            ;;
        download)
            download_snapshots "${2:-8888}" "${3:-300}"
            ;;
        help|--help|-h)
            echo "Docker Container Debug Script"
            echo ""
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  status       - Show container status and health (default)"
            echo "  logs [n]     - Show last n container logs (default: 100)"
            echo "  events       - Show Docker events (restarts, OOM, etc.)"
            echo "  inspect      - Detailed container inspection"
            echo "  resources    - Show resource usage (CPU, memory)"
            echo "  lifecycle    - Show process lifecycle logs"
            echo "  redis        - Redis connection, memory, and queue diagnostics"
            echo "  mongodb      - MongoDB connection pool and query diagnostics"
            echo "  health       - Application health endpoint checks"
            echo "  memory       - Node.js heap and memory analysis"
            echo "  network      - DNS resolution and API connectivity"
            echo "  queue        - BullMQ queue and worker diagnostics"
            echo "  crash        - Analyze recent crash/restart"
            echo "  all          - Run all diagnostics"
            echo "  watch        - Live monitoring mode"
            echo "  export [serve] [port] - Export all debug info (optionally serve via HTTP)"
            echo ""
            echo "Automated Monitoring:"
            echo "  snapshot [trigger]  - Take immediate diagnostic snapshot"
            echo "  monitor [interval]  - Start periodic snapshot daemon (default: 3600s = 1hr)"
            echo "  crashes             - Watch for crashes and auto-capture snapshots"
            echo "  snapshots           - List saved snapshots"
            echo "  stop-monitor        - Stop monitoring daemons"
            echo "  download [port] [timeout] - Create zip and serve via HTTP (default: port 8888, 300s)"
            echo ""
            echo "  help         - Show this help message"
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
