#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Redirect all output to log file AND stdout for debugging
LOG_FILE="/var/log/nfttools-install.log"
if [ -w "/var/log" ] || [ -w "$LOG_FILE" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "========== Installation started at $(date) =========="
fi

# Repository and version information
REGISTRY="nfttools"
VERSION="beta-single"

echo -e "${GREEN}NFT Bidding Bot Installation Script${NC}"
echo "----------------------------------------"

# Check OS
OS=$(uname)
ARCH=$(uname -m)
PROCESSOR=""


if [ "$OS" = "Darwin" ]; then
    if [ "$ARCH" = "arm64" ]; then
        PROCESSOR="Apple Silicon (M1/M2)"
    else
        PROCESSOR="Intel"
    fi
fi

echo -e "${YELLOW}Detected OS: $OS${NC}"
echo -e "${YELLOW}System Architecture: $ARCH${NC}"
if [ ! -z "$PROCESSOR" ]; then
    echo -e "${YELLOW}Processor Type: $PROCESSOR${NC}"
fi

# Check Docker installation
if ! [ -x "$(command -v docker)" ]; then
    echo -e "${YELLOW}Docker not found. Installing Docker...${NC}"
    if [ "$OS" = "Linux" ]; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
    elif [ "$OS" = "Darwin" ]; then
        echo -e "${RED}Please install Docker Desktop manually from: https://www.docker.com/products/docker-desktop${NC}"
        exit 1
    fi
fi

# Fix Docker socket permissions
echo -e "${YELLOW}Setting Docker socket permissions...${NC}"
if [ "$OS" = "Linux" ]; then
    # Ensure the docker group exists
    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    # Add current user to docker group
    sudo usermod -aG docker $USER
    # Set permissions for Docker socket
    sudo chmod 666 /var/run/docker.sock
fi

# Open port 8888 for debug log downloads (if UFW is active)
if [ "$OS" = "Linux" ] && command -v ufw >/dev/null 2>&1; then
    if sudo ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Opening port 8888 for debug log downloads...${NC}"
        sudo ufw allow 8888/tcp >/dev/null 2>&1
        echo -e "${GREEN}Port 8888 opened for HTTP downloads${NC}"
    fi
fi

# Check Docker Compose installation
if ! [ -x "$(command -v docker-compose)" ]; then
    echo -e "${YELLOW}Docker Compose not found.${NC}"
    if [ "$OS" = "Darwin" ]; then
        # Get Docker version for macOS
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
        MAJOR_VERSION=$(echo $DOCKER_VERSION | cut -d. -f1)

        if [ "$MAJOR_VERSION" -ge 2 ]; then
            echo -e "${GREEN}Docker version >= 2.0.0 detected. Docker Compose is already included.${NC}"
        else
            echo -e "${YELLOW}Installing Docker Compose...${NC}"
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        fi
    else
        echo -e "${YELLOW}Installing Docker Compose...${NC}"
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
fi

# Check curl installation (required for health checks and downloads)
if ! [ -x "$(command -v curl)" ]; then
    echo -e "${YELLOW}curl not found. Installing curl...${NC}"
    if [ "$OS" = "Linux" ]; then
        sudo apt-get update -qq
        sudo apt-get install -y curl
    elif [ "$OS" = "Darwin" ]; then
        echo -e "${GREEN}curl should be pre-installed on macOS${NC}"
    fi
fi

# Check jq installation (required for health checks)
if ! [ -x "$(command -v jq)" ]; then
    echo -e "${YELLOW}jq not found. Installing jq for health checks...${NC}"
    if [ "$OS" = "Linux" ]; then
        # Only update if we haven't already (from curl install)
        if ! [ -x "$(command -v curl)" ]; then
            sudo apt-get update -qq
        fi
        sudo apt-get install -y jq
    elif [ "$OS" = "Darwin" ]; then
        if [ -x "$(command -v brew)" ]; then
            brew install jq
        else
            echo -e "${RED}Please install jq manually: https://stedolan.github.io/jq/download/${NC}"
            echo -e "${YELLOW}Or install Homebrew first: https://brew.sh${NC}"
            exit 1
        fi
    fi
fi

# Setup swap space for VPS (only on Linux)
if [ "$OS" = "Linux" ]; then
    echo -e "${YELLOW}Checking swap configuration...${NC}"
    
    # Check if swap already exists
    if [ $(swapon -s | wc -l) -gt 1 ]; then
        echo -e "${GREEN}Swap already configured:${NC}"
        free -h
        
        # Check if existing swap is optimal
        CURRENT_SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
        CURRENT_SWAP_GB=$((CURRENT_SWAP_KB / 1024 / 1024))
        TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
        
        echo -e "${YELLOW}Current swap: ${CURRENT_SWAP_GB}GB, Total RAM: ${TOTAL_RAM_GB}GB${NC}"
        
        # Recommend optimal swap size for this system
        if [ $TOTAL_RAM_GB -le 2 ]; then
            OPTIMAL_SWAP_GB=$((TOTAL_RAM_GB * 2))
        elif [ $TOTAL_RAM_GB -le 8 ]; then
            OPTIMAL_SWAP_GB=$TOTAL_RAM_GB
        else
            OPTIMAL_SWAP_GB=8
        fi
        
        if [ $CURRENT_SWAP_GB -lt $OPTIMAL_SWAP_GB ]; then
            echo -e "${YELLOW}Consider increasing swap to ${OPTIMAL_SWAP_GB}GB for optimal performance${NC}"
        fi
    else
        # Calculate optimal swap size based on RAM
        TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
        
        echo -e "${YELLOW}Detected ${TOTAL_RAM_GB}GB RAM${NC}"
        
        # Dynamic swap sizing:
        # <= 2GB RAM: 2x RAM
        # 2-8GB RAM: 1x RAM  
        # > 8GB RAM: 8GB fixed
        if [ $TOTAL_RAM_GB -le 2 ]; then
            SWAP_SIZE_GB=$((TOTAL_RAM_GB * 2))
        elif [ $TOTAL_RAM_GB -le 8 ]; then
            SWAP_SIZE_GB=$TOTAL_RAM_GB
        else
            SWAP_SIZE_GB=8
        fi
        
        echo -e "${YELLOW}Setting up ${SWAP_SIZE_GB}GB swap space (optimized for ${TOTAL_RAM_GB}GB RAM)...${NC}"
        
        # Create swap file
        echo "Creating ${SWAP_SIZE_GB}GB swap file..."
        sudo fallocate -l ${SWAP_SIZE_GB}G /swapfile
        
        # Set permissions
        echo "Setting permissions..."
        sudo chmod 600 /swapfile
        
        # Make swap
        echo "Creating swap area..."
        sudo mkswap /swapfile
        
        # Enable swap
        echo "Enabling swap..."
        sudo swapon /swapfile
        
        # Make permanent
        echo "Making swap permanent..."
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
        
        # Optimized swappiness based on RAM size and VPS usage
        if [ $TOTAL_RAM_GB -ge 8 ]; then
            # For 8GB+ systems, be more conservative with swap
            SWAPPINESS=5
            CACHE_PRESSURE=50
        elif [ $TOTAL_RAM_GB -ge 4 ]; then
            # For 4-8GB systems, moderate swap usage
            SWAPPINESS=10
            CACHE_PRESSURE=100
        else
            # For smaller systems, allow more swap usage
            SWAPPINESS=20
            CACHE_PRESSURE=150
        fi
        
        echo "Setting swappiness to ${SWAPPINESS} (optimized for ${TOTAL_RAM_GB}GB RAM)..."
        echo "vm.swappiness=${SWAPPINESS}" | sudo tee -a /etc/sysctl.conf
        sudo sysctl vm.swappiness=${SWAPPINESS}
        
        # Set cache pressure for better memory management
        echo "Setting vfs_cache_pressure to ${CACHE_PRESSURE}..."
        echo "vm.vfs_cache_pressure=${CACHE_PRESSURE}" | sudo tee -a /etc/sysctl.conf
        sudo sysctl vm.vfs_cache_pressure=${CACHE_PRESSURE}
        
        # Enable swap file preallocation for better performance
        echo "Optimizing swap performance..."
        echo "vm.page-cluster=3" | sudo tee -a /etc/sysctl.conf
        sudo sysctl vm.page-cluster=3
        
        echo -e "${GREEN}Swap setup complete!${NC}"
        echo "Optimization applied:"
        echo "- Swap size: ${SWAP_SIZE_GB}GB (${TOTAL_RAM_GB}GB RAM detected)"
        echo "- Swappiness: ${SWAPPINESS} (lower = less swap usage)"
        echo "- Cache pressure: ${CACHE_PRESSURE} (optimized for VPS)"
        echo "- Page cluster: 3 (improved swap I/O)"
        echo ""
        echo "Current memory status:"
        free -h
    fi
fi

# System configuration for Docker containers (only on Linux)
if [ "$OS" = "Linux" ]; then
    echo -e "${YELLOW}Optimizing system configuration for Docker containers...${NC}"
    
    # Fix Redis memory overcommit warning
    echo "Setting vm.overcommit_memory = 1 for Redis"
    sudo sysctl vm.overcommit_memory=1
    
    # Make it persistent
    if ! grep -q "vm.overcommit_memory = 1" /etc/sysctl.conf; then
        echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
    fi
    
    # Set transparent huge pages to never (Redis recommendation)
    echo "Disabling transparent huge pages for Redis"
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "Could not disable transparent huge pages (normal on some systems)"
    
    # Increase max map count for better performance
    echo "Setting vm.max_map_count for better performance"
    sudo sysctl vm.max_map_count=262144
    
    # Make it persistent
    if ! grep -q "vm.max_map_count = 262144" /etc/sysctl.conf; then
        echo "vm.max_map_count = 262144" | sudo tee -a /etc/sysctl.conf
    fi
    
    # Set up Docker log rotation to prevent unbounded log growth
    echo -e "${YELLOW}Setting up Docker log rotation...${NC}"
    sudo mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        echo "Backing up existing /etc/docker/daemon.json..."
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
    fi
    sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1g",
    "max-file": "3"
  }
}
EOF

    # Restart Docker to apply log rotation settings (ignore errors on non-systemd setups)
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart docker || true
    else
        sudo service docker restart || true
    fi

    echo -e "${GREEN}System configuration optimized!${NC}"
    echo "Changes applied:"
    echo "- vm.overcommit_memory = 1 (prevents Redis memory issues)"
    echo "- vm.max_map_count = 262144 (improves performance)"
    echo "These settings are now persistent and will survive reboots."
