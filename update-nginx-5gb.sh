#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if USERNAME is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Please provide a username as the first argument${NC}"
    echo "Usage: $0 USERNAME"
    exit 1
fi

USERNAME=$1

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
    server_name ${USERNAME}.nfttools.io;
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

        # CORS headers (commented out, uncomment if needed)
        # add_header 'Access-Control-Allow-Origin' '*';
        # add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
        # add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
    }
}

# API site configuration
server {
    server_name ${USERNAME}-api.nfttools.io;
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

        # CORS headers (commented out, uncomment if needed)
        # add_header 'Access-Control-Allow-Origin' '*';
        # add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
        # add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
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
else
    echo "❌ Nginx configuration test failed, removing symlink"
    sudo rm /etc/nginx/sites-enabled/nfttools.io
    exit 1
fi

echo -e "\n${GREEN}✅ Nginx configuration updated successfully!${NC}"
echo -e "The following changes were made:"
echo -e "  - client_max_body_size increased to 5G"
echo -e "  - Extended timeouts to 1200s (20 minutes) for large downloads"
echo -e "  - Disabled proxy buffering for efficient large file handling"
echo -e "  - Optimized buffer sizes for better performance"
echo -e "\nBoth ${USERNAME}.nfttools.io and ${USERNAME}-api.nfttools.io now support 5GB file transfers."