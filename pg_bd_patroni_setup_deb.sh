#!/bin/bash

#***********************************************************#
#                                                           #
#  Nome: pg_bd_patroni_setup_deb.sh                         #
#  Autor: Ozano Neto                                        #
#  Descricao: Criar cluster PostgreSQL HA com Patroni       #
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

POSTGRES_VERSION="17"
PATRONI_VERSION="4.0.7"
POSTGRES_USER="postgres"
PATRONI_USER="postgres"
POSTGRES_DATA_DIR="/var/lib/postgresql"
PATRONI_CONFIG_DIR="/etc/patroni"
PATRONI_LOG_DIR="/var/log/patroni"
POSTGRES_PORT="5432"
PATRONI_API_PORT="8008"

# Default cluster configuration
CLUSTER_NAME="pg-etcd-cluster"
SCOPE="pg-etcd-cluster"

#============================================================
# HELPER FUNCTIONS
#============================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to print usage
usage() {
    log_step "POSTGRESQL HA - WITH PATRONI and ETCD"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Required Options:"
    echo "  -n, --node-name     Node name (e.g., lx-pgnode-01, lx-pgnode-02, lx-pgnode-03)"
    echo "  -i, --node-ip       IP address of this PostgreSQL node"
    echo "  -e, --etcd-hosts    Comma-separated etcd endpoints (host1:2379,host2:2379,host3:2379)"
    echo ""
    echo "Optional Parameters:"
    echo "  -c, --cluster-name  Cluster name (default: $CLUSTER_NAME)"
    echo "  -s, --scope         Patroni scope (default: $SCOPE)"
    echo "  -p, --postgres-ver  PostgreSQL version (default: $POSTGRES_VERSION)"
    echo "  -u, --superuser     PostgreSQL superuser password (auto-generated if not provided)"
    echo "  -r, --replicator    PostgreSQL replication user password (auto-generated if not provided)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -n lx-pgnode-01 -i 10.0.0.4 -e 10.0.0.4:2379,10.0.0.5:2379,10.0.0.6:2379 -u mypassword -r replpassword"
    echo ""
}

# Function to generate random password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then       
        log_error "This script must be run as root"
        exit 1
    fi
}

# Function to detect OS
detect_os() {
    log_step "Detecting Operating System"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect operating system"
        exit 1
    fi
    
    log_info "Operating System: $OS $VERSION"
}

# Detect system architecture
detect_architecture() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            SYSTEM_ARCH="amd64"
            log_info "Architecture: AMD64/x86_64"
            ;;
        aarch64|arm64)
            SYSTEM_ARCH="arm64"
            log_info "Architecture: ARM64/aarch64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Show Configs
show_configuration() {
    log_step "CONFIGURATION SUMMARY"
    echo ""
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Scope: $SCOPE"
    echo "  PostgreSQL Version: $POSTGRES_VERSION"
    echo "  System Architecture: $SYSTEM_ARCH"
    echo ""
    echo "  Node Name: $NODE_NAME"
    echo "  Node IP: $NODE_IP"
    echo "  etcd Hosts: $ETCD_HOSTS"
    echo ""
    echo "  PostgreSQL Port: $POSTGRES_PORT"
    echo "  Patroni API Port: $PATRONI_API_PORT"
    echo ""
    read -p "Continue with installation? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Installation cancelled by user"
        exit 0
    fi
}

# Function Install Dependencies
install_dependencies() {
    log_step "Installing System Dependencies"
    
    case $OS in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            # Update package lists and install basic requirements first
            apt-get update -qq
            apt-get install -y apt-transport-https ca-certificates
            
            # Install Python and development tools
            apt-get install -y \
                python3 \
                python3-pip \
                python3-dev \
                python3-venv \
                python3-setuptools \
                python3-wheel \
                build-essential \
                libpq-dev \
                openssl \
                wget \
                curl       
            
            log_success "Dependencies installed successfully"
            ;;
        *)
            log_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
}

# Function to Install PostgreSQL
install_postgresql() {
    log_step "Installing PostgreSQL $POSTGRES_VERSION"
    
    case $OS in
        ubuntu|debian)           
            apt-get update -qq
            apt-get install -y postgresql-$POSTGRES_VERSION postgresql-client-$POSTGRES_VERSION
            
            # Stop default PostgreSQL Service
            log_info "Stopping PostgreSQL Service"
            systemctl stop postgresql@$POSTGRES_VERSION-main.service 2>/dev/null || true
            systemctl disable postgresql@$POSTGRES_VERSION-main.service 2>/dev/null || true
            
            log_success "PostgreSQL $POSTGRES_VERSION Installed and Services Stopped"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

