#!/bin/bash

#***********************************************************#
#                                                           #
#  Nome: azure_nlb_patroni_setup.sh                         #
#  Autor: Ozano Neto                                        #
#  Descricao: Setup Azure Load Balancer for Patroni HA      #
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
RESOURCE_GROUP="RG_VM_LINUX"
LOCATION="eastus"

# Load Balancer Configuration
LB_NAME="nlb-postgresql-ha"
LB_FRONTEND_IP="nlb-frontend-postgresql"
LB_BACKEND_POOL="nlb-backend-postgresql"
LB_PROBE_NAME="health-pg-patroni"
LB_RULE_NAME="nlb-rule-postgresql"

# Network Configuration
VNET_NAME="vnet-pgha-cluster"
SUBNET_NAME="default"
LB_PRIVATE_IP="10.1.0.10"
NSG_NAME="nsg-pgha-cluster"

# PostgreSQL Nodes
NODE1_NAME="lx-pgnode-01"
NODE2_NAME="lx-pgnode-02"
NODE3_NAME="lx-pgnode-03"

# Ports
POSTGRES_PORT="55018"
PATRONI_API_PORT="8008"

# Load Balancer Type: "internal" or "public"
LB_TYPE="internal"

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
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -g, --resource-group    Resource group name (default: $RESOURCE_GROUP)"
    echo "  -l, --location          Azure location (default: $LOCATION)"
    echo "  -n, --lb-name           Load balancer name (default: $LB_NAME)"
    echo "  -v, --vnet-name         Virtual network name (default: $VNET_NAME)"
    echo "  -s, --subnet-name       Subnet name (default: $SUBNET_NAME)"
    echo "  -i, --lb-ip             Load balancer private IP (default: $LB_PRIVATE_IP)"
    echo "  -t, --lb-type           Load balancer type: internal|public (default: $LB_TYPE)"
    echo "  -1, --node1-name        Node 1 VM name (default: $NODE1_NAME)"
    echo "  -2, --node2-name        Node 2 VM name (default: $NODE2_NAME)"
    echo "  -3, --node3-name        Node 3 VM name (default: $NODE3_NAME)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Example:"
    echo "  ${GREEN}$0 -g rg-postgresql-ha -l eastus -t internal${NC}"
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
    echo ""
    echo "  Load Balancer Name: ${CYAN}$LB_NAME${NC}"
    echo "  Frontend IP Name: ${CYAN}$LB_FRONTEND_IP${NC}"
    echo "  Backend Pool: ${CYAN}$LB_BACKEND_POOL${NC}"
    echo "  Private IP: ${CYAN}$LB_PRIVATE_IP${NC}"
    echo ""
    echo "  Virtual Network: ${CYAN}$VNET_NAME${NC}"
    echo "  Subnet: ${CYAN}$SUBNET_NAME${NC}"
    echo ""
    echo "  PostgreSQL Nodes:"
    echo "    - $NODE1_NAME"
    echo "    - $NODE2_NAME"
    echo "    - $NODE3_NAME"
    echo ""
    echo "  Health Probe: Port $PATRONI_API_PORT (Patroni REST API)"
    echo "  PostgreSQL Port: $POSTGRES_PORT"
    echo ""
    read -p "Continue with setup? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Setup cancelled by user"
        exit 0
    fi
}

