#!/bin/bash

#***********************************************************#
#                                                           #
#  Nome: pg_bd_etcd_cluster_setup_deb.sh                    #
#  Autor: Ozano Neto                                        #
#  Descricao: Criar cluster etcd para patroni               #
#  Run Script on each node with appropriate parameters      #
#                                                           #
#  BDADOS TECNOLOGIA LTDA                                   #
#  http://www.bdados.com.br                                 #
#                                                           #
#***********************************************************#

set -e

#============================================================
# STEP 1: CONFIGURATIONS
#============================================================

# etcd version
ETCD_VERSION="3.6.5"

# System User and Directories
ETCD_USER="etcd"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_CONFIG_DIR="/etc/etcd"
ETCD_LOG_DIR="/var/log/etcd"
CLUSTER_TOKEN="pgha-etcd-cluster"

# Architecture detection (will be set automatically)
ETCD_ARCH=""

#============================================================
# STEP 2: NODES IP CONFIGURATION
#============================================================
# Node 1
NODE1_NAME="lx-pgnode-01"
NODE1_IP="10.0.0.4"

# Node 2
NODE2_NAME="lx-pgnode-02"
NODE2_IP="10.0.0.5"

# Node 3
NODE3_NAME="lx-pgnode-03"
NODE3_IP="10.0.0.6"

#============================================================
# HELPER FUNCTIONS
#============================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_step() {
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root"
        log_error "This script must be run as root"
        exit 1
    fi
}

# Detect system architecture
detect_architecture() {
    log_step "Detecting System Architecture"
    
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            ETCD_ARCH="amd64"
            log_info "Architecture detected: AMD64/x86_64"
            ;;
        aarch64|arm64)
            ETCD_ARCH="arm64"
            log_info "Architecture detected: ARM64/aarch64"
            ;;
        armv7l|armhf)
            ETCD_ARCH="arm"
            log_info "Architecture detected: ARM v7"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            log_error "Supported architectures: amd64, arm64, arm"
            exit 1
            ;;
    esac
}

# Detect current node
detect_node() {
    local current_ip=$(hostname -I | awk '{print $1}')
    
    if [[ "$current_ip" == "$NODE1_IP" ]]; then
        CURRENT_NODE_NAME="$NODE1_NAME"
        CURRENT_NODE_IP="$NODE1_IP"
        NODE_NUMBER=1
    elif [[ "$current_ip" == "$NODE2_IP" ]]; then
        CURRENT_NODE_NAME="$NODE2_NAME"
        CURRENT_NODE_IP="$NODE2_IP"
        NODE_NUMBER=2
    elif [[ "$current_ip" == "$NODE3_IP" ]]; then
        CURRENT_NODE_NAME="$NODE3_NAME"
        CURRENT_NODE_IP="$NODE3_IP"
        NODE_NUMBER=3
    else
        log_error "Current IP ($current_ip) does not match any configured node"        
        log_error "Configure the correct IPs at the beginning of the script"
        exit 1
    fi
    
    log_info "Node Detected: $CURRENT_NODE_NAME ($CURRENT_NODE_IP)"
}

# Build cluster string dynamically for current node
build_cluster_string() {
    local cluster_members=""
    
    # Always include current node
    cluster_members="${CURRENT_NODE_NAME}=http://${CURRENT_NODE_IP}:2380"
    
    # Add other nodes
    if [[ "$CURRENT_NODE_IP" != "$NODE1_IP" ]]; then
        cluster_members="${cluster_members},${NODE1_NAME}=http://${NODE1_IP}:2380"
    fi
    
    if [[ "$CURRENT_NODE_IP" != "$NODE2_IP" ]]; then
        cluster_members="${cluster_members},${NODE2_NAME}=http://${NODE2_IP}:2380"
    fi
    
    if [[ "$CURRENT_NODE_IP" != "$NODE3_IP" ]]; then
        cluster_members="${cluster_members},${NODE3_NAME}=http://${NODE3_IP}:2380"
    fi
    
    echo "$cluster_members"
}