# Function to create directories
setup_users_directories() {
    log_step "Setting up Users and Directories"
    
    # Create directories
    log_info "Creating directory structure..."
    mkdir -p "$PATRONI_CONFIG_DIR" "$PATRONI_LOG_DIR" 
    
    # Set permissions
    chown "$PATRONI_USER:$PATRONI_USER" "$PATRONI_LOG_DIR"
    chown "$PATRONI_USER:$PATRONI_USER" "$PATRONI_CONFIG_DIR"   
    
    log_info "Directories created:"
    log_info "  - $PATRONI_CONFIG_DIR"
    log_info "  - $PATRONI_LOG_DIR"    
    
    # Allow user to run systemctl commands for PostgreSQL
    log_info "Configuring sudo permissions for postgres user..."
    cat > /etc/sudoers.d/postgres << 'EOF'
    postgres ALL=(ALL) NOPASSWD: /bin/systemctl start postgresql*, /bin/systemctl stop postgresql*, /bin/systemctl restart postgresql*, /bin/systemctl reload postgresql*, /bin/systemctl status postgresql*
EOF
    
    chmod 440 /etc/sudoers.d/postgres
    log_success "Users and directories configured"
}

# Function Install Patroni
install_patroni() {
    log_step "Installing Patroni $PATRONI_VERSION"
    
    log_info "Installing Patroni and dependencies from APT..."
    apt install -y patroni check-patroni
    
    # Verify installation
    if command -v patroni >/dev/null 2>&1; then
        local installed_version=$(patroni --version 2>/dev/null || echo "unknown")
        log_success "Patroni Installed: $installed_version"
    else
        log_error "Patroni Installation Failed"
        exit 1
    fi
}

# Function to generate Patroni configuration
generate_patroni_config() {
    local node_name="$1"
    local node_ip="$2"
    local etcd_hosts="$3"
    local superuser_password="$4"
    local replicator_password="$5"
    
    log_step "Generating Patroni Configuration"
    
    log_info "Node: $node_name ($node_ip)"
    
    # Convert etcd_hosts format
    local etcd_url_list=""
    IFS=',' read -ra HOSTS <<< "$etcd_hosts"
    for host in "${HOSTS[@]}"; do
        if [[ -n "$etcd_url_list" ]]; then
            etcd_url_list="${etcd_url_list}, "
        fi
        etcd_url_list="${etcd_url_list}${host}"
    done
    
    log_info "etcd endpoints: $etcd_url_list"
    
    cat > "$PATRONI_CONFIG_DIR/tmp_patroni.output" << EOF
scope: $SCOPE
namespace: /pgservice/
name: $node_name

restapi:
  listen: $node_ip: $PATRONI_API_PORT
  connect_address: $node_ip:$PATRONI_API_PORT

etcd3:
  hosts: $etcd_url_list
EOF
    
    # Set permissions
    chown "$PATRONI_USER:$PATRONI_USER" "$PATRONI_CONFIG_DIR/tmp_patroni.output"
    chmod 600 "$PATRONI_CONFIG_DIR/tmp_patroni.output"
    
    log_success "Configuration file created: $PATRONI_CONFIG_DIR/tmp_patroni.output"
}

# Function to start Patroni
start_patroni() {
    log_step "Starting Patroni Service"
    
    log_info "Enabling Patroni service..."
    systemctl enable patroni.service
    
    log_info "Starting Patroni service..."
    systemctl start patroni.service
    
    # Wait for service to start
    log_info "Waiting for service to initialize..."
    sleep 10
    
    # Check status
    if systemctl is-active --quiet patroni; then
        log_success "Patroni service started successfully"
    else
        log_error "Failed to start Patroni service"
        echo ""
        log_info "Service status:"
        systemctl status patroni
        echo ""
        log_info "Recent logs:"
        journalctl -u patroni -n 50 --no-pager
        exit 1
    fi
}

# Function to verify cluster
verify_cluster() {
    local node_ip="$1"
    
    log_step "Verifying Patroni Cluster"
    
    # Wait for cluster to initialize
    log_info "Waiting for cluster Initialization ..."
    sleep 15
    
    # Check cluster status
    log_info "Checking cluster status..."
    echo ""
    patronictl -c "$PATRONI_CONFIG_DIR/patroni.yml" list || true
    echo ""
    
    # Check if PostgreSQL is accessible
    log_info "Testing PostgreSQL Connection"
    export PGPASSWORD="$SUPERUSER_PASSWORD"
    if psql -h "$node_ip" -p "$POSTGRES_PORT" -U postgres -d postgres -c "SELECT version();" >/dev/null 2>&1; then
        log_success "PostgreSQL connection test successful"
    else
        log_warn "PostgreSQL connection test failed - this may be normal during initial cluster setup"
        log_warn "Wait a few moments and try: psql -h $node_ip -p $POSTGRES_PORT -U postgres"
    fi
}

