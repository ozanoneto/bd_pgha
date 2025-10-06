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
CLUSTER_NAME="pgha-etcd-cluster"
SCOPE="pgha-etcd-cluster"

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
            apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
            
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
                wget
            
            # Install PostgreSQL client separately
            apt-get install -y postgresql-client-$POSTGRES_VERSION
            
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
            apt-get install -y postgresql-$POSTGRES_VERSION
            
            # Stop default PostgreSQL service
            log_info "Stopping default PostgreSQL Service"
            systemctl stop postgresql 2>/dev/null || true
            systemctl disable postgresql 2>/dev/null || true
            
            log_success "PostgreSQL $POSTGRES_VERSION installed"
            ;;
        *)
            log_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
}

# Function to create users and directories
setup_users_directories() {
    log_step "Setting up Users and Directories"
    
    # Create directories
    log_info "Creating directory structure..."
    mkdir -p "$PATRONI_CONFIG_DIR" "$PATRONI_LOG_DIR" /var/lib/patroni
    
    # Set permissions
    chown "$PATRONI_USER:$PATRONI_USER" "$PATRONI_LOG_DIR" /var/lib/patroni
    chown root:root "$PATRONI_CONFIG_DIR"   
    
    log_info "Directories created:"
    log_info "  - $PATRONI_CONFIG_DIR"
    log_info "  - $PATRONI_LOG_DIR"
    log_info "  - /var/lib/patroni"
    
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
    apt install -y python3 python3-dev python3-psycopg2 psutils patroni check-patroni
    
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
    
    cat > "$PATRONI_CONFIG_DIR/patroni.yml" << EOF
scope: $SCOPE
namespace: /pgservice/
name: $node_name

log:
  level: WARNING
  traceback_level: ERROR
  format: '%(asctime)s %(levelname)s: %(message)s'
  dateformat: ''
  max_queue_size: 1000
  dir: /var/log/patroni
  file_num: 4
  file_size: 25000000
  loggers:
    patroni.postmaster: WARNING
    urllib3: WARNING

restapi:
  listen: $node_ip: $PATRONI_API_PORT
  connect_address: $node_ip:$PATRONI_API_PORT
  authentication:
      username: patroni
      password: 8UITnqgAUiabInQqVobiRr7acy7
  request_queue_size: 5

etcd3:
  hosts: $etcd_url_list

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    master_start_timeout: 300
    synchronous_mode: false
    synchronous_mode_strict: false 
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 250
        superuser_reserved_connections: 5
        password_encryption: scram-sha-256
        max_locks_per_transaction: 64
        max_prepared_transactions: 0        
        shared_buffers: 1GB
        work_mem: 16MB
        maintenance_work_mem: 512MB
        effective_cache_size: 3GB
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.8
        min_wal_size: 2GB
        max_wal_size: 8GB
        wal_buffers: 32MB
        default_statistics_target: 1000
        seq_page_cost: 1
        random_page_cost: 4
        effective_io_concurrency: 2
        synchronous_commit: on
        autovacuum: on
        autovacuum_max_workers: 5
        autovacuum_vacuum_scale_factor: 0.01
        autovacuum_analyze_scale_factor: 0.01
        autovacuum_vacuum_cost_limit: 500
        autovacuum_vacuum_cost_delay: 2
        autovacuum_naptime: 1s
        max_files_per_process: 4096
        archive_mode: on
        archive_timeout: 1800s        
        wal_level: replica
        wal_keep_size: 2GB
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: on
        wal_log_hints: on        
        shared_preload_libraries: pg_stat_statements
        pg_stat_statements.max: 10000
        pg_stat_statements.track: all
        pg_stat_statements.track_utility: false
        pg_stat_statements.save: true        
        track_io_timing: on
        log_lock_waits: on
        log_temp_files: 0
        track_activities: on
        track_counts: on
        track_functions: all
        log_checkpoints: on
        logging_collector: on
        log_truncate_on_rotation: on
        log_rotation_age: 1d
        log_rotation_size: 0
        log_line_prefix: '%t [%p-%l] %r %q%u@%d '
        log_filename: postgresql-%Y-%m-%d_%H%M%S.log
        log_directory: $POSTGRES_DATA_DIR/$POSTGRES_VERSION/main/log
        hot_standby_feedback: off
        max_standby_streaming_delay: 30s
        wal_receiver_status_interval: 10s
        idle_in_transaction_session_timeout: 10min
        jit: off
        max_worker_processes: 4
        max_parallel_workers: 4
        max_parallel_workers_per_gather: 2
        max_parallel_maintenance_workers: 2

  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums      

  pg_hba:
  - host replication replicator 127.0.0.1/32 scram-sha-256
  - host replication replicator $node_ip/0 scram-sha-256
  - host all all 0.0.0.0/0 scram-sha-256  

postgresql:
  listen: $node_ip:$POSTGRES_PORT
  connect_address: $node_ip:$POSTGRES_PORT
  use_unix_socket: true
  data_dir: $POSTGRES_DATA_DIR/$POSTGRES_VERSION/main
  config_dir: /etc/postgresql/$POSTGRES_VERSION/main
  bin_dir: /usr/lib/postgresql/$POSTGRES_VERSION/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: $replicator_password
    superuser:
      username: postgres
      password: $superuser_password
    rewind:
      username: rewind_user
      password: $(generate_password)

  parameters:
    unix_socket_directories: '/var/run/postgresql'

  remove_data_directory_on_rewind_failure: false
  remove_data_directory_on_diverged_timelines: false

  create_replica_methods:
   - basebackup
  
  basebackup:
   max-rate: '250M'
   checkpoint: 'fast'

watchdog:
  mode: required
  device: /dev/watchdog
  safety_margin: 5
  
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
    
    # Set permissions
    chown "$PATRONI_USER:$PATRONI_USER" "$PATRONI_CONFIG_DIR/patroni.yml"
    chmod 600 "$PATRONI_CONFIG_DIR/patroni.yml"
    
    log_success "Configuration file created: $PATRONI_CONFIG_DIR/patroni.yml"
}