# Show configs
show_configuration() {
    log_step "CLUSTER CONFIGURATION"
    echo ""
    echo "  etcd Version: $ETCD_VERSION"
    echo "  Architecture: $ETCD_ARCH"
    echo "  Cluster Token: $CLUSTER_TOKEN"
    echo ""
    echo "  Node 01: $NODE1_NAME - $NODE1_IP"
    echo "  Node 02: $NODE2_NAME - $NODE2_IP"
    echo "  Node 03: $NODE3_NAME - $NODE3_IP"
    echo ""
    echo "  Current Node: $CURRENT_NODE_NAME ($CURRENT_NODE_IP)"
    echo "  Cluster String: $(build_cluster_string)"
    echo ""
    read -p "Continue with Installation? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Installation Cancelled"
        exit 0
    fi
}

#============================================================
# STEP 3: DOWNLOAD AND INSTALL
#============================================================

install_dependencies() {
    log_step "Installing dependencies"
    
    apt-get update -qq
    apt-get install -y wget curl tar
    
    log_info "Dependencies Installed"
}

create_etcd_user() {
    log_step "Creating etcd User"
    
    if id "$ETCD_USER" &>/dev/null; then
        log_warn "User $ETCD_USER already exists"
    else
        useradd --system --home-dir "$ETCD_DATA_DIR" --shell /bin/false "$ETCD_USER"
        log_info "User $ETCD_USER created"
    fi
}

create_directories() {
    log_step "Creating Directories"
    
    mkdir -p "$ETCD_DATA_DIR"
    mkdir -p "$ETCD_CONFIG_DIR"
    mkdir -p "$ETCD_LOG_DIR"
    
    chown -R "$ETCD_USER:$ETCD_USER" "$ETCD_DATA_DIR"
    chown -R "$ETCD_USER:$ETCD_USER" "$ETCD_LOG_DIR"
    
    log_info "Directories created:"
    log_info "  - $ETCD_DATA_DIR"
    log_info "  - $ETCD_CONFIG_DIR"
    log_info "  - $ETCD_LOG_DIR"
}

download_and_install_etcd() {
    log_step "Downloading and installing etcd"
    
    # Check if already installed
    if [[ -f /usr/local/bin/etcd ]]; then
        local installed_version=$(/usr/local/bin/etcd --version 2>/dev/null | head -n1 | awk '{print $3}')
        if [[ "$installed_version" == "$ETCD_VERSION" ]]; then
            log_warn "etcd $ETCD_VERSION already installed"
            return 0
        else
            log_info "Installed version: $installed_version"
            log_info "Updating to: $ETCD_VERSION"
        fi
    fi
    
    # Download with architecture-specific URL
    cd /tmp
    local download_url="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"
    local tarball="etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"
    
    log_info "Baixando de / Downloading from: $download_url"
    
    if [[ -f "$tarball" ]]; then
        rm -f "$tarball"
    fi
    
    wget -q --show-progress "$download_url" || {
        log_error "Falha no download / Download failed"
        log_error "URL: $download_url"
        exit 1
    }
    
    # Extract
    log_info "Extraindo arquivos / Extracting files..."
    tar -xzf "$tarball"
    
    # Install binaries
    log_info "Instalando binários / Installing binaries..."
    cp "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcd" /usr/local/bin/
    cp "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdctl" /usr/local/bin/
    cp "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdutl" /usr/local/bin/
    
    chmod +x /usr/local/bin/etcd
    chmod +x /usr/local/bin/etcdctl
    chmod +x /usr/local/bin/etcdutl
    
    # Cleanup
    rm -rf "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}"*
    
    # Verify installation
    local version=$(/usr/local/bin/etcd --version | head -n1)
    log_info "etcd instalado / installed: $version"
}