# Create Load Balancer
create_load_balancer() {
    log_step "Creating Load Balancer"
    
    if az network lb show --resource-group $RESOURCE_GROUP --name $LB_NAME &> /dev/null; then
        log_warn "Load balancer '$LB_NAME' already exists"
        read -p "Delete and recreate? (yes/no): " recreate
        if [[ "$recreate" == "yes" ]]; then
            log_info "Deleting existing load balancer..."
            az network lb delete --resource-group $RESOURCE_GROUP --name $LB_NAME
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
          --name $LB_NAME \
          --sku Standard \
          --vnet-name $VNET_NAME \
          --subnet $SUBNET_NAME \
          --frontend-ip-name $LB_FRONTEND_IP \
          --backend-pool-name $LB_BACKEND_POOL \
          --private-ip-address $LB_PRIVATE_IP
        
        log_success "Internal load balancer created: $LB_NAME ($LB_PRIVATE_IP)"
        
    elif [[ "$LB_TYPE" == "public" ]]; then
        log_info "Creating public IP address..."
        
        az network public-ip create \
          --resource-group $RESOURCE_GROUP \
          --name pip-$LB_NAME \
          --sku Standard \
          --allocation-method Static \
          --location $LOCATION
        
        log_info "Creating public load balancer..."
        
        az network lb create \
          --resource-group $RESOURCE_GROUP \
          --name $LB_NAME \
          --sku Standard \
          --public-ip-address pip-$LB_NAME \
          --frontend-ip-name $LB_FRONTEND_IP \
          --backend-pool-name $LB_BACKEND_POOL
        
        local public_ip=$(az network public-ip show \
          --resource-group $RESOURCE_GROUP \
          --name pip-$LB_NAME \
          --query ipAddress -o tsv)
        
        log_success "Public load balancer created: $LB_NAME ($public_ip)"
    fi
}

# Create Health Probe
create_health_probe() {
    log_step "Creating Health Probe"
    
    log_info "Creating HTTP health probe on port $PATRONI_API_PORT..."
    log_info "Endpoint: /primary (only returns 200 for PRIMARY node)"
    
    az network lb probe create \
      --resource-group $RESOURCE_GROUP \
      --lb-name $LB_NAME \
      --name $LB_PROBE_NAME \
      --protocol http \
      --port $PATRONI_API_PORT \
      --path "/primary" \
      --interval 5 \
      --threshold 2
    
    log_success "Health probe created: $LB_PROBE_NAME"
    log_info "  Protocol: HTTP"
    log_info "  Port: $PATRONI_API_PORT"
    log_info "  Path: /primary"
    log_info "  Interval: 5 seconds"
    log_info "  Threshold: 2 failures"
}

# Create Load Balancing Rule
create_load_balancing_rule() {
    log_step "Creating Load Balancing Rule"
    
    log_info "Creating rule for PostgreSQL port $POSTGRES_PORT..."
    
    az network lb rule create \
      --resource-group $RESOURCE_GROUP \
      --lb-name $LB_NAME \
      --name $LB_RULE_NAME \
      --protocol tcp \
      --frontend-port $POSTGRES_PORT \
      --backend-port $POSTGRES_PORT \
      --frontend-ip-name $LB_FRONTEND_IP \
      --backend-pool-name $LB_BACKEND_POOL \
      --probe-name $LB_PROBE_NAME \
      --disable-outbound-snat true \
      --idle-timeout 30 \
      --enable-tcp-reset true \
      --load-distribution Default
    
    log_success "Load balancing rule created: $LB_RULE_NAME"
    log_info "  Frontend port: $POSTGRES_PORT"
    log_info "  Backend port: $POSTGRES_PORT"
    log_info "  Distribution: Default (5-tuple hash)"
    log_info "  Idle timeout: 30 seconds"
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
    log_step "Adding Nodes to Backend Pool"
    
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
          --lb-name $LB_NAME \
          --address-pool $LB_BACKEND_POOL 2>/dev/null; then
            log_success "  ✓ Added $NODE to backend pool"
        else
            log_warn "  ⚠ $NODE already in backend pool or failed to add"
        fi
    done
    
    log_success "All nodes processed"
}