fi

# System cleanup (especially useful for updates)
if [ "$OS" = "Linux" ]; then
    echo -e "${YELLOW}Performing system cleanup...${NC}"
    
    # Truncate Docker container logs and common large system logs
    echo "=== Truncating Docker container logs... ==="
    sudo find /var/lib/docker/containers/ -name "*-json.log" -exec truncate -s 0 {} \; 2>/dev/null || true
    
    echo "=== Truncating big system logs... ==="
    [ -f /var/log/nginx/access.log ] && sudo truncate -s 0 /var/log/nginx/access.log || true
    [ -f /var/log/nginx/error.log ] && sudo truncate -s 0 /var/log/nginx/error.log || true
    [ -f /var/log/btmp ] && sudo truncate -s 0 /var/log/btmp || true
    
    # Docker cleanup (preserve volumes to protect database data)
    echo "Cleaning Docker system..."
    docker system prune -a -f
    
    # Journal cleanup
    echo "Cleaning system journals..."
    sudo journalctl --vacuum-time=1d
    
    # Package cleanup
    echo "Cleaning package cache..."
    sudo apt-get clean
    sudo apt-get autoremove -y
    
    # Temp and log cleanup
    echo "Cleaning temporary files and old logs..."
    sudo rm -rf /tmp/* /var/tmp/* /var/log/*.gz /var/log/*.old /var/log/*.1
    
    # NPM cache cleanup
    if command -v npm &> /dev/null; then
        echo "Cleaning npm cache..."
        npm cache clean --force
    fi
    
    echo -e "${GREEN}System cleanup complete!${NC}"
fi

# Stop and remove existing containers if they exist
echo -e "${YELLOW}Checking for existing containers...${NC}"
CONTAINER_PREFIX="nft-bidding-bot"
EXISTING_CONTAINERS=$(docker ps -aq --filter "name=${CONTAINER_PREFIX}")

if [ ! -z "$EXISTING_CONTAINERS" ]; then
    echo -e "${YELLOW}Stopping existing containers...${NC}"
    docker stop $EXISTING_CONTAINERS
    echo -e "${YELLOW}Removing existing containers...${NC}"
    docker rm $EXISTING_CONTAINERS
fi

# Make sure all containers using Redis volumes are stopped
echo -e "${YELLOW}Ensuring all Redis containers are stopped...${NC}"
REDIS_CONTAINERS=$(docker ps -a --filter "ancestor=redis" -q)
if [ ! -z "$REDIS_CONTAINERS" ]; then
    echo -e "${YELLOW}Stopping Redis containers...${NC}"
    docker stop $REDIS_CONTAINERS
    echo -e "${YELLOW}Removing Redis containers...${NC}"
    docker rm $REDIS_CONTAINERS
fi


# Stop all containers to ensure clean restart
echo -e "${YELLOW}Stopping all containers for clean restart...${NC}"
ALL_CONTAINERS=$(docker ps -q)
if [ ! -z "$ALL_CONTAINERS" ]; then
    docker stop $ALL_CONTAINERS
fi

# Clear Redis volumes for fresh installation (preserving MongoDB and debug logs)
echo -e "${YELLOW}Removing Redis volumes for fresh installation (MongoDB and debug logs will be preserved)...${NC}"

# Get all volumes related to the application
APP_VOLUMES=$(docker volume ls -q | grep -E "(nft-bidding-bot_|redis_data|server_data|server_logs|mongodb_data)")
if [ ! -z "$APP_VOLUMES" ]; then
    echo -e "${YELLOW}Found application volumes:${NC}"
    echo "$APP_VOLUMES"

    echo -e "${YELLOW}Preserving MongoDB data and debug logs...${NC}"
    # Remove all volumes except MongoDB and server_logs (debug logs)
    VOLUMES_TO_REMOVE=$(echo "$APP_VOLUMES" | grep -v -E "(mongodb|server_logs)")
    
    if [ ! -z "$VOLUMES_TO_REMOVE" ]; then
        echo -e "${YELLOW}Removing volumes:${NC}"
        echo "$VOLUMES_TO_REMOVE"
        echo "$VOLUMES_TO_REMOVE" | xargs docker volume rm -f || {
            echo -e "${RED}Some volumes could not be removed. Attempting force removal...${NC}"
            for vol in $VOLUMES_TO_REMOVE; do
                docker volume rm -f $vol || echo -e "${RED}Could not remove volume $vol${NC}"
            done
        }
    fi
fi

# Also remove any dangling volumes
echo -e "${YELLOW}Removing dangling volumes...${NC}"
docker volume prune -f


# Create project directory
PROJECT_DIR="nft-bidding-bot"
cd $PROJECT_DIR


# Download necessary files
echo -e "${YELLOW}Downloading configuration files...${NC}"

# Check architecture and modify compose file if needed
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo "Detected ARM64 architecture, downloading ARM64 compose file..."
    curl -s "https://gist.githubusercontent.com/ayenisholah/753cdedf3111ea63215fb2aef7420efd/raw/f1982bc5862e1470e4aeaa0ec266cad286536a89/compose.production-arm64.yaml?_=$(uuidgen)" -o compose.yaml
else
    echo "Detected AMD64 architecture, downloading AMD64 compose file..."
    curl -s "https://raw.githubusercontent.com/nfttools-org/bidding-bot-installation/refs/heads/beta-redis-single/compose.yaml" -o compose.yaml
fi

# Download debug script to project root
echo -e "${YELLOW}Downloading debug script...${NC}"
curl -s "https://raw.githubusercontent.com/nfttools-org/bidding-bot-installation/refs/heads/beta-redis-single/debug-container.sh" -o debug-container.sh
chmod +x debug-container.sh

# Function to get IP address
get_ip_address() {
    if [ "$(uname)" == "Darwin" ]; then
        # macOS
        IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
    else
        # Linux
        IP=$(hostname -I | awk '{print $1}' | grep -v '^$')
        
        # If empty, try alternative method
        if [ -z "$IP" ]; then
            IP=$(ip route get 1 | awk '{print $NF;exit}')
        fi
    fi
    
    # Fallback to public IP if still 
    if [ -z "$IP" ]; then
        IP=$(curl -s ifconfig.me)
    fi
    
    echo "$IP"
}

# Get server IP
SERVER_IP=$(get_ip_address)
echo -e "${YELLOW}Detected Server IP: ${SERVER_IP}${NC}"

# Check if .env file exists
if [ -f .env ]; then
    echo -e "${YELLOW}.env file exists, appending values...${NC}"
    
    # Function to update or append env variable
    update_env_var() {
        local key=$1
        local value=$2
        if grep -q "^${key}=" .env; then
            # Update existing value
            sed -i.bak "s|^${key}=.*|${key}=${value}|" .env && rm -f .env.bak
        else
            # Append new value
            echo "${key}=${value}" >> .env
        fi
    }
    
    # Update or append each variable
    update_env_var "MONGODB_URI" "mongodb://mongodb:27017/BIDDING_BOT"
    update_env_var "PORT_SERVER" "3003"
    update_env_var "PORT_CLIENT" "3001"
    update_env_var "SERVER_IP" "${SERVER_IP}"
    update_env_var "REDIS_HOST" "redis"
    update_env_var "REDIS_PORT" "6379"
    update_env_var "MONGO_MAX_POOL_SIZE" "100"
    update_env_var "MONGO_MIN_POOL_SIZE" "30"
    update_env_var "DEBUG" "true"
    update_env_var "MARKETPLACE_WS_URL" "wss://nfttools-ws-proxy.nfttools.io"
else
    echo -e "${YELLOW}Creating new .env file...${NC}"
    cat > .env << EOL
MONGODB_URI=mongodb://mongodb:27017/BIDDING_BOT
PORT_SERVER=3003
PORT_CLIENT=3001
SERVER_IP=${SERVER_IP}
REDIS_HOST=redis
REDIS_PORT=6379
MONGO_MAX_POOL_SIZE=100
MONGO_MIN_POOL_SIZE=30
DEBUG=true
MARKETPLACE_WS_URL=wss://nfttools-ws-proxy.nfttools.io
EOL
fi

# Extract USERNAME for health checks (early extraction)
if [ -f .env ] && grep -q "USERNAME=" .env; then
    USERNAME=$(grep "USERNAME=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
else
    USERNAME="nft"  # Default fallback
fi

# Remove old images to force fresh pull
echo -e "${YELLOW}Removing old Docker images...${NC}"
docker images | grep "nfttools/bidding-bot" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true

# Start services with fresh pull
echo -e "${YELLOW}Pulling fresh Docker images...${NC}"
docker compose pull --ignore-pull-failures || {
    echo -e "${RED}Failed to pull some images. Retrying...${NC}"
    docker compose pull
}

# Fix debug-logs volume permissions BEFORE starting containers
# This ensures the volume has correct permissions when the server first starts
echo -e "${YELLOW}Setting up debug-logs volume with correct permissions...${NC}"

VOLUME_NAME="nft-bidding-bot_server_logs"

# Check if volume exists and is empty - if so, remove it to recreate with proper permissions
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    FILE_COUNT=$(docker run --rm -v "$VOLUME_NAME":/data alpine sh -c 'find /data -type f 2>/dev/null | wc -l' 2>/dev/null || echo "0")
    if [ "$FILE_COUNT" -eq "0" ] || [ -z "$FILE_COUNT" ]; then
        echo "Empty or inaccessible volume detected, recreating with correct permissions..."
        docker volume rm "$VOLUME_NAME" 2>/dev/null || true
    fi
fi

# Create volume if it doesn't exist
docker volume create "$VOLUME_NAME" 2>/dev/null || true

# Always set permissions (handles both new and existing volumes)
docker run --rm -v "$VOLUME_NAME":/data alpine sh -c '
    chmod 777 /data
    chown 1000:1000 /data
    # Create a test file to verify write permissions
    touch /data/.permission-test && rm /data/.permission-test
' && echo -e "${GREEN}Debug-logs volume permissions verified${NC}" \
  || echo -e "${RED}Warning: Could not set volume permissions${NC}"

echo -e "${YELLOW}Starting services...${NC}"
docker compose up -d

# Function to check port health
check_port_health() {
  local port=$1
  local name=$2
  curl -sf --max-time 5 "http://localhost:${port}" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} ${name} (localhost:${port}) is healthy"
    return 0
  else
    echo -e "${RED}✗${NC} ${name} (localhost:${port}) is not responding"
    return 1
  fi
}

# Function to check domain health
check_domain_health() {
  local domain=$1
  local name=$2
  curl -sf --max-time 5 "http://${domain}" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} ${name} (${domain}) is accessible"
    return 0
  else
    echo -e "${YELLOW}⚠${NC} ${name} (${domain}) is not accessible (DNS may not be configured)"
    return 0  # Don't fail on domain check
  fi
}

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Performing Health Checks${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Wait for containers to stabilize (silent wait)
echo "Waiting for services to initialize..."
sleep 30

echo ""
echo "Checking internal services:"
check_port_health 3003 "Server API" || SERVER_FAILED=true
check_port_health 3001 "Client UI" || CLIENT_FAILED=true

echo ""
echo "Checking external domains:"
check_domain_health "${USERNAME}.nfttools.io" "Client Domain"
check_domain_health "${USERNAME}-api.nfttools.io" "API Domain"

echo ""
if [ "$SERVER_FAILED" = "true" ] || [ "$CLIENT_FAILED" = "true" ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}Health Check Failed${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "  - Check container logs: docker compose logs server"
    echo "  - Check container logs: docker compose logs client"
    echo "  - Check container status: docker compose ps"
    exit 1
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}All Health Checks Passed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Verify debug-logs permissions (backup check - run as root)
echo -e "${YELLOW}Verifying debug-logs permissions...${NC}"
docker exec -u root nft-bidding-bot-server-1 sh -c 'chmod 777 /app/debug-logs && chown 1000:1000 /app/debug-logs' 2>/dev/null || true

# Clear debug logs for fresh start after update
echo -e "${YELLOW}Clearing debug logs for fresh start...${NC}"
docker exec -u root nft-bidding-bot-server-1 sh -c 'rm -f /app/debug-logs/*.log' 2>/dev/null || {
  echo -e "${YELLOW}Note: Could not clear debug logs (container may not be ready yet)${NC}"
}
echo -e "${GREEN}Debug logs cleared for fresh start${NC}"

# Cleanup obsolete MongoDB collections migrated to LRU caches (2026-01-27)
echo -e "${YELLOW}Cleaning up obsolete MongoDB collections...${NC}"

# Check if MongoDB container is running
if docker ps --format "{{.Names}}" | grep -q "mongodb"; then
    # Collections migrated to LRU caches
    COLLECTIONS=(
        "taskruntimestates"
        "tokentraitcaches"
        "tokentraits"
        "raritycaches"
        "bidlogs"
        "approvals"
    )

    echo "Dropping ${#COLLECTIONS[@]} obsolete collections from BIDDING_BOT database..."

    # Drop each collection with audit logging
    for collection in "${COLLECTIONS[@]}"; do
        # Get document count for audit log
        DOC_COUNT=$(docker exec nft-bidding-bot-mongodb-1 mongosh --quiet BIDDING_BOT \
            --eval "db.${collection}.countDocuments()" 2>/dev/null || echo "0")

        # Drop collection
        RESULT=$(docker exec nft-bidding-bot-mongodb-1 mongosh --quiet BIDDING_BOT \
            --eval "db.${collection}.drop()" 2>&1)

        if [ $? -eq 0 ]; then
            if [ "$DOC_COUNT" != "0" ]; then
                echo "  ✓ Dropped '${collection}' (${DOC_COUNT} documents)"
            else
                echo "  ✓ '${collection}' (already dropped)"
            fi
        else
            # Gracefully handle "collection doesn't exist" errors
            if [[ "$RESULT" == *"false"* ]] || [[ "$RESULT" == *"NamespaceNotFound"* ]]; then
                echo "  ✓ '${collection}' (already dropped)"
            else
                echo -e "  ${YELLOW}⚠${NC} '${collection}' - $RESULT"
            fi
        fi
    done

    echo -e "${GREEN}MongoDB collection cleanup complete${NC}"
else
    echo -e "${YELLOW}MongoDB container not running, skipping collection cleanup${NC}"
fi

echo ""

# Run debug script and save output to txt file
echo -e "${YELLOW}Running container diagnostics...${NC}"
./debug-container.sh all > debug-output.txt 2>&1
echo -e "${GREEN}Debug output saved to debug-output.txt${NC}"

# Setup debug monitoring systemd services (only on Linux with systemd)
if [ "$OS" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
    echo -e "${YELLOW}Setting up debug monitoring services...${NC}"

    # Create debug-monitor service (hourly snapshots)
    sudo tee /etc/systemd/system/debug-monitor.service >/dev/null <<EOF
[Unit]
Description=NFT Bidding Bot Debug Monitor (Hourly Snapshots)
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/debug-container.sh monitor 3600
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Create debug-crashwatch service
    sudo tee /etc/systemd/system/debug-crashwatch.service >/dev/null <<EOF
[Unit]
Description=NFT Bidding Bot Crash Watcher
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/debug-container.sh crashes
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start services
    sudo systemctl daemon-reload
    sudo systemctl enable debug-monitor debug-crashwatch
    sudo systemctl start debug-monitor debug-crashwatch

    echo -e "${GREEN}Debug monitoring services started!${NC}"
    echo "  - Hourly snapshots: systemctl status debug-monitor"
    echo "  - Crash watcher: systemctl status debug-crashwatch"
    echo "  - Snapshots saved to: ./debug-snapshots/"
fi

# Ensure update server is running and healthy (only on Linux with systemd)
if [ "$OS" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
    echo -e "${YELLOW}Checking update server status...${NC}"

    # Check if update-server service exists
    if systemctl list-unit-files | grep -q "update-server.service"; then
        # Service exists - check if it's running
        if systemctl is-active --quiet update-server; then
            echo -e "${GREEN}Update server is running${NC}"
        else
            echo -e "${YELLOW}Update server is not running. Starting...${NC}"
            sudo systemctl start update-server
            sleep 2
        fi

        # Verify health endpoint
        echo -e "${YELLOW}Testing update server health...${NC}"
        if curl -sf http://127.0.0.1:9999/health > /dev/null 2>&1; then
            echo -e "${GREEN}Update server health check passed!${NC}"
        else
            echo -e "${RED}Update server health check failed. Restarting service...${NC}"
            sudo systemctl restart update-server
            sleep 3

            # Final health check
            if curl -sf http://127.0.0.1:9999/health > /dev/null 2>&1; then
                echo -e "${GREEN}Update server recovered and healthy!${NC}"
            else
                echo -e "${RED}Update server still not responding. Check logs with: journalctl -u update-server${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}Update server service not installed (will be set up by deployer)${NC}"
    fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Access your application:${NC}"
echo ""
echo -e "  ${GREEN}Internal Access:${NC}"
echo -e "    Server API: http://${SERVER_IP}:3003"
echo -e "    Client UI:  http://${SERVER_IP}:3001"
echo ""
echo -e "  ${GREEN}Domain Access (if DNS configured):${NC}"
echo -e "    Client:     http://${USERNAME}.nfttools.io"
echo -e "    API:        http://${USERNAME}-api.nfttools.io"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo -e "  ${GREEN}cd $PROJECT_DIR${NC}"
echo -e "  ${GREEN}docker compose ps${NC}      - Check service status"
echo -e "  ${GREEN}docker compose logs${NC}    - View logs"
echo -e "  ${GREEN}docker compose down${NC}    - Stop services"
echo ""

# Check if nginx is installed and update configuration for 5GB downloads if not already done
if command -v nginx &> /dev/null; then
    echo -e "\n${YELLOW}Nginx detected on this system.${NC}"
    
    # Check if nginx 5GB configuration has already been applied
    NGINX_MARKER="/etc/nfttools-nginx-5gb-configured"
    
    if [ -f "$NGINX_MARKER" ]; then
        echo -e "${GREEN}Nginx 5GB configuration already applied.${NC}"
    else
        echo -e "${YELLOW}Applying nginx configuration for 5GB file downloads...${NC}"
        
        # Extract USERNAME from .env file or use container prefix
        if [ -f .env ] && grep -q "USERNAME=" .env; then
            NGINX_USERNAME=$(grep "USERNAME=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        else
            # Use container prefix as username, removing "nft-bidding-bot" to get base name
            # If CONTAINER_PREFIX is "nft-bidding-bot", we'll use "nft" as default
            NGINX_USERNAME="nft"
        fi
        
        echo -e "${YELLOW}Using username: ${NGINX_USERNAME}${NC}"
        echo -e "${GREEN}Updating Nginx configuration for 5GB downloads...${NC}"
        
        # Remove existing symlink if it exists
        echo "🔗 Removing existing site symlink..."
        if [ -L /etc/nginx/sites-enabled/nfttools.io ]; then
            sudo rm /etc/nginx/sites-enabled/nfttools.io
            echo "✅ Removed existing symlink"
        fi
        
        # Create new nginx configuration with 5GB support
        echo "📝 Creating new nginx configuration..."
        sudo tee /etc/nginx/sites-available/nfttools.io >/dev/null <<NGINX_CONF
# Client site configuration
server {
    server_name ${NGINX_USERNAME}.nfttools.io;
    client_max_body_size 5G;

    # Extended timeouts for large downloads
    proxy_read_timeout 1200s;
    proxy_send_timeout 1200s;
    proxy_connect_timeout 75s;
    
    # Disable buffering for large files
    proxy_buffering off;
    proxy_request_buffering off;

    error_page 502 /502.html;
    location = /502.html {
        root /var/www/nfttools-error-pages;
        internal;
    }

    location / {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket specific settings
        proxy_connect_timeout 300s;
        proxy_send_timeout 75s;
        proxy_read_timeout 300s;

        # Large file handling settings
        proxy_max_temp_file_size 0;
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Optimized buffer sizes
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}

# API site configuration
server {
    server_name ${NGINX_USERNAME}-api.nfttools.io;
    client_max_body_size 5G;

    # Extended timeouts for large downloads
    proxy_read_timeout 1200s;
    proxy_send_timeout 1200s;
    proxy_connect_timeout 75s;
    
    # Disable buffering for large files
    proxy_buffering off;
    proxy_request_buffering off;

    error_page 502 /502.html;
    location = /502.html {
        root /var/www/nfttools-error-pages;
        internal;
    }

    location / {
        proxy_pass http://localhost:3003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket specific settings
        proxy_connect_timeout 300s;
        proxy_send_timeout 75s;
        proxy_read_timeout 300s;

        # Large file handling settings
        proxy_max_temp_file_size 0;
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Optimized buffer sizes
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
NGINX_CONF

        echo "🔗 Creating new symlink..."
        sudo ln -s /etc/nginx/sites-available/nfttools.io /etc/nginx/sites-enabled/nfttools.io
        
        echo "🧪 Testing nginx configuration..."
        if sudo nginx -t; then
            echo "✅ Nginx configuration is valid"
            echo "🔄 Reloading nginx..."
            sudo systemctl reload nginx
            echo "✅ Nginx reloaded successfully"
            
            # Create marker file to indicate nginx 5GB configuration has been applied
            sudo touch "$NGINX_MARKER"
            echo "📝 Created marker file: $NGINX_MARKER"
            
            echo -e "\n${GREEN}✅ Nginx configuration updated successfully!${NC}"
            echo -e "The following changes were made:"
            echo -e "  - client_max_body_size increased to 5G"
            echo -e "  - Extended timeouts to 1200s (20 minutes) for large downloads"
            echo -e "  - Disabled proxy buffering for efficient large file handling"
            echo -e "  - Optimized buffer sizes for better performance"
            echo -e "\nBoth ${NGINX_USERNAME}.nfttools.io and ${NGINX_USERNAME}-api.nfttools.io now support 5GB file transfers."
        else
            echo "❌ Nginx configuration test failed, removing symlink"
            sudo rm /etc/nginx/sites-enabled/nfttools.io
            echo -e "${RED}Failed to update nginx configuration. Please check your nginx setup.${NC}"
        fi
    fi
    
    # Configure SSL certificates if not already done
    SSL_MARKER="/etc/nfttools-nginx-ssl-configured"
    
    if [ -f "$SSL_MARKER" ]; then
        echo -e "${GREEN}SSL certificates already configured.${NC}"
    else
        echo -e "\n${YELLOW}Setting up SSL certificates for HTTPS access...${NC}"
        
        # Extract email from .env file
        if [ -f .env ] && grep -q "EMAIL=" .env; then
            SSL_EMAIL=$(grep "EMAIL=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        else
            echo -e "${YELLOW}No EMAIL found in .env file.${NC}"
            read -p "Enter email for SSL certificate registration: " SSL_EMAIL
            if [ -z "$SSL_EMAIL" ]; then
                echo -e "${RED}Email is required for SSL setup. Skipping SSL configuration.${NC}"
                return
            fi
        fi
        
        # Install certbot if not present
        if ! command -v certbot &> /dev/null; then
            echo -e "${YELLOW}Installing certbot...${NC}"
            sudo apt update
            sudo apt install -y certbot python3-certbot-nginx
        fi
        
        # Extract USERNAME for domains
        if [ -f .env ] && grep -q "USERNAME=" .env; then
            SSL_USERNAME=$(grep "USERNAME=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        else
            SSL_USERNAME="$NGINX_USERNAME"
        fi
        
        echo -e "${YELLOW}Obtaining SSL certificates for domains:${NC}"
        echo -e "  - ${SSL_USERNAME}.nfttools.io"
        echo -e "  - ${SSL_USERNAME}-api.nfttools.io"
        
        # Obtain SSL certificates
        if sudo certbot --nginx \
            -d "${SSL_USERNAME}.nfttools.io" \
            -d "${SSL_USERNAME}-api.nfttools.io" \
            --non-interactive \
            --agree-tos \
            --email "$SSL_EMAIL" \
            --redirect; then
            
            echo -e "${GREEN}✅ SSL certificates obtained successfully!${NC}"
            
            # Create marker file
            sudo touch "$SSL_MARKER"
            echo "📝 Created SSL marker file: $SSL_MARKER"
            
            # Reload nginx with new SSL configuration
            sudo systemctl reload nginx
            
            echo -e "\n${GREEN}HTTPS is now enabled!${NC}"
            echo -e "Your sites are accessible at:"
            echo -e "  - https://${SSL_USERNAME}.nfttools.io"
            echo -e "  - https://${SSL_USERNAME}-api.nfttools.io"
            echo -e "\nHTTP requests will be automatically redirected to HTTPS."
        else
            echo -e "${RED}Failed to obtain SSL certificates.${NC}"
            echo -e "${YELLOW}You can manually run: sudo certbot --nginx${NC}"
        fi
    fi
fi

# Setup Update Server (Linux only)
if [ "$OS" = "Linux" ]; then
    echo -e "\n${YELLOW}Setting up Update Server on port 9999...${NC}"

    # Check for Node.js
    if ! command -v node >/dev/null 2>&1; then
        echo -e "${YELLOW}Installing Node.js...${NC}"
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -y nodejs
    fi

    # Create update server with wrapper script approach (survives parent restart)
    cat <<'UPDATE_SERVER' > /root/server.js
const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');

const PORT = 9999;
const LOG_FILE = '/var/log/nfttools-update.log';
const STATUS_FILE = '/tmp/update-status.json';
const LOCK_FILE = '/tmp/update-in-progress.lock';

// Logging function
function log(message, level = 'INFO') {
  const timestamp = new Date().toISOString();
  const logLine = `[${timestamp}] [${level}] ${message}\n`;
  try {
    fs.appendFileSync(LOG_FILE, logLine);
  } catch (e) {}
  console.log(logLine.trim());
}

// Update status tracking
function updateStatus(status) {
  try {
    fs.writeFileSync(STATUS_FILE, JSON.stringify({
      ...status,
      timestamp: new Date().toISOString()
    }, null, 2));
  } catch (e) {
    log(`Failed to write status: ${e.message}`, 'ERROR');
  }
}

// Crash protection
process.on('uncaughtException', (error) => {
  log(`Uncaught Exception: ${error.message}`, 'ERROR');
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  log(`Unhandled Rejection: ${reason}`, 'ERROR');
  process.exit(1);
});

log('Update server starting...');

const server = http.createServer((req, res) => {
  const clientIP = (req.connection.remoteAddress || req.socket.remoteAddress || '').replace(/^::ffff:/, '');

  // IP validation - localhost and Docker networks only
  const isAllowed = clientIP === '127.0.0.1' || clientIP === '::1' ||
                   /^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(clientIP);

  if (!isAllowed) {
    log(`Rejected connection from ${clientIP}`, 'WARN');
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: false, message: 'Access denied' }));
    return;
  }

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

  // GET /health - Health check
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      success: true,
      status: 'healthy',
      uptime: process.uptime(),
      timestamp: new Date().toISOString()
    }));
    return;
  }

  // GET /logs - Return last 200 lines of log
  if (req.method === 'GET' && req.url === '/logs') {
    try {
      const logs = fs.existsSync(LOG_FILE)
        ? fs.readFileSync(LOG_FILE, 'utf8').split('\n').slice(-200).join('\n')
        : 'No logs yet';
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end(logs);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('Error reading logs: ' + e.message);
    }
    return;
  }

  // GET /status - Return last update status
  if (req.method === 'GET' && req.url === '/status') {
    try {
      const status = fs.existsSync(STATUS_FILE)
        ? JSON.parse(fs.readFileSync(STATUS_FILE, 'utf8'))
        : { status: 'no updates yet' };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(status));
    } catch (e) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'unknown', error: e.message }));
    }
    return;
  }

  // GET /update - Check server status
  if (req.method === 'GET' && req.url === '/update') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true, message: 'Update server is running' }));
    return;
  }

  // POST /update - Trigger update using wrapper script (survives server restart)
  if (req.method === 'POST' && req.url === '/update') {
    let body = '';
    req.on('data', chunk => body += chunk.toString());
    req.on('end', () => {
      try {
        const { scriptUrl } = JSON.parse(body);

        // Validate URL
        if (!scriptUrl) {
          log('Missing scriptUrl in request', 'ERROR');
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: false, message: 'scriptUrl is required' }));
          return;
        }

        const urlPattern = /^https?:\/\/[^\s<>{}\\|\\^~\[\]`]+$/;
        if (!urlPattern.test(scriptUrl)) {
          log(`Invalid scriptUrl format: ${scriptUrl}`, 'ERROR');
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: false, message: 'Invalid URL format' }));
          return;
        }

        // Check lock file to prevent concurrent updates
        if (fs.existsSync(LOCK_FILE)) {
          try {
            const lockAge = Date.now() - fs.statSync(LOCK_FILE).mtimeMs;
            if (lockAge < 600000) { // 10 minutes
              log(`Update rejected - another update in progress (lock age: ${Math.round(lockAge/1000)}s)`, 'WARN');
              res.writeHead(409, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ success: false, message: 'Update already in progress' }));
              return;
            }
            log(`Stale lock file found (${Math.round(lockAge/1000)}s old), removing...`, 'WARN');
          } catch (e) {}
        }

        log(`=== UPDATE STARTED ===`);
        log(`Script URL: ${scriptUrl}`);
        log(`Client IP: ${clientIP}`);

        // Create lock file
        fs.writeFileSync(LOCK_FILE, Date.now().toString());

        // Create wrapper script that handles its own logging (survives parent death)
        const wrapperScript = `/tmp/update-wrapper-${Date.now()}.sh`;
        const wrapperContent = `#!/bin/bash
# Auto-generated update wrapper script
SCRIPT_URL="${scriptUrl}"
LOG_FILE="/var/log/nfttools-update.log"
STATUS_FILE="/tmp/update-status.json"
LOCK_FILE="/tmp/update-in-progress.lock"

log_msg() {
  echo "[\$(date -Iseconds)] [INFO] \$1" >> "\$LOG_FILE"
}

log_msg "=== WRAPPER SCRIPT STARTED ==="
log_msg "Script URL: \$SCRIPT_URL"
echo '{"status":"running","scriptUrl":"'\$SCRIPT_URL'","startedAt":"'\$(date -Iseconds)'","wrapper":true}' > "\$STATUS_FILE"

# Download script to temp file first
TEMP_SCRIPT="/tmp/nfttools-install-\$\$.sh"
log_msg "Downloading script to \$TEMP_SCRIPT..."
curl -sL "\$SCRIPT_URL" -o "\$TEMP_SCRIPT"
CURL_STATUS=\$?

if [ \$CURL_STATUS -ne 0 ]; then
  log_msg "ERROR: Failed to download script (curl exit code: \$CURL_STATUS)"
  echo '{"status":"failed","error":"download_failed","exitCode":'\$CURL_STATUS',"completedAt":"'\$(date -Iseconds)'"}' > "\$STATUS_FILE"
  rm -f "\$LOCK_FILE" "\$TEMP_SCRIPT"
  exit 1
fi

log_msg "Downloaded script successfully (\$(wc -c < \$TEMP_SCRIPT) bytes). Executing..."
chmod +x "\$TEMP_SCRIPT"

# Execute script and capture output with timestamps
bash "\$TEMP_SCRIPT" 2>&1 | while IFS= read -r line; do
  echo "[\$(date -Iseconds)] [INFO] [OUTPUT] \$line" >> "\$LOG_FILE"
done

PIPE_STATUS=\${PIPESTATUS[0]}
rm -f "\$TEMP_SCRIPT"
log_msg "=== WRAPPER SCRIPT COMPLETED === bash exit code: \$PIPE_STATUS"

if [ \$PIPE_STATUS -eq 0 ]; then
  echo '{"status":"success","exitCode":'\$PIPE_STATUS',"completedAt":"'\$(date -Iseconds)'","wrapper":true}' > "\$STATUS_FILE"
else
  echo '{"status":"failed","exitCode":'\$PIPE_STATUS',"completedAt":"'\$(date -Iseconds)'","wrapper":true}' > "\$STATUS_FILE"
fi

# Cleanup
rm -f "\$LOCK_FILE"
rm -f "${wrapperScript}"
`;

        fs.writeFileSync(wrapperScript, wrapperContent);
        fs.chmodSync(wrapperScript, '755');

        updateStatus({ status: 'running', scriptUrl, startedAt: new Date().toISOString(), wrapper: true });

        // Respond immediately that update started
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, message: 'Update started', status: 'running' }));

        // Execute wrapper script completely detached with nohup
        // This survives even if this Node.js process is restarted
        log(`Launching wrapper script: ${wrapperScript}`);
        const child = spawn('nohup', [wrapperScript], {
          detached: true,
          stdio: 'ignore',
          env: { ...process.env, HOME: '/root' }
        });
        child.unref();

        log('Wrapper script launched successfully');

      } catch (e) {
        log(`Parse error: ${e.message}`, 'ERROR');
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, message: 'Invalid JSON' }));
      }
    });
    return;
  }

  // 404 for unknown routes
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ success: false, message: 'Not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  log(`Update server running on port ${PORT}`);
  log(`PID: ${process.pid}`);
  log(`Node version: ${process.version}`);
});

server.on('error', (e) => {
  log(`Server error: ${e.message}`, 'ERROR');
  process.exit(1);
});
UPDATE_SERVER

    # Create systemd service
    cat <<'SERVICE' > /etc/systemd/system/update-server.service
[Unit]
Description=NFTTools Update Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/node /root/server.js
Restart=always
RestartSec=5
StartLimitIntervalSec=0
StandardOutput=journal
StandardError=journal
SyslogIdentifier=update-server
Environment="NODE_ENV=production"

[Install]
WantedBy=multi-user.target
SERVICE

    # Configure UFW for port 9999 (localhost and Docker only)
    if command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring firewall for update server...${NC}"
        # Remove existing rules for port 9999 first
        sudo ufw status numbered 2>/dev/null | grep 9999 | awk -F'[][]' '{print $2}' | sort -rn | while read -r num; do
            [ -n "$num" ] && sudo ufw --force delete "$num" 2>/dev/null
        done
        # Add new rules
        sudo ufw allow from 127.0.0.1 to any port 9999 comment 'Update server - localhost' 2>/dev/null || true
        sudo ufw allow from 172.16.0.0/12 to any port 9999 comment 'Update server - Docker' 2>/dev/null || true
    fi

    # Enable and start service
    systemctl daemon-reload
    systemctl enable update-server
    systemctl restart update-server

    if systemctl is-active --quiet update-server; then
        echo -e "${GREEN}Update server is running on port 9999${NC}"
        echo -e "Endpoints:"
        echo -e "  GET  /health - Health check"
        echo -e "  GET  /logs   - View recent update logs"
        echo -e "  GET  /status - Last update status"
        echo -e "  POST /update - Trigger update"
        echo -e "Logs: /var/log/nfttools-update.log"
    else
        echo -e "${RED}Failed to start update server${NC}"
        systemctl status update-server --no-pager
    fi
fi

# Final completion marker
echo "========== Installation completed at $(date) =========="
echo "{\"success\": true, \"timestamp\": \"$(date -Iseconds)\"}" > /tmp/install-status.json