configure_etcd() {
    log_step "Configuring etcd"
    
    # Build cluster string for this node
    local cluster_string=$(build_cluster_string)
    
    log_info "Cluster string: $cluster_string"
    
    # Create configuration file
    cat > "$ETCD_CONFIG_DIR/etcd.conf" << EOF
# etcd Configuration for $CURRENT_NODE_NAME - Generated on $(date)
ETCD_NAME="$CURRENT_NODE_NAME"
ETCD_DATA_DIR="$ETCD_DATA_DIR"
ETCD_INITIAL_CLUSTER="$cluster_string"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="$CLUSTER_TOKEN"
ETCD_LISTEN_PEER_URLS="http://$CURRENT_NODE_IP:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$CURRENT_NODE_IP:2380"
ETCD_LISTEN_CLIENT_URLS="http://$CURRENT_NODE_IP:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://$CURRENT_NODE_IP:2379"
ETCD_ELECTION_TIMEOUT="5000"
ETCD_HEARTBEAT_INTERVAL="1000"
ETCD_INITIAL_ELECTION_TICK_ADVANCE="false"
ETCD_AUTO_COMPACTION_RETENTION="1"
ETCD_QUOTA_BACKEND_BYTES="6442450944"
ETCD_LOG_LEVEL="info"
ETCD_LOG_OUTPUTS="$ETCD_LOG_DIR/etcd.log"
EOF
    
    chown etcd:etcd "$ETCD_CONFIG_DIR/etcd.conf"
    chmod 644 "$ETCD_CONFIG_DIR/etcd.conf"
    
    log_info "Configuration file created"
    log_info " --> $ETCD_CONFIG_DIR/etcd.conf"
}

create_systemd_service() {
    log_step "Creating systemd service"
    
    cat > /etc/systemd/system/etcd.service << 'EOF'
[Unit]
Description=Etcd Server - Orchestrate a High Availability PostgreSQL - Patroni
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd
EnvironmentFile=/etc/etcd/etcd.conf
User=etcd
ExecStart=/bin/bash -c "GOMAXPROCS=$(nproc) /usr/local/bin/etcd"
Restart=on-failure

# Resource limits
LimitNOFILE=65536
LimitNPROC=8192
IOSchedulingClass=realtime
IOSchedulingPriority=0
Nice=-20

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "Systemd service created"
}

stop_existing_etcd() {
    if systemctl is-active --quiet etcd 2>/dev/null; then
        log_warn "Stopping existing etcd"
        systemctl stop etcd
    fi
}

prepare_etcd_service() {
    log_step "Preparing etcd service"
    echo ""
    systemctl enable etcd
    echo ""
    log_info "etcd service enabled but NOT started"    
    log_warn "You must start the service MANUALLY after all nodes are ready"
}

verify_cluster() {
    log_step "Configuration Completed"
    echo ""
    log_info "Cluster Configured, but Services NOT started"
    echo ""
    log_warn "Services must be started MANUALLY"
}