# Verify setup
verify_setup() {
    log_step "Verifying Setup"
    
    log_info "Checking load balancer configuration..."
    
    # Get load balancer IP
    local LB_IP=""
    if [[ "$LB_TYPE" == "internal" ]]; then
        LB_IP=$(az network lb frontend-ip show \
          --resource-group $RESOURCE_GROUP \
          --lb-name $LB_NAME \
          --name $LB_FRONTEND_IP \
          --query privateIpAddress -o tsv)
    else
        LB_IP=$(az network public-ip show \
          --resource-group $RESOURCE_GROUP \
          --name pip-$LB_NAME \
          --query ipAddress -o tsv)
    fi
    
    log_info "Load Balancer IP: $LB_IP"
    
    # Check backend pool members
    log_info "Checking backend pool members..."
    local backend_count=$(az network lb address-pool show \
      --resource-group $RESOURCE_GROUP \
      --lb-name $LB_NAME \
      --name $LB_BACKEND_POOL \
      --query 'backendIpConfigurations | length(@)' -o tsv)
    
    log_info "Backend pool members: $backend_count"
    
    if [[ "$backend_count" -eq 3 ]]; then
        log_success "All 3 nodes in backend pool"
    else
        log_warn "Expected 3 nodes, found $backend_count"
    fi
    
    # Check health probe
    log_info "Checking health probe configuration..."
    az network lb probe show \
      --resource-group $RESOURCE_GROUP \
      --lb-name $LB_NAME \
      --name $LB_PROBE_NAME \
      --query '{Port:port,Protocol:protocol,Path:requestPath}' -o table
    
    log_success "Configuration verified"
}

# Show completion info
show_completion_info() {
    log_step "SETUP COMPLETED SUCCESSFULLY"
    
    # Get load balancer IP
    local LB_IP=""
    if [[ "$LB_TYPE" == "internal" ]]; then
        LB_IP=$(az network lb frontend-ip show \
          --resource-group $RESOURCE_GROUP \
          --lb-name $LB_NAME \
          --name $LB_FRONTEND_IP \
          --query privateIpAddress -o tsv)
    else
        LB_IP=$(az network public-ip show \
          --resource-group $RESOURCE_GROUP \
          --name pip-$LB_NAME \
          --query ipAddress -o tsv)
    fi
    
    echo ""
    echo "================================================"
    echo "  Load Balancer: $LB_NAME"
    echo "  Type: $LB_TYPE"
    echo "  IP Address: $LB_IP"
    echo "  Status: $ACTIVE"
    echo "================================================"
    echo ""
    
    log_info "Connection Information:"
    echo "  PostgreSQL Port: $POSTGRES_PORT"
    echo "  Health Probe Port: $PATRONI_API_PORT"
    echo "  Health Check Endpoint: /primary"
    echo ""
    
    log_info "Test PostgreSQL Connection:"
    echo "================================================"
    echo ""
    echo "  psql -h $LB_IP -p $POSTGRES_PORT -U postgres -d postgres"
    echo ""
    echo "================================================"
    
    log_info "Test Health Probe (from each node):"
    echo "================================================"
    echo "  curl http://localhost:$PATRONI_API_PORT/primary"
    echo "  Returns HTTP 200 only if node is PRIMARY"
    echo ""
    echo "================================================"
    
    log_info "Monitor Load Balancer:"
    echo "================================================"
    echo "  az network lb show -g $RESOURCE_GROUP -n $LB_NAME -o table"
    echo "  az network lb probe show -g $RESOURCE_GROUP --lb-name $LB_NAME -n $LB_PROBE_NAME -o table"
    echo ""
    echo "================================================"
    
    log_warn "Next Steps:"
    echo "  1. Verify Patroni is running on all nodes: systemctl status patroni.service"
    echo "  2. Test health endpoints on each node"
    echo "  3. Connect to PostgreSQL through load balancer"
    echo "  4. Test failover by performing switchover"
    echo ""
    echo "================================================"
    
    log_success "Azure Load Balancer Completed"
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
            -n|--lb-name)
                LB_NAME="$2"
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
            -i|--lb-ip)
                LB_PRIVATE_IP="$2"
                shift 2
                ;;
            -t|--lb-type)
                LB_TYPE="$2"
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
    
    log_step "AZURE LOAD BALANCER SETUP FOR PATRONI HA"
    
    # Pre-flight checks
    check_azure_cli
    check_azure_login
    verify_resource_group
    verify_virtual_network
    verify_subnet
    verify_vms
    show_configuration
    
    # Setup steps
    create_load_balancer
    create_health_probe
    create_load_balancing_rule
    configure_nsg
    add_backend_pool_members
    verify_setup
    
    # Final info
    show_completion_info
    
    log_success "Script execution completed successfully!"
}

# Run main function with all arguments
main "$@"