# Show Messages
show_completion_info() {
    log_step "INSTALLATION COMPLETED SUCCESSFULLY"
    
    echo ""
    echo "================================================"
    echo "  Node: $NODE_NAME"
    echo "  IP: $NODE_IP"
    echo ""
    echo "================================================"
    echo ""
    
    log_info "Cluster Information:"
    echo "================================================"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Scope: $SCOPE"
    echo "  PostgreSQL Version: $POSTGRES_VERSION"
    echo "================================================"
    echo "" 

    log_warn "IMPORTANT - Save these credentials securely:"
    echo "================================================"
    echo "│ PostgreSQL Superuser:"
    echo "│   Username: $postgres"
    echo "│   Password: $SUPERUSER_PASSWORD"
    echo "│"
    echo "│ Replication User:"
    echo "│   Username: $replicator"
    echo "│   Password: $REPLICATOR_PASSWORD"
    echo "================================================"
    echo ""
    
    log_info "Connection Information:"
    "================================================"
    echo "  PostgreSQL Port: $POSTGRES_PORT"
    echo "  Patroni API Port: $PATRONI_API_PORT"
    echo ""
    "================================================"
    echo ""

    echo "================================================"    
    log_info "Check Cluster Status:"
    echo "================================================"
    echo " patronictl -c /etc/patroni/patroni.yml list"
    echo ""
    echo "================================================"    
    
    log_success "Patroni PostgreSQL HA Cluster setup completed"
}

#=======================================
# MAIN EXECUTION 
#=======================================

main() {
    local node_name=""
    local node_ip=""
    local etcd_hosts=""
    local superuser_password=""
    local replicator_password=""
    local cluster_name="$CLUSTER_NAME"
    local scope="$SCOPE"
    local postgres_version="$POSTGRES_VERSION"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--node-name)
                node_name="$2"
                shift 2
                ;;
            -i|--node-ip)
                node_ip="$2"
                shift 2
                ;;
            -e|--etcd-hosts)
                etcd_hosts="$2"
                shift 2
                ;;
            -c|--cluster-name)
                cluster_name="$2"
                shift 2
                ;;
            -s|--scope)
                scope="$2"
                shift 2
                ;;
            -p|--postgres-ver)
                postgres_version="$2"
                POSTGRES_VERSION="$2"
                shift 2
                ;;
            -u|--superuser)
                superuser_password="$2"
                shift 2
                ;;
            -r|--replicator)
                replicator_password="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [[ -z "$node_name" || -z "$node_ip" || -z "$etcd_hosts" ]]; then
        log_error "Missing required parameters"
        echo ""
        usage
        exit 1
    fi
    
    # Generate passwords if not provided
    if [[ -z "$superuser_password" ]]; then
        superuser_password=$(generate_password)
        log_info "Generated superuser password: $superuser_password"
    fi
    
    if [[ -z "$replicator_password" ]]; then
        replicator_password=$(generate_password)
        log_info "Generated replicator password: $replicator_password"
    fi
    
    # Store variables for global access
    NODE_NAME="$node_name"
    NODE_IP="$node_ip"
    ETCD_HOSTS="$etcd_hosts"
    SUPERUSER_PASSWORD="$superuser_password"
    REPLICATOR_PASSWORD="$replicator_password"
    CLUSTER_NAME="$cluster_name"
    SCOPE="$scope"
    
    # Determine if this is the first node
    IS_FIRST_NODE="false"
    if [[ "$node_name" =~ 01$ ]] || [[ "$node_name" =~ -1$ ]]; then
        IS_FIRST_NODE="true"
    fi
    
    log_step "STARTING PATRONI POSTGRESQL HA CLUSTER SETUP"
    
    # Pre-flight checks
    check_root
    detect_os
    detect_architecture
    show_configuration
    
    # Installation steps
    install_dependencies
    install_postgresql
    setup_users_directories
    install_patroni    
    generate_patroni_config "$node_name" "$node_ip" "$etcd_hosts" "$superuser_password" "$replicator_password"       
    
    # Final info
    show_completion_info
    
    log_success "Script execution completed successfully!"
}

# Execute main function
main "$@"