show_post_install_info() {
    log_step "INSTALLATION COMPLETED"
    
    echo ""
    echo "================================================"
    echo "  Node configured: $CURRENT_NODE_NAME"
    echo "  IP: $CURRENT_NODE_IP"
    echo "  Architecture: $ETCD_ARCH"
    echo "  READY BUT NOT STARTED"
    echo "================================================"
    echo ""
    
    if [[ $NODE_NUMBER -eq 1 ]]; then
        log_warn "NEXT STEPS (NODE 1 - bootstrap):"
        echo ""
        echo "1) Configure NODE 2 and NODE 3 by running this script on each node"
        echo ""
        echo "2) Start etcd on NODE 1 FIRST:"
        echo "   sudo systemctl start etcd.service$"
        echo "   sudo systemctl status etcd.service"
        echo ""
        echo "3) Verify NODE 1 is running and check cluster status:"
        echo "   etcdctl --endpoints=http://127.0.0.1:2379 member list"
        echo ""
        echo "========================================================================="
        echo "4) Add NODE 2 and NODE 3 as members (run on NODE 1):"
        echo ""
        echo "========================================================================="
        echo "   etcdctl member add ${NODE2_NAME} --peer-urls=http://${NODE2_IP}:2380"
        echo "========================================================================="
        echo ""
        echo "   Expected Output:"
        echo "   ========================================================================="        
        echo "   │ ETCD_NAME=\"${NODE2_NAME}\""
        echo "   │ ETCD_INITIAL_CLUSTER=\"${NODE1_NAME}=http://${NODE1_IP}:2380,${NODE2_NAME}=http://${NODE2_IP}:2380\""
        echo "   │ ETCD_INITIAL_CLUSTER_STATE=\"existing\""
        echo "   ========================================================================="
        echo ""
        echo "========================================================================="
        echo "   etcdctl member add ${NODE3_NAME} --peer-urls=http://${NODE3_IP}:2380"
        echo "========================================================================="
        echo ""
        echo "   Expected Output:"
        echo "   ========================================================================="        
        echo "   │ ETCD_NAME=\"${NODE3_NAME}\""
        echo "   │ ETCD_INITIAL_CLUSTER=\"${NODE1_NAME}=http://${NODE1_IP}:2380,${NODE2_NAME}=http://${NODE2_IP}:2380,${NODE3_NAME}=http://${NODE3_IP}:2380\""
        echo "   │ ETCD_INITIAL_CLUSTER_STATE=\"existing\""
        echo "   ========================================================================="        
        echo ""
        echo "5) Update NODE 2 config to join existing cluster:"
        echo "   NODE 2 (${NODE2_IP})"
        echo "   sudo sed -i 's/ETCD_INITIAL_CLUSTER_STATE=\"new\"/ETCD_INITIAL_CLUSTER_STATE=\"existing\"/' /etc/etcd/etcd.conf"        
        echo ""
        echo "6) Update NODE 3 config to join existing cluster:"
        echo "   NODE 3 (${NODE3_IP})"
        echo "   sudo sed -i 's/ETCD_INITIAL_CLUSTER_STATE=\"new\"/ETCD_INITIAL_CLUSTER_STATE=\"existing\"/' /etc/etcd/etcd.conf"
        echo ""
        echo "7) Verify full cluster health (run from any node):"
        echo "   etcdctl --endpoints=http://${NODE1_IP}:2379,http://${NODE2_IP}:2379,http://${NODE3_IP}:2379 endpoint health"
        echo "   etcdctl member list"
        echo ""
    elif [[ $NODE_NUMBER -eq 2 ]]; then
        log_warn "NEXT STEP (NODE 2):"
        echo ""
        echo "1) Configure NODE 3 by running this script"
        echo ""
        echo "2) Wait for instructions from NODE 1 operator"
        echo "   - NODE 1 must start first"
        echo "   - NODE 1 operator will add this node with: etcdctl member add${NC}"
        echo "   - Then update config and start this node"
        echo ""
        echo "3) When ready, NODE 1 operator will execute:"
        echo "   etcdctl member add ${NODE2_NAME} --peer-urls=http://${NODE2_IP}:2380"
        echo ""
        echo "4) After member add completes, update config HERE on NODE 2:"
        echo "   sudo sed -i 's/ETCD_INITIAL_CLUSTER_STATE=\"new\"/ETCD_INITIAL_CLUSTER_STATE=\"existing\"/' /etc/etcd/etcd.conf"
        echo "   sudo systemctl start etcd.service"
        echo ""
    else
        log_info "ALL NODES CONFIGURED (NODE 3)"
        echo ""
        log_warn "Wait for instructions from NODE 1 operator"
        echo ""
        echo "Node 3 is ready but MUST wait for:"
        echo "  1) NODE 1 to start"
        echo "  2) NODE 2 to be added and started"
        echo "  3) NODE 1 operator to add NODE 3"
        echo ""
        echo "When ready, NODE 1 operator will execute:"
        echo "  etcdctl member add ${NODE3_NAME} --peer-urls=http://${NODE3_IP}:2380"
        echo ""
        echo "After member add completes, update config HERE on NODE 3:"
        echo "  sudo sed -i 's/ETCD_INITIAL_CLUSTER_STATE=\"new\"/ETCD_INITIAL_CLUSTER_STATE=\"existing\"/' /etc/etcd/etcd.conf"
        echo "  sudo systemctl start etcd.service"
        echo ""
        echo "After NODE 3 starts, verify full cluster (from any node):"
        echo "  etcdctl --endpoints=http://${NODE1_IP}:2379,http://${NODE2_IP}:2379,http://${NODE3_IP}:2379 endpoint health"
        echo "  etcdctl member list${NC}"
        echo ""        
        echo "=========================================================================" 
    fi
}

#=======================================
# MAIN EXECUTION 
#=======================================

main() {
    log_step "STARTING ETCD CLUSTER INSTALLATION"
    
    # Pre-flight checks
    check_root
    detect_architecture
    detect_node
    show_configuration
    
    # Installation steps
    install_dependencies
    create_etcd_user
    create_directories
    download_and_install_etcd
    
    # Configuration
    stop_existing_etcd
    configure_etcd
    create_systemd_service
    
    # Start and verify
    prepare_etcd_service
    verify_cluster
    
    # Final info
    show_post_install_info
    
    log_info "Script Completed Successfully!"
}

# Execute main function
main "$@"