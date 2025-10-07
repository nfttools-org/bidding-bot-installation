#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Repository and version information
REGISTRY="nfttools"
VERSION="multi-chain"

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

# Clear Redis and server volumes for fresh installation (preserving MongoDB)
echo -e "${YELLOW}Removing Redis and server volumes for fresh installation (MongoDB data will be preserved)...${NC}"

# Get all volumes related to the application
APP_VOLUMES=$(docker volume ls -q | grep -E "(nft-bidding-bot_|redis_data|server_data|mongodb_data)")
if [ ! -z "$APP_VOLUMES" ]; then
    echo -e "${YELLOW}Found application volumes:${NC}"
    echo "$APP_VOLUMES"
    
    echo -e "${YELLOW}Preserving MongoDB data...${NC}"
    # Remove all volumes except MongoDB
    VOLUMES_TO_REMOVE=$(echo "$APP_VOLUMES" | grep -v "mongodb")
    
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
else
    echo -e "${YELLOW}Creating new .env file...${NC}"
    cat > .env << EOL
MONGODB_URI=mongodb://mongodb:27017/BIDDING_BOT
PORT_SERVER=3003
PORT_CLIENT=3001
SERVER_IP=${SERVER_IP}
REDIS_HOST=redis
REDIS_PORT=6379
EOL
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

echo -e "${YELLOW}Starting services...${NC}"
docker compose up -d

# Check health
echo -e "${YELLOW}Checking service health...${NC}"
sleep 10

if curl -sk http://localhost:3003/health > /dev/null; then
    echo -e "${GREEN}Server is healthy!${NC}"
else
    echo -e "${RED}Server health check failed${NC}"
fi

if curl -sk http://localhost:3001 > /dev/null; then
    echo -e "${GREEN}Client is accessible!${NC}"
else
    echo -e "${RED}Client health check failed${NC}"
fi

echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "Remote Server running at: http://${SERVER_IP}:3003"
echo -e "Remote Client running at: http://${SERVER_IP}:3001"
echo -e "\nUseful commands:"
echo -e "${YELLOW}cd $PROJECT_DIR${NC}"
echo -e "${YELLOW}docker compose ps${NC} - Check service status"
echo -e "${YELLOW}docker compose logs${NC} - View logs"
echo -e "${YELLOW}docker compose down${NC} - Stop services"

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
