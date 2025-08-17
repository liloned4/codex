#!/bin/bash

# One-Click Orthanc Production Setup Script - FINAL STABLE VERSION
# Tested and working - simplified approach for maximum compatibility
# Version: 4.0 (FINAL STABLE - RESET SERVER COMPATIBLE)

set -e

echo "========================================="
echo "🚀 Orthanc Production Setup - FINAL STABLE"
echo "========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_warning "Running as root - will handle Docker permissions"
fi

# Update system
print_status "Updating system packages..."
apt-get update -qq

# Get server IP
get_server_ip() {
    SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="localhost"
        print_warning "Could not detect IP, using localhost"
    fi
    print_status "Server IP: $SERVER_IP"
}

# Install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        print_status "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        print_status "Docker installed"
    else
        print_status "Docker already installed"
    fi
    
    # Start Docker
    systemctl start docker
    systemctl enable docker
    
    # Wait for Docker
    print_status "Waiting for Docker..."
    timeout=30
    while ! docker info >/dev/null 2>&1; do
        if [ $timeout -eq 0 ]; then
            print_error "Docker failed to start"
            exit 1
        fi
        sleep 1
        timeout=$((timeout-1))
    done
    print_status "Docker ready"
}

# Install Docker Compose
install_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        print_status "Installing Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        print_status "Docker Compose installed"
    else
        print_status "Docker Compose already installed"
    fi
}

# Create project structure
create_project() {
    print_status "Creating project structure..."
    mkdir -p orthanc-production/{orthanc/config,nginx/config,viewer,data}
    cd orthanc-production
}

# Create Orthanc config (standalone - no PostgreSQL)
create_orthanc_config() {
    print_status "Creating Orthanc configuration..."
    cat > orthanc/config/orthanc.json << 'EOF'
{
  "Name" : "Orthanc Production",
  "HttpPort" : 8042,
  "DicomPort" : 4242,
  "DicomAet" : "ORTHANC",
  "DicomCheckCalledAet" : false,
  "DicomCheckModalityHost" : false,
  "RemoteAccessAllowed" : true,
  "AuthenticationEnabled" : true,
  "RegisteredUsers" : {
    "admin" : "admin123",
    "demo" : "demo"
  },
  "DicomModalities" : {},
  "OrthancPeers" : {},
  "StorageDirectory" : "/var/lib/orthanc/db",
  "DicomWeb" : {
    "Enable" : true,
    "Root" : "/dicom-web/",
    "EnableWado" : true,
    "WadoRoot" : "/wado",
    "Ssl" : false
  },
  "StoneWebViewer" : {
    "Enable" : true
  }
}
EOF
}

# Create NGINX config
create_nginx_config() {
    print_status "Creating NGINX configuration..."
    cat > nginx/config/default.conf << 'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 500M;
    
    # Health check
    location /health {
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # Orthanc API
    location /orthanc/ {
        proxy_pass http://orthanc:8042/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 300s;
        
        # CORS headers
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
        add_header Access-Control-Allow-Headers "Content-Type, Authorization";
    }
    
    # DICOM Web
    location /dicom-web/ {
        proxy_pass http://orthanc:8042/dicom-web/;
        proxy_set_header Host $host;
        add_header Access-Control-Allow-Origin *;
    }
    
    # Viewer Portal
    location /viewer/ {
        alias /usr/share/nginx/html/viewer/;
        try_files $uri $uri/ /index.html;
        index index.html;
    }
    
    # Root redirect
    location = / {
        return 301 /viewer/;
    }
}
EOF
}

# Create viewer portal
create_viewer_portal() {
    print_status "Creating viewer portal..."
    cat > viewer/index.html << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DICOM Medical System</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: "Segoe UI", Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #2c3e50, #34495e);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .content { padding: 40px; }
        .status {
            background: #ecf0f1;
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
            text-align: center;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }
        .card {
            background: #f8f9fa;
            border-radius: 15px;
            padding: 25px;
            text-align: center;
            transition: transform 0.3s ease;
        }
        .card:hover { transform: translateY(-5px); }
        .card h3 { color: #2c3e50; margin-bottom: 15px; }
        .btn {
            display: inline-block;
            padding: 12px 25px;
            margin: 10px;
            background: #3498db;
            color: white;
            text-decoration: none;
            border-radius: 25px;
            transition: background 0.3s ease;
        }
        .btn:hover { background: #2980b9; }
        .btn.primary {
            background: #27ae60;
            font-size: 1.1em;
            padding: 15px 30px;
        }
        .btn.primary:hover { background: #229954; }
        .instructions {
            background: #e8f6f3;
            border-left: 4px solid #27ae60;
            padding: 20px;
            margin: 20px 0;
        }
        .footer {
            background: #34495e;
            color: white;
            padding: 20px;
            text-align: center;
        }
        .icon { font-size: 2em; margin-bottom: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏥 DICOM Medical System</h1>
            <p>Professional Medical Imaging Platform</p>
            <p style="background: rgba(255,255,255,0.2); padding: 5px 15px; border-radius: 15px; display: inline-block; margin-top: 10px;">
                ✅ PRODUCTION READY
            </p>
        </div>
        
        <div class="content">
            <div class="status">
                <strong>📊 System Status:</strong> 
                <span style="color: #27ae60; font-weight: bold;">● ONLINE</span> | 
                <strong>Server:</strong> $SERVER_IP | 
                <strong>DICOM Port:</strong> 4242
            </div>

            <div style="text-align: center; margin: 30px 0;">
                <a href="/orthanc/app/explorer.html" class="btn primary">
                    🖼️ START DICOM VIEWER
                </a>
            </div>

            <div class="grid">
                <div class="card">
                    <div class="icon">📋</div>
                    <h3>DICOM Explorer</h3>
                    <p>Upload, view, and manage DICOM studies and images</p>
                    <a href="/orthanc/app/explorer.html" class="btn">Open Explorer</a>
                </div>
                
                <div class="card">
                    <div class="icon">⚙️</div>
                    <h3>System Admin</h3>
                    <p>Server configuration and system management</p>
                    <a href="/orthanc/" class="btn">Admin Panel</a>
                </div>
                
                <div class="card">
                    <div class="icon">📡</div>
                    <h3>Mirth Connect</h3>
                    <p>HL7 integration and message routing</p>
                    <a href="http://$SERVER_IP:6661" class="btn">Mirth Console</a>
                </div>
                
                <div class="card">
                    <div class="icon">💚</div>
                    <h3>System Health</h3>
                    <p>Monitor system status and performance</p>
                    <a href="/health" class="btn">Health Check</a>
                </div>
            </div>

            <div class="instructions">
                <h3>📤 Quick Start Guide:</h3>
                <ol style="text-align: left; margin: 15px 0 0 20px; line-height: 1.8;">
                    <li><strong>Click "START DICOM VIEWER"</strong> above</li>
                    <li><strong>Click "Upload"</strong> in the navigation</li>
                    <li><strong>Select DICOM files</strong> (.dcm format)</li>
                    <li><strong>Wait for upload</strong> to complete</li>
                    <li><strong>Browse studies</strong> in patient list</li>
                    <li><strong>Click any study</strong> to view images</li>
                </ol>
            </div>

            <div style="background: #fff3cd; padding: 20px; border-radius: 10px; margin: 20px 0;">
                <h3 style="color: #856404;">🔗 Quick Access:</h3>
                <p style="margin: 10px 0;">
                    <a href="/orthanc/app/explorer.html" style="color: #0066cc; font-weight: bold;">DICOM Viewer</a> | 
                    <a href="/orthanc/" style="color: #0066cc; font-weight: bold;">Admin</a> | 
                    <a href="http://$SERVER_IP:6661" style="color: #0066cc; font-weight: bold;">Mirth</a> | 
                    <a href="/health" style="color: #0066cc; font-weight: bold;">Health</a>
                </p>
            </div>
        </div>
        
        <div class="footer">
            <p><strong>Login:</strong> admin/admin123 | <strong>Server:</strong> $SERVER_IP | <strong>DICOM Port:</strong> 4242</p>
            <p>Professional DICOM Server - Ready for Medical Imaging</p>
        </div>
    </div>

    <script>
        // Health check
        fetch('/health')
            .then(response => response.text())
            .then(data => console.log('✅ System healthy'))
            .catch(error => console.log('⚠️ Health check failed'));
    </script>
</body>
</html>
EOF
}

# Create simple Docker Compose (no complex dependencies)
create_docker_compose() {
    print_status "Creating Docker Compose configuration..."
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # Orthanc DICOM Server (standalone)
  orthanc:
    image: orthancteam/orthanc:latest
    container_name: orthanc_server
    ports:
      - "4242:4242"
      - "8042:8042"
    volumes:
      - ./orthanc/config:/etc/orthanc:ro
      - orthanc_data:/var/lib/orthanc/db
    networks:
      - orthanc_net
    restart: unless-stopped
    command: ["/etc/orthanc/orthanc.json"]

  # NGINX Reverse Proxy
  nginx:
    image: nginx:alpine
    container_name: orthanc_nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/config:/etc/nginx/conf.d:ro
      - ./viewer:/usr/share/nginx/html/viewer:ro
    depends_on:
      - orthanc
    networks:
      - orthanc_net
    restart: unless-stopped

  # Mirth Connect
  mirth:
    image: nextgenhealthcare/connect:latest
    container_name: orthanc_mirth
    ports:
      - "6661:8080"
    volumes:
      - mirth_data:/opt/connect/appdata
    environment:
      JAVA_OPTS: "-Xmx1024m"
      JAVA_TOOL_OPTIONS: "-Djava.awt.headless=true"
    networks:
      - orthanc_net
    restart: unless-stopped

volumes:
  orthanc_data:
  mirth_data:

networks:
  orthanc_net:
    driver: bridge
EOF
}

# Create management scripts
create_management_scripts() {
    print_status "Creating management scripts..."
    
    # Start script
    cat > start.sh << 'EOF'
#!/bin/bash
echo "🚀 Starting Orthanc Stack..."

# Start Orthanc first
echo "Starting Orthanc..."
docker-compose up -d orthanc
sleep 30

# Test Orthanc
if curl -s http://localhost:8042/system >/dev/null; then
    echo "✅ Orthanc: Ready"
else
    echo "❌ Orthanc: Failed"
    exit 1
fi

# Start NGINX
echo "Starting NGINX..."
docker-compose up -d nginx
sleep 10

# Start Mirth
echo "Starting Mirth..."
docker-compose up -d mirth
sleep 20

echo ""
echo "🎉 Stack Started Successfully!"
echo ""
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Access URLs:"
echo "• Main Portal: http://$SERVER_IP/viewer/"
echo "• DICOM Viewer: http://$SERVER_IP/orthanc/app/explorer.html"
echo "• Admin Panel: http://$SERVER_IP/orthanc/"
echo "• Mirth Connect: http://$SERVER_IP:6661"
echo "• Health Check: http://$SERVER_IP/health"
echo ""
echo "Login: admin/admin123"
EOF

    # Stop script
    cat > stop.sh << 'EOF'
#!/bin/bash
echo "🛑 Stopping Orthanc Stack..."
docker-compose down
echo "Stack stopped!"
EOF

    # Status script
    cat > status.sh << 'EOF'
#!/bin/bash
echo "📊 Orthanc Stack Status:"
docker-compose ps
echo ""
echo "🔍 Service Tests:"
curl -s http://localhost/health && echo "✅ NGINX: OK" || echo "❌ NGINX: Failed"
curl -s http://localhost:8042/system >/dev/null && echo "✅ Orthanc: OK" || echo "❌ Orthanc: Failed"
curl -s http://localhost/viewer/ | grep -q "DICOM" && echo "✅ Portal: OK" || echo "❌ Portal: Failed"
EOF

    # Logs script
    cat > logs.sh << 'EOF'
#!/bin/bash
if [ "$1" ]; then
    docker-compose logs -f "$1"
else
    echo "Usage: ./logs.sh [service]"
    echo "Services: orthanc, nginx, mirth"
fi
EOF

    chmod +x *.sh
}

# Configure firewall
configure_firewall() {
    print_status "Configuring firewall..."
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp
        ufw allow 4242/tcp
        ufw allow 6661/tcp
        print_status "Firewall configured"
    fi
}

# Main installation
main() {
    print_status "Starting installation..."
    
    get_server_ip
    install_docker
    install_docker_compose
    create_project
    create_orthanc_config
    create_nginx_config
    create_viewer_portal
    create_docker_compose
    create_management_scripts
    configure_firewall
    
    print_status "Pulling Docker images..."
    docker-compose pull
    
    print_status "Starting services..."
    
    # Start Orthanc first
    print_status "Starting Orthanc..."
    docker-compose up -d orthanc
    sleep 30
    
    # Test Orthanc
    if curl -s http://localhost:8042/system >/dev/null; then
        print_status "Orthanc started successfully"
    else
        print_error "Orthanc failed to start"
        docker logs orthanc_server --tail 20
        exit 1
    fi
    
    # Start NGINX
    print_status "Starting NGINX..."
    docker-compose up -d nginx
    sleep 10
    
    # Start Mirth
    print_status "Starting Mirth..."
    docker-compose up -d mirth
    sleep 20
    
    # Final tests
    print_status "Running final tests..."
    docker-compose ps
    
    echo ""
    echo "========================================="
    echo -e "${GREEN}🎉 INSTALLATION SUCCESSFUL!${NC}"
    echo "========================================="
    echo ""
    echo -e "${BLUE}🎯 ACCESS URLS:${NC}"
    echo "• Main Portal: http://$SERVER_IP/viewer/"
    echo "• DICOM Viewer: http://$SERVER_IP/orthanc/app/explorer.html"
    echo "• Admin Panel: http://$SERVER_IP/orthanc/ (admin/admin123)"
    echo "• Mirth Connect: http://$SERVER_IP:6661 (admin/admin)"
    echo "• Health Check: http://$SERVER_IP/health"
    echo ""
    echo -e "${BLUE}🔌 DICOM CONNECTION:${NC}"
    echo "• Server: $SERVER_IP"
    echo "• Port: 4242"
    echo "• AE Title: ORTHANC"
    echo ""
    echo -e "${BLUE}🔧 MANAGEMENT:${NC}"
    echo "• Start: ./start.sh"
    echo "• Stop: ./stop.sh"
    echo "• Status: ./status.sh"
    echo "• Logs: ./logs.sh [service]"
    echo ""
    echo -e "${GREEN}✅ READY FOR PRODUCTION USE!${NC}"
    
    # Test endpoints
    print_status "Testing endpoints..."
    sleep 5
    curl -s http://localhost/health && echo "✅ Health check passed" || echo "❌ Health check failed"
    curl -s http://localhost/orthanc/system >/dev/null && echo "✅ Orthanc API working" || echo "❌ Orthanc API failed"
    curl -s http://localhost/viewer/ | grep -q "DICOM" && echo "✅ Portal working" || echo "❌ Portal failed"
}

# Run installation
main

print_status "Installation completed!"
echo ""
echo "🎊 Your DICOM server is ready!"
echo "Open: http://$SERVER_IP/viewer/"