# Function to setup PostgreSQL directories
setup_postgresql_directories() {
    local node_ip="$1"
    
    log_step "Setting up PostgreSQL Directories"
    
    # Create PostgreSQL data directory structure
    log_info "Creating PostgreSQL data directory..."
    mkdir -p "$POSTGRES_DATA_DIR/$POSTGRES_VERSION"
    chown -R postgres:postgres "$POSTGRES_DATA_DIR"
    
    # Create socket directory
    log_info "Creating socket directory..."
    mkdir -p /var/run/postgresql
    chown postgres:postgres /var/run/postgresql
    
    # Create log directory
    log_info "Creating log directory..."
    mkdir -p $POSTGRES_DATA_DIR/$POSTGRES_VERSION/main/log
    chown -R postgres:postgres $POSTGRES_DATA_DIR/$POSTGRES_VERSION/main/log
    
    log_success "PostgreSQL directories configured"
}

# Function to configure firewall (if applicable)
configure_firewall() {
    local node_ip="$1"
    
    log_step "Configuring Firewall Rules"
    
    # Check if firewall is active
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW firewall..."
        ufw allow $POSTGRES_PORT/tcp
        ufw allow $PATRONI_API_PORT/tcp
        log_success "UFW firewall rules added"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port=$POSTGRES_PORT/tcp
        firewall-cmd --permanent --add-port=$PATRONI_API_PORT/tcp
        firewall-cmd --reload
        log_success "Firewalld rules added"
    else
        log_warn "No active firewall detected - skipping firewall configuration"
    fi
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

# Function to create helper scripts
create_helper_scripts() {
    log_step "Creating Helper Scripts"
    
    log_info "Creating management scripts..."
    
    # Create patroni management script
    cat > /usr/local/bin/patroni-status << 'EOF'
#!/bin/bash
patronictl -c /etc/patroni/patroni.yml list
EOF
    
    cat > /usr/local/bin/patroni-switchover << 'EOF'
#!/bin/bash
patronictl -c /etc/patroni/patroni.yml switchover
EOF
    
    cat > /usr/local/bin/patroni-failover << 'EOF'
#!/bin/bash
patronictl -c /etc/patroni/patroni.yml failover
EOF
    
    cat > /usr/local/bin/patroni-reinit << 'EOF'
#!/bin/bash
patronictl -c /etc/patroni/patroni.yml reinit
EOF
    
    chmod +x /usr/local/bin/patroni-*
    
    log_success "Helper scripts created:"
    log_info "  - patroni-status      : Show cluster status"
    log_info "  - patroni-switchover  : Perform controlled switchover"
    log_info "  - patroni-failover    : Perform failover"
    log_info "  - patroni-reinit      : Reinitialize a replica"
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
    setup_postgresql_directories "$node_ip"
    generate_patroni_config "$node_name" "$node_ip" "$etcd_hosts" "$superuser_password" "$replicator_password"   
    configure_firewall "$node_ip"
    create_helper_scripts   
    
    # Final info
    show_completion_info
    
    log_success "Script execution completed successfully!"
}

# Execute main function
main "$@"