#!/bin/bash

#***********************************************************#
#                                                           #
#  Nome: azure_lb_patroni_setup.sh                          #
#  Autor: Ozano Neto                                        #
#  Descricao: Setup Azure Load Balancer for Patroni HA     #
#              with separate Write (PRIMARY) and Read       #
#              (REPLICAS) load balancers                    #
#  Requires: Azure CLI installed and authenticated          #
#                                                           #
#  BDADOS TECNOLOGIA LTDA                                   #
#  http://www.bdados.com.br                                 #
#                                                           #
#***********************************************************#

set -e

#============================================================
# STEP 1: CONFIGURATIONS
#============================================================

# Azure Resource Configuration
RESOURCE_GROUP="rg-postgresql-ha"
LOCATION="eastus"

# Load Balancer Configuration - WRITE (Primary)
LB_NAME_WRITE="lb-postgresql-write"
LB_FRONTEND_IP_WRITE="lb-frontend-postgresql-write"
LB_BACKEND_POOL="lb-backend-postgresql"
LB_PROBE_NAME_PRIMARY="health-probe-patroni-primary"
LB_RULE_NAME_WRITE="lb-rule-postgresql-write"

# Load Balancer Configuration - READ (Replicas)
LB_NAME_READ="lb-postgresql-read"
LB_FRONTEND_IP_READ="lb-frontend-postgresql-read"
LB_PROBE_NAME_REPLICA="health-probe-patroni-replica"
LB_RULE_NAME_READ="lb-rule-postgresql-read"

# Network Configuration
VNET_NAME="vnet-postgresql-ha"
SUBNET_NAME="subnet-postgresql-backend"
LB_PRIVATE_IP_WRITE="10.0.0.10"
LB_PRIVATE_IP_READ="10.0.0.11"
NSG_NAME="nsg-postgresql-nodes"

# PostgreSQL Nodes
NODE1_NAME="lx-pgnode-01"
NODE2_NAME="lx-pgnode-02"
NODE3_NAME="lx-pgnode-03"

# Ports
POSTGRES_PORT="5432"
PATRONI_API_PORT="8008"

# Load Balancer Type: "internal" or "public"
LB_TYPE="internal"

# Setup Mode: "write-only", "read-only", or "both"
SETUP_MODE="both"

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
    log_step "AZURE LOAD BALANCER SETUP FOR PATRONI HA"
    echo ""
    echo "This script creates TWO load balancers:"
    echo "  1. WRITE Load Balancer - Routes traffic to PRIMARY node only"
    echo "  2. READ Load Balancer  - Routes traffic to REPLICA nodes only"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -g, --resource-group    Resource group name (default: $RESOURCE_GROUP)"
    echo "  -l, --location          Azure location (default: $LOCATION)"
    echo "  -v, --vnet-name         Virtual network name (default: $VNET_NAME)"
    echo "  -s, --subnet-name       Subnet name (default: $SUBNET_NAME)"
    echo "  -w, --write-ip          Write LB private IP (default: $LB_PRIVATE_IP_WRITE)"
    echo "  -r, --read-ip           Read LB private IP (default: $LB_PRIVATE_IP_READ)"
    echo "  -t, --lb-type           Load balancer type: internal|public (default: $LB_TYPE)"
    echo "  -m, --mode              Setup mode: write-only|read-only|both (default: $SETUP_MODE)"
    echo "  -1, --node1-name        Node 1 VM name (default: $NODE1_NAME)"
    echo "  -2, --node2-name        Node 2 VM name (default: $NODE2_NAME)"
    echo "  -3, --node3-name        Node 3 VM name (default: $NODE3_NAME)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Setup Modes:"
    echo "  ${CYAN}write-only${NC} - Only create write load balancer (PRIMARY)"
    echo "  ${CYAN}read-only${NC}  - Only create read load balancer (REPLICAS)"
    echo "  ${CYAN}both${NC}       - Create both write and read load balancers (recommended)"
    echo ""
    echo "Example:"
    echo "  ${GREEN}$0 -g rg-postgresql-ha -l eastus -t internal -m both${NC}"
    echo ""
}

# Check if Azure CLI is installed
check_azure_cli() {
    log_step "Checking Prerequisites"
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed"
        log_error "Install from: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi
    
    log_info "Azure CLI installed: $(az version --query '\"azure-cli\"' -o tsv)"
}

# Check if logged in to Azure
check_azure_login() {
    log_info "Checking Azure authentication..."
    
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure"
        log_error "Please run: az login"
        exit 1
    fi
    
    local subscription=$(az account show --query name -o tsv)
    local account=$(az account show --query user.name -o tsv)
    
    log_info "Logged in as: $account"
    log_info "Subscription: $subscription"
}

# Verify resource group exists
verify_resource_group() {
    log_info "Verifying resource group: $RESOURCE_GROUP"
    
    if ! az group show --name $RESOURCE_GROUP &> /dev/null; then
        log_error "Resource group '$RESOURCE_GROUP' does not exist"
        log_error "Create it with: az group create -n $RESOURCE_GROUP -l $LOCATION"
        exit 1
    fi
    
    log_success "Resource group exists"
}

# Verify virtual network exists
verify_virtual_network() {
    log_info "Verifying virtual network: $VNET_NAME"
    
    if ! az network vnet show --resource-group $RESOURCE_GROUP --name $VNET_NAME &> /dev/null; then
        log_error "Virtual network '$VNET_NAME' does not exist"
        exit 1
    fi
    
    log_success "Virtual network exists"
}

# Verify subnet exists
verify_subnet() {
    log_info "Verifying subnet: $SUBNET_NAME"
    
    if ! az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --name $SUBNET_NAME &> /dev/null; then
        log_error "Subnet '$SUBNET_NAME' does not exist in VNet '$VNET_NAME'"
        exit 1
    fi
    
    log_success "Subnet exists"
}

# Verify VMs exist
verify_vms() {
    log_info "Verifying PostgreSQL VMs..."
    
    local all_exist=true
    
    for NODE in $NODE1_NAME $NODE2_NAME $NODE3_NAME; do
        if az vm show --resource-group $RESOURCE_GROUP --name $NODE &> /dev/null; then
            log_info "  ✓ VM found: $NODE"
        else
            log_error "  ✗ VM not found: $NODE"
            all_exist=false
        fi
    done
    
    if [ "$all_exist" = false ]; then
        log_error "Some VMs are missing. Please create them first."
        exit 1
    fi
    
    log_success "All VMs exist"
}

# Show configuration summary
show_configuration() {
    log_step "CONFIGURATION SUMMARY"
    echo ""
    echo "  Resource Group: ${YELLOW}$RESOURCE_GROUP${NC}"
    echo "  Location: ${YELLOW}$LOCATION${NC}"
    echo "  Load Balancer Type: ${YELLOW}$LB_TYPE${NC}"
    echo "  Setup Mode: ${YELLOW}$SETUP_MODE${NC}"
    echo ""
    
    if [[ "$SETUP_MODE" == "write-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        echo "  ${CYAN}WRITE Load Balancer (PRIMARY only):${NC}"
        echo "    Name: $LB_NAME_WRITE"
        echo "    IP: $LB_PRIVATE_IP_WRITE"
        echo "    Health Check: /primary (port $PATRONI_API_PORT)"
        echo ""
    fi
    
    if [[ "$SETUP_MODE" == "read-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        echo "  ${CYAN}READ Load Balancer (REPLICAs only):${NC}"
        echo "    Name: $LB_NAME_READ"
        echo "    IP: $LB_PRIVATE_IP_READ"
        echo "    Health Check: /replica (port $PATRONI_API_PORT)"
        echo ""
    fi
    
    echo "  Virtual Network: ${CYAN}$VNET_NAME${NC}"
    echo "  Subnet: ${CYAN}$SUBNET_NAME${NC}"
    echo ""
    echo "  PostgreSQL Nodes:"
    echo "    - $NODE1_NAME"
    echo "    - $NODE2_NAME"
    echo "    - $NODE3_NAME"
    echo ""
    echo "  PostgreSQL Port: $POSTGRES_PORT"
    echo "  Patroni API Port: $PATRONI_API_PORT"
    echo ""
    read -p "Continue with setup? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Setup cancelled by user"
        exit 0
    fi
}

# Create Load Balancer
create_load_balancer() {
    local lb_name="$1"
    local lb_frontend="$2"
    local lb_ip="$3"
    local lb_purpose="$4"
    
    log_step "Creating $lb_purpose Load Balancer"
    
    if az network lb show --resource-group $RESOURCE_GROUP --name $lb_name &> /dev/null; then
        log_warn "Load balancer '$lb_name' already exists"
        read -p "Delete and recreate? (yes/no): " recreate
        if [[ "$recreate" == "yes" ]]; then
            log_info "Deleting existing load balancer..."
            az network lb delete --resource-group $RESOURCE_GROUP --name $lb_name
            log_info "Deleted existing load balancer"
        else
            log_info "Using existing load balancer"
            return 0
        fi
    fi
    
    if [[ "$LB_TYPE" == "internal" ]]; then
        log_info "Creating internal load balancer..."
        
        az network lb create \
          --resource-group $RESOURCE_GROUP \
          --name $lb_name \
          --sku Standard \
          --vnet-name $VNET_NAME \
          --subnet $SUBNET_NAME \
          --frontend-ip-name $lb_frontend \
          --backend-pool-name $LB_BACKEND_POOL \
          --private-ip-address $lb_ip
        
        log_success "$lb_purpose load balancer created: $lb_name ($lb_ip)"
        
    elif [[ "$LB_TYPE" == "public" ]]; then
        log_info "Creating public IP address..."
        
        az network public-ip create \
          --resource-group $RESOURCE_GROUP \
          --name pip-$lb_name \
          --sku Standard \
          --allocation-method Static \
          --location $LOCATION
        
        log_info "Creating public load balancer..."
        
        az network lb create \
          --resource-group $RESOURCE_GROUP \
          --name $lb_name \
          --sku Standard \
          --public-ip-address pip-$lb_name \
          --frontend-ip-name $lb_frontend \
          --backend-pool-name $LB_BACKEND_POOL
        
        local public_ip=$(az network public-ip show \
          --resource-group $RESOURCE_GROUP \
          --name pip-$lb_name \
          --query ipAddress -o tsv)
        
        log_success "$lb_purpose load balancer created: $lb_name ($public_ip)"
    fi
}

# Create Write Load Balancer
create_write_load_balancer() {
    if [[ "$SETUP_MODE" == "read-only" ]]; then
        log_info "Skipping write load balancer (mode: $SETUP_MODE)"
        return 0
    fi
    
    create_load_balancer "$LB_NAME_WRITE" "$LB_FRONTEND_IP_WRITE" "$LB_PRIVATE_IP_WRITE" "WRITE (PRIMARY)"
}

# Create Read Load Balancer
create_read_load_balancer() {
    if [[ "$SETUP_MODE" == "write-only" ]]; then
        log_info "Skipping read load balancer (mode: $SETUP_MODE)"
        return 0
    fi
    
    create_load_balancer "$LB_NAME_READ" "$LB_FRONTEND_IP_READ" "$LB_PRIVATE_IP_READ" "READ (REPLICAS)"
}

# Create Health Probe
create_health_probe() {
    local lb_name="$1"
    local probe_name="$2"
    local probe_path="$3"
    local probe_purpose="$4"
    
    log_step "Creating Health Probe for $probe_purpose"
    
    log_info "Creating HTTP health probe on port $PATRONI_API_PORT..."
    log_info "Endpoint: $probe_path (only returns 200 for $probe_purpose)"
    
    az network lb probe create \
      --resource-group $RESOURCE_GROUP \
      --lb-name $lb_name \
      --name $probe_name \
      --protocol http \
      --port $PATRONI_API_PORT \
      --path "$probe_path" \
      --interval 5 \
      --threshold 2
    
    log_success "Health probe created: $probe_name"
    log_info "  Protocol: HTTP"
    log_info "  Port: $PATRONI_API_PORT"
    log_info "  Path: $probe_path"
    log_info "  Interval: 5 seconds"
    log_info "  Threshold: 2 failures"
}

# Create Write Health Probe
create_write_health_probe() {
    if [[ "$SETUP_MODE" == "read-only" ]]; then
        return 0
    fi
    
    create_health_probe "$LB_NAME_WRITE" "$LB_PROBE_NAME_PRIMARY" "/primary" "PRIMARY NODE"
}

# Create Read Health Probe
create_read_health_probe() {
    if [[ "$SETUP_MODE" == "write-only" ]]; then
        return 0
    fi
    
    create_health_probe "$LB_NAME_READ" "$LB_PROBE_NAME_REPLICA" "/replica" "REPLICA NODES"
}

# Create Load Balancing Rule
create_load_balancing_rule() {
    local lb_name="$1"
    local rule_name="$2"
    local frontend_ip="$3"
    local probe_name="$4"
    local lb_purpose="$5"
    local distribution="${6:-Default}"
    
    log_step "Creating Load Balancing Rule for $lb_purpose"
    
    log_info "Creating rule for PostgreSQL port $POSTGRES_PORT..."
    
    az network lb rule create \
      --resource-group $RESOURCE_GROUP \
      --lb-name $lb_name \
      --name $rule_name \
      --protocol tcp \
      --frontend-port $POSTGRES_PORT \
      --backend-port $POSTGRES_PORT \
      --frontend-ip-name $frontend_ip \
      --backend-pool-name $LB_BACKEND_POOL \
      --probe-name $probe_name \
      --disable-outbound-snat true \
      --idle-timeout 30 \
      --enable-tcp-reset true \
      --load-distribution $distribution
    
    log_success "Load balancing rule created: $rule_name"
    log_info "  Frontend port: $POSTGRES_PORT"
    log_info "  Backend port: $POSTGRES_PORT"
    log_info "  Distribution: $distribution"
    log_info "  Idle timeout: 30 seconds"
}

# Create Write Load Balancing Rule
create_write_load_balancing_rule() {
    if [[ "$SETUP_MODE" == "read-only" ]]; then
        return 0
    fi
    
    # Use Default distribution for write - ensures connections go to PRIMARY only
    create_load_balancing_rule \
        "$LB_NAME_WRITE" \
        "$LB_RULE_NAME_WRITE" \
        "$LB_FRONTEND_IP_WRITE" \
        "$LB_PROBE_NAME_PRIMARY" \
        "WRITE (PRIMARY)" \
        "Default"
}

# Create Read Load Balancing Rule
create_read_load_balancing_rule() {
    if [[ "$SETUP_MODE" == "write-only" ]]; then
        return 0
    fi
    
    # Use Default distribution for read - distributes across all REPLICAs
    create_load_balancing_rule \
        "$LB_NAME_READ" \
        "$LB_RULE_NAME_READ" \
        "$LB_FRONTEND_IP_READ" \
        "$LB_PROBE_NAME_REPLICA" \
        "READ (REPLICAS)" \
        "Default"
}

# Configure Network Security Group
configure_nsg() {
    log_step "Configuring Network Security Group"
    
    # Check if NSG exists
    if ! az network nsg show --resource-group $RESOURCE_GROUP --name $NSG_NAME &> /dev/null; then
        log_warn "NSG '$NSG_NAME' not found"
        log_warn "Skipping NSG configuration - configure manually if needed"
        return 0
    fi
    
    log_info "Configuring NSG rules for health probe and PostgreSQL..."
    
    # Allow health probe from Azure Load Balancer
    if az network nsg rule show --resource-group $RESOURCE_GROUP --nsg-name $NSG_NAME --name AllowHealthProbe &> /dev/null; then
        log_warn "NSG rule 'AllowHealthProbe' already exists"
    else
        az network nsg rule create \
          --resource-group $RESOURCE_GROUP \
          --nsg-name $NSG_NAME \
          --name AllowHealthProbe \
          --priority 100 \
          --source-address-prefixes AzureLoadBalancer \
          --destination-port-ranges $PATRONI_API_PORT \
          --protocol Tcp \
          --access Allow \
          --direction Inbound
        
        log_success "NSG rule created: AllowHealthProbe (port $PATRONI_API_PORT)"
    fi
    
    # Allow PostgreSQL from within VNet
    if az network nsg rule show --resource-group $RESOURCE_GROUP --nsg-name $NSG_NAME --name AllowPostgreSQL &> /dev/null; then
        log_warn "NSG rule 'AllowPostgreSQL' already exists"
    else
        az network nsg rule create \
          --resource-group $RESOURCE_GROUP \
          --nsg-name $NSG_NAME \
          --name AllowPostgreSQL \
          --priority 110 \
          --source-address-prefixes VirtualNetwork \
          --destination-port-ranges $POSTGRES_PORT \
          --protocol Tcp \
          --access Allow \
          --direction Inbound
        
        log_success "NSG rule created: AllowPostgreSQL (port $POSTGRES_PORT)"
    fi
}

# Add nodes to backend pool
add_backend_pool_members() {
    local lb_name="$1"
    local lb_purpose="$2"
    
    log_step "Adding Nodes to Backend Pool ($lb_purpose)"
    
    for NODE in $NODE1_NAME $NODE2_NAME $NODE3_NAME; do
        log_info "Processing node: $NODE"
        
        # Get NIC ID
        local NIC_ID=$(az vm show \
          --resource-group $RESOURCE_GROUP \
          --name $NODE \
          --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        
        local NIC_NAME=$(basename $NIC_ID)
        log_info "  NIC: $NIC_NAME"
        
        # Add to backend pool
        if az network nic ip-config address-pool add \
          --resource-group $RESOURCE_GROUP \
          --nic-name $NIC_NAME \
          --ip-config-name ipconfig1 \
          --lb-name $lb_name \
          --address-pool $LB_BACKEND_POOL 2>/dev/null; then
            log_success "  ✓ Added $NODE to backend pool"
        else
            log_warn "  ⚠ $NODE already in backend pool or failed to add"
        fi
    done
    
    log_success "All nodes processed for $lb_purpose"
}

# Add nodes to write backend pool
add_write_backend_pool_members() {
    if [[ "$SETUP_MODE" == "read-only" ]]; then
        return 0
    fi
    
    add_backend_pool_members "$LB_NAME_WRITE" "WRITE"
}

# Add nodes to read backend pool
add_read_backend_pool_members() {
    if [[ "$SETUP_MODE" == "write-only" ]]; then
        return 0
    fi
    
    add_backend_pool_members "$LB_NAME_READ" "READ"
}

# Verify setup
verify_setup() {
    log_step "Verifying Setup"
    
    if [[ "$SETUP_MODE" == "write-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        log_info "Checking WRITE load balancer configuration..."
        
        # Get load balancer IP
        local LB_IP_WRITE=""
        if [[ "$LB_TYPE" == "internal" ]]; then
            LB_IP_WRITE=$(az network lb frontend-ip show \
              --resource-group $RESOURCE_GROUP \
              --lb-name $LB_NAME_WRITE \
              --name $LB_FRONTEND_IP_WRITE \
              --query privateIpAddress -o tsv)
        else
            LB_IP_WRITE=$(az network public-ip show \
              --resource-group $RESOURCE_GROUP \
              --name pip-$LB_NAME_WRITE \
              --query ipAddress -o tsv)
        fi
        
        log_info "WRITE Load Balancer IP: $LB_IP_WRITE"
        
        # Check backend pool members
        local backend_count_write=$(az network lb address-pool show \
          --resource-group $RESOURCE_GROUP \
          --lb-name $LB_NAME_WRITE \
          --name $LB_BACKEND_POOL \
          --query 'backendIpConfigurations | length(@)' -o tsv)
        
        log_info "WRITE backend pool members: $backend_count_write"
        
        if [[ "$backend_count_write" -eq 3 ]]; then
            log_success "All 3 nodes in WRITE backend pool"
        else
            log_warn "Expected 3 nodes in WRITE pool, found $backend_count_write"
        fi
    fi
    
    if [[ "$SETUP_MODE" == "read-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        log_info "Checking READ load balancer configuration..."
        
        # Get load balancer IP
        local LB_IP_READ=""
        if [[ "$LB_TYPE" == "internal" ]]; then
            LB_IP_READ=$(az network lb frontend-ip show \
              --resource-group $RESOURCE_GROUP \
              --lb-name $LB_NAME_READ \
              --name $LB_FRONTEND_IP_READ \
              --query privateIpAddress -o tsv)
        else
            LB_IP_READ=$(az network public-ip show \
              --resource-group $RESOURCE_GROUP \
              --name pip-$LB_NAME_READ \
              --query ipAddress -o tsv)
        fi
        
        log_info "READ Load Balancer IP: $LB_IP_READ"
        
        # Check backend pool members
        local backend_count_read=$(az network lb address-pool show \
          --resource-group $RESOURCE_GROUP \
          --lb-name $LB_NAME_READ \
          --name $LB_BACKEND_POOL \
          --query 'backendIpConfigurations | length(@)' -o tsv)
        
        log_info "READ backend pool members: $backend_count_read"
        
        if [[ "$backend_count_read" -eq 3 ]]; then
            log_success "All 3 nodes in READ backend pool"
        else
            log_warn "Expected 3 nodes in READ pool, found $backend_count_read"
        fi
    fi
    
    log_success "Configuration verified"
}

# Show completion info
show_completion_info() {
    log_step "SETUP COMPLETED SUCCESSFULLY"
    
    echo ""
    echo "================================================"
    echo "  ${CYAN}PostgreSQL HA Load Balancers Created${NC}"
    echo "  Setup Mode: ${YELLOW}$SETUP_MODE${NC}"
    echo "  Type: ${YELLOW}$LB_TYPE${NC}"
    echo "================================================"
    echo ""
    
    if [[ "$SETUP_MODE" == "write-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        # Get WRITE load balancer IP
        local LB_IP_WRITE=""
        if [[ "$LB_TYPE" == "internal" ]]; then
            LB_IP_WRITE=$(az network lb frontend-ip show \
              --resource-group $RESOURCE_GROUP \
              --lb-name $LB_NAME_WRITE \
              --name $LB_FRONTEND_IP_WRITE \
              --query privateIpAddress -o tsv)
        else
            LB_IP_WRITE=$(az network public-ip show \
              --resource-group $RESOURCE_GROUP \
              --name pip-$LB_NAME_WRITE \
              --query ipAddress -o tsv)
        fi
        
        echo "┌────────────────────────────────────────────────────────────────"
        echo "│ ${GREEN}WRITE Load Balancer (PRIMARY Only)${NC}"
        echo "├────────────────────────────────────────────────────────────────"
        echo "│ Name: ${CYAN}$LB_NAME_WRITE${NC}"
        echo "│ IP Address: ${CYAN}$LB_IP_WRITE${NC}"
        echo "│ Port: ${CYAN}$POSTGRES_PORT${NC}"
        echo "│ Health Check: ${CYAN}/primary${NC} (port $PATRONI_API_PORT)"
        echo "│ Purpose: ${YELLOW}All write operations (INSERT, UPDATE, DELETE)${NC}"
        echo "└────────────────────────────────────────────────────────────────"
        echo ""
    fi
    
    if [[ "$SETUP_MODE" == "read-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        # Get READ load balancer IP
        local LB_IP_READ=""
        if [[ "$LB_TYPE" == "internal" ]]; then
            LB_IP_READ=$(az network lb frontend-ip show \
              --resource-group $RESOURCE_GROUP \
              --lb-name $LB_NAME_READ \
              --name $LB_FRONTEND_IP_READ \
              --query privateIpAddress -o tsv)
        else
            LB_IP_READ=$(az network public-ip show \
              --resource-group $RESOURCE_GROUP \
              --name pip-$LB_NAME_READ \
              --query ipAddress -o tsv)
        fi
        
        echo "┌────────────────────────────────────────────────────────────────"
        echo "│ ${GREEN}READ Load Balancer (REPLICAs Only)${NC}"
        echo "├────────────────────────────────────────────────────────────────"
        echo "│ Name: ${CYAN}$LB_NAME_READ${NC}"
        echo "│ IP Address: ${CYAN}$LB_IP_READ${NC}"
        echo "│ Port: ${CYAN}$POSTGRES_PORT${NC}"
        echo "│ Health Check: ${CYAN}/replica${NC} (port $PATRONI_API_PORT)"
        echo "│ Purpose: ${YELLOW}All read operations (SELECT) distributed across replicas${NC}"
        echo "└────────────────────────────────────────────────────────────────"
        echo ""
    fi
    
    if [[ "$SETUP_MODE" == "both" ]]; then
        log_info "Connection Examples:"
        echo ""
        echo "  ${GREEN}# Write operations (PRIMARY)${NC}"
        echo "  psql -h $LB_IP_WRITE -p $POSTGRES_PORT -U postgres -d mydb"
        echo "  psql -h $LB_IP_WRITE -p $POSTGRES_PORT -U postgres -c \"INSERT INTO ...\""
        echo ""
        echo "  ${GREEN}# Read operations (REPLICAs - load balanced)${NC}"
        echo "  psql -h $LB_IP_READ -p $POSTGRES_PORT -U postgres -d mydb -c \"SELECT ...\""
        echo ""
    elif [[ "$SETUP_MODE" == "write-only" ]]; then
        echo "  ${GREEN}# Write operations (PRIMARY)${NC}"
        echo "  psql -h $LB_IP_WRITE -p $POSTGRES_PORT -U postgres -d mydb"
        echo ""
    else
        echo "  ${GREEN}# Read operations (REPLICAs)${NC}"
        echo "  psql -h $LB_IP_READ -p $POSTGRES_PORT -U postgres -d mydb"
        echo ""
    fi
    
    log_info "Test Health Probes:"
    echo "  ${GREEN}# Test PRIMARY endpoint (should return 200 only on PRIMARY)${NC}"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.4:$PATRONI_API_PORT/primary"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.5:$PATRONI_API_PORT/primary"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.6:$PATRONI_API_PORT/primary"
    echo ""
    echo "  ${GREEN}# Test REPLICA endpoint (should return 200 only on REPLICAs)${NC}"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.4:$PATRONI_API_PORT/replica"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.5:$PATRONI_API_PORT/replica"
    echo "  curl -s -o /dev/null -w \"%{http_code}\" http://10.0.0.6:$PATRONI_API_PORT/replica"
    echo ""
    
    log_info "Verify Cluster Status:"
    echo "  ${GREEN}patroni-status${NC}"
    echo "  ${GREEN}patronictl -c /etc/patroni/patroni.yml list${NC}"
    echo ""
    
    log_info "Test Load Distribution (READ Load Balancer):"
    echo "  ${GREEN}# Run multiple times to see different replica IPs${NC}"
    echo "  for i in {1..10}; do"
    echo "    psql -h $LB_IP_READ -p $POSTGRES_PORT -U postgres -t -c \"SELECT inet_server_addr();\""
    echo "  done"
    echo ""
    
    log_info "Monitor Load Balancers:"
    if [[ "$SETUP_MODE" == "both" ]] || [[ "$SETUP_MODE" == "write-only" ]]; then
        echo "  ${GREEN}# WRITE Load Balancer${NC}"
        echo "  az network lb show -g $RESOURCE_GROUP -n $LB_NAME_WRITE -o table"
        echo "  az network lb probe show -g $RESOURCE_GROUP --lb-name $LB_NAME_WRITE -n $LB_PROBE_NAME_PRIMARY -o table"
        echo ""
    fi
    if [[ "$SETUP_MODE" == "both" ]] || [[ "$SETUP_MODE" == "read-only" ]]; then
        echo "  ${GREEN}# READ Load Balancer${NC}"
        echo "  az network lb show -g $RESOURCE_GROUP -n $LB_NAME_READ -o table"
        echo "  az network lb probe show -g $RESOURCE_GROUP --lb-name $LB_NAME_READ -n $LB_PROBE_NAME_REPLICA -o table"
        echo ""
    fi
    
    log_warn "Application Configuration:"
    echo ""
    echo "  Configure your application to use DIFFERENT connection strings:"
    echo ""
    echo "  ${YELLOW}# For write operations${NC}"
    echo "  WRITE_DB_HOST=$LB_IP_WRITE"
    echo "  WRITE_DB_PORT=$POSTGRES_PORT"
    echo ""
    echo "  ${YELLOW}# For read operations${NC}"
    echo "  READ_DB_HOST=$LB_IP_READ"
    echo "  READ_DB_PORT=$POSTGRES_PORT"
    echo ""
    echo "  ${CYAN}Example application code:${NC}"
    echo "  # Python with psycopg2"
    echo "  write_conn = psycopg2.connect(host='$LB_IP_WRITE', port=$POSTGRES_PORT, ...)"
    echo "  read_conn = psycopg2.connect(host='$LB_IP_READ', port=$POSTGRES_PORT, ...)"
    echo ""
    
    log_warn "Best Practices:"
    echo "  1. ${CYAN}Use WRITE LB for:${NC} INSERT, UPDATE, DELETE, DDL statements"
    echo "  2. ${CYAN}Use READ LB for:${NC} SELECT queries, reports, analytics"
    echo "  3. ${CYAN}Monitor replication lag:${NC} Ensure replicas are in sync"
    echo "  4. ${CYAN}Test failover:${NC} Verify automatic failover works correctly"
    echo "  5. ${CYAN}Connection pooling:${NC} Use pgBouncer or application-level pooling"
    echo ""
    
    log_success "Azure Load Balancer setup completed successfully!"
}

#=======================================
# MAIN EXECUTION 
#=======================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -g|--resource-group)
                RESOURCE_GROUP="$2"
                shift 2
                ;;
            -l|--location)
                LOCATION="$2"
                shift 2
                ;;
            -v|--vnet-name)
                VNET_NAME="$2"
                shift 2
                ;;
            -s|--subnet-name)
                SUBNET_NAME="$2"
                shift 2
                ;;
            -w|--write-ip)
                LB_PRIVATE_IP_WRITE="$2"
                shift 2
                ;;
            -r|--read-ip)
                LB_PRIVATE_IP_READ="$2"
                shift 2
                ;;
            -t|--lb-type)
                LB_TYPE="$2"
                shift 2
                ;;
            -m|--mode)
                SETUP_MODE="$2"
                shift 2
                ;;
            -1|--node1-name)
                NODE1_NAME="$2"
                shift 2
                ;;
            -2|--node2-name)
                NODE2_NAME="$2"
                shift 2
                ;;
            -3|--node3-name)
                NODE3_NAME="$2"
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
    
    # Validate LB_TYPE
    if [[ "$LB_TYPE" != "internal" && "$LB_TYPE" != "public" ]]; then
        log_error "Invalid load balancer type: $LB_TYPE"
        log_error "Must be 'internal' or 'public'"
        exit 1
    fi
    
    # Validate SETUP_MODE
    if [[ "$SETUP_MODE" != "write-only" && "$SETUP_MODE" != "read-only" && "$SETUP_MODE" != "both" ]]; then
        log_error "Invalid setup mode: $SETUP_MODE"
        log_error "Must be 'write-only', 'read-only', or 'both'"
        exit 1
    fi
    
    log_step "AZURE LOAD BALANCER SETUP FOR PATRONI HA"
    log_info "Setup Mode: $SETUP_MODE"
    
    # Pre-flight checks
    check_azure_cli
    check_azure_login
    verify_resource_group
    verify_virtual_network
    verify_subnet
    verify_vms
    show_configuration
    
    # Setup WRITE Load Balancer (PRIMARY)
    if [[ "$SETUP_MODE" == "write-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        create_write_load_balancer
        create_write_health_probe
        create_write_load_balancing_rule
        add_write_backend_pool_members
    fi
    
    # Setup READ Load Balancer (REPLICAS)
    if [[ "$SETUP_MODE" == "read-only" ]] || [[ "$SETUP_MODE" == "both" ]]; then
        create_read_load_balancer
        create_read_health_probe
        create_read_load_balancing_rule
        add_read_backend_pool_members
    fi
    
    # Configure NSG (common for both)
    configure_nsg
    
    # Verify and show results
    verify_setup
    show_completion_info
    
    log_success "Script execution completed successfully!"
}

# Run main function with all arguments
main "$@"