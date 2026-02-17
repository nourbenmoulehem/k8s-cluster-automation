#!/bin/bash

# Heat + Ansible + Full OpenStack K8s Cluster Orchestration

set -e # exit on error

# Change to demo-user
source "/home/controller/demo-openrc"

# Configuration:
STACK_NAME="k8s-production"
HEAT_TEMPLATE="/home/controller/paas/heat/k8s-full-cluster-template.yml"
INVENTORY_FILE="/home/controller/paas/inventory-openstack.yml"
PLAYBOOK="/home/controller/paas/site.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#if [ -z "$ANTHROPIC_API_KEY" ]; then
 #   print_error "ANTHROPIC_API_KEY not set!"



  #  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  #      exit 1
  #  fi
 #   export SKIP_CLAUDE_OBSERVER=true
#fi


# HELPER FUNCTIONS
print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

wait_for_ssh() {
    local IP=$1
    local USER=$2
    local NAME=$3
    local MAX_RETRIES=60  # Increased for cloud instances
    local RETRY_COUNT=0
    
    print_info "Waiting for $NAME to be SSH-ready..."
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$IP" "echo 'ready'" &>/dev/null; then
            print_success "$NAME ($USER@$IP) is ready!"
            return 0
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo -n "."
        sleep 5
    done
    
    echo ""
    print_error "Timeout waiting for $NAME"
    return 1
}

# MAIN DEPLOYMENT
print_header "Pure OpenStack K8s Cluster Deployment"
echo ""
echo "Cluster Configuration:"
echo "  Master:  compute-test (Legion) - k8s-master (4GB, 40GB)"
echo "  Worker1: compute-nour (Dell)   - ubuntu-small (2GB, 20GB)"
echo "  Worker2: compute-nour (Dell)   - ubuntu-small (2GB, 20GB)"
echo ""
echo "This script will:"
echo "  1. Deploy 3 OpenStack instances via Heat"
echo "  2. Generate Ansible inventory dynamically"
echo "  3. Deploy complete K8s cluster (1 master + 2 workers)"
echo "  4. Deploy monitoring stack"
echo "  5. Deploy Nestie application"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Deployment cancelled"
    exit 1
fi

# --------------------------------------------------
# STEP 1: HEAT STACK DEPLOYMENT
# --------------------------------------------------

print_header "Step 1/6: Managing Heat Stack"

if openstack stack show "$STACK_NAME" &>/dev/null; then
    print_info "Existing stack found"
    
    # No K8s cleanup needed - entire cluster is ephemeral!
    print_info "Deleting old stack (all nodes will be destroyed)..."
    openstack stack delete -y "$STACK_NAME"
    
    while openstack stack show "$STACK_NAME" &>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo ""
    print_success "Old stack deleted"
    sleep 3
fi

# Create new stack
print_info "Creating Heat stack: $STACK_NAME"
openstack stack create -t "$HEAT_TEMPLATE" \
    --parameter key_name=mykey \
    --parameter network=selfservice \
    --parameter external_network=provider \
    "$STACK_NAME" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    print_error "Failed to create Heat stack"
    exit 1
fi

print_success "Stack creation initiated"

# --------------------------------------------------
# STEP 2: WAIT FOR HEAT COMPLETION
# --------------------------------------------------

print_header "Step 2/6: Waiting for Stack Completion"

while true; do
    STATUS=$(openstack stack show "$STACK_NAME" -f value -c stack_status 2>/dev/null || echo "UNKNOWN")
    
    if [ "$STATUS" == "CREATE_COMPLETE" ]; then
        print_success "Stack created successfully!"
        break
    elif [ "$STATUS" == "CREATE_FAILED" ]; then
        print_error "Stack creation failed!"
        echo ""
        print_info "Failed resources:"
        openstack stack resource list "$STACK_NAME" --filter status=FAILED
        echo ""
        print_info "Stack events:"
        openstack stack event list "$STACK_NAME" --nested-depth 2 | head -20
        exit 1
    fi
    echo -n "."
    sleep 5
done

echo ""

# --------------------------------------------------
# STEP 3: EXTRACT IPS FROM SERVERS
# --------------------------------------------------

print_header "Step 3/6: Extracting Instance IPs"

# Wait for instances to fully boot
sleep 5


# Function to get IPs from server (ROBUST VERSION)
get_ip() {
    local server=$1
    local ip_type=$2
    
    # Get addresses string
    local addresses=$(openstack server show "$server" -f value -c addresses 2>/dev/null)
    
    if [ -z "$addresses" ]; then
        echo "DEBUG: No addresses found for $server" >&2
        return 1
    fi
    
    echo "DEBUG: Raw addresses for $server: $addresses" >&2
    
    # Format is: "selfservice=172.16.1.64, 192.168.1.124"
    # Internal IP: 172.16.1.64
    # Floating IP: 192.168.1.124
    
    if [ "$ip_type" == "floating" ]; then
        # Get the IP after the comma
        echo "$addresses" | sed 's/.*,\s*//' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
    else
        # Get the IP after the equals sign, before the comma
        echo "$addresses" | sed 's/.*=//' | sed 's/,.*//' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
    fi
}

# Extract all IPs
print_info "Getting master IPs..."
MASTER_INTERNAL=$(get_ip "k8s-master" "internal")
MASTER_IP=$(get_ip "k8s-master" "floating")

print_info "Getting worker1 IPs..."
WORKER1_INTERNAL=$(get_ip "k8s-worker1" "internal")
WORKER1_IP=$(get_ip "k8s-worker1" "floating")

print_info "Getting worker2 IPs..."
WORKER2_INTERNAL=$(get_ip "k8s-worker2" "internal")
WORKER2_IP=$(get_ip "k8s-worker2" "floating")

# Verify all IPs were extracted
if [ -z "$MASTER_IP" ] || [ -z "$WORKER1_IP" ] || [ -z "$WORKER2_IP" ]; then
    print_error "Failed to extract all floating IPs"
    echo ""
    echo "Server status:"
    openstack server list | grep k8s
    exit 1
fi

print_success "All IPs extracted"
echo ""
echo "Cluster IPs:"
echo "  Master:  $MASTER_IP (internal: $MASTER_INTERNAL)"
echo "  Worker1: $WORKER1_IP (internal: $WORKER1_INTERNAL)"
echo "  Worker2: $WORKER2_IP (internal: $WORKER2_INTERNAL)"
echo ""

# Verify instance placement
print_info "Instance placement:"
for instance in k8s-master k8s-worker1 k8s-worker2; do
    HOST=$(openstack server show $instance -f value -c OS-EXT-SRV-ATTR:hypervisor_hostname 2>/dev/null)
    echo "  $instance: $HOST"
done

# --------------------------------------------------
# STEP 4: GENERATE INVENTORY
# --------------------------------------------------

print_header "Step 4/6: Generating Inventory"

# Generate inventory.yml
cat > "$INVENTORY_FILE" <<EOF
# ============================================
# Pure OpenStack Kubernetes Cluster Inventory
# Auto-generated by deploy-openstack.sh
# Generated: $(date)
# ============================================

all:
  vars:
    ansible_ssh_private_key_file: ~/.ssh/id_rsa
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
    ansible_python_interpreter: /usr/bin/python3
  
  children:
    k8s_cluster:
      children:
        k8s_master:
          hosts:
            master:
              ansible_host: $MASTER_IP
              ansible_user: ubuntu
              internal_ip: $MASTER_INTERNAL
        
        k8s_workers:
          hosts:
            worker1:
              ansible_host: $WORKER1_IP
              ansible_user: ubuntu
              internal_ip: $WORKER1_INTERNAL
            
            worker2:
              ansible_host: $WORKER2_IP
              ansible_user: ubuntu
              internal_ip: $WORKER2_INTERNAL
EOF

print_success "Inventory generated: $INVENTORY_FILE"

# --------------------------------------------------
# STEP 5: WAIT FOR SSH ACCESS
# --------------------------------------------------

print_header "Step 5/6: Waiting for SSH Access"

# Wait for all nodes to be SSH-ready
wait_for_ssh "$MASTER_IP" "ubuntu" "Master" || exit 1
wait_for_ssh "$WORKER1_IP" "ubuntu" "Worker1" || exit 1
wait_for_ssh "$WORKER2_IP" "ubuntu" "Worker2" || exit 1

echo ""
print_success "All nodes are SSH-ready!"

# Test Ansible connectivity
print_info "Testing Ansible connectivity..."
if ansible all -i "$INVENTORY_FILE" -m ping >/dev/null 2>&1; then
    print_success "Ansible connectivity confirmed!"
else
    print_error "Ansible connectivity test failed"
    exit 1
fi

# --------------------------------------------------
# STEP 6: DEPLOY KUBERNETES CLUSTER
# --------------------------------------------------

print_header "Step 6/6: Deploying Kubernetes Cluster"

echo ""
echo "This will run the complete playbook:"
echo "  - Prepare all nodes (common, container-runtime, kubernetes)"
echo "  - Initialize master node"
echo "  - Join worker nodes"
echo "  - Deploy monitoring stack"
echo "  - Deploy Nestie application"
echo ""
echo "Estimated time: 15-20 minutes"
echo ""

# Run the complete playbook
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK"

PLAYBOOK_EXIT_CODE=$?

# --------------------------------------------------
# FINAL SUMMARY
# --------------------------------------------------

echo ""

if [ $PLAYBOOK_EXIT_CODE -eq 0 ]; then
    print_header "Deployment Complete! 🎉"
    echo ""
    echo "Cluster Information:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Nodes (All OpenStack instances):"
    echo "  Master:  ssh ubuntu@$MASTER_IP (compute-test/Legion)"
    echo "  Worker1: ssh ubuntu@$WORKER1_IP (compute-nour/Dell)"
    echo "  Worker2: ssh ubuntu@$WORKER2_IP (compute-nour/Dell)"
    echo ""
    echo "Applications:"
    echo "  Nestie:     http://$MASTER_IP:30080"
    echo "  Prometheus: http://$MASTER_IP:31000"
    echo "  Grafana:    http://$MASTER_IP:32000"
    echo "    Username: admin"
    echo "    Password: admin123"
    echo ""
    echo "Verification Commands:"
    echo "  ssh ubuntu@$MASTER_IP 'kubectl get nodes'"
    echo "  ssh ubuntu@$MASTER_IP 'kubectl get pods -A'"
    echo "  ssh ubuntu@$MASTER_IP 'kubectl get pods -n monitoring'"
    echo ""
    echo "Resource Usage:"
    echo "  Legion (compute-test): Master - 4GB RAM, 2 CPU, 40GB disk"
    echo "  Dell (compute-nour):   Workers - 4GB RAM, 4 CPU, 40GB disk"
    echo "  Dell Remaining:        6GB RAM, 4 CPU, 45GB disk available"
    echo ""
    echo "Stack Management:"
    echo "  View stack:   openstack stack show $STACK_NAME"
    echo "  View events:  openstack stack event list $STACK_NAME"
    echo "  Delete stack: openstack stack delete $STACK_NAME"
    echo "    (Deletes ALL nodes - cluster is fully ephemeral!)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_success "Pure OpenStack Kubernetes cluster is ready! 🚀"
else
    print_error "Deployment failed!"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check logs above for errors"
    echo "  2. Verify inventory: cat $INVENTORY_FILE"
    echo "  3. Test connectivity: ansible all -i $INVENTORY_FILE -m ping"
    echo "  4. Check instances: openstack server list | grep k8s"
    echo "  5. Re-run: ./deploy-openstack.sh"
    echo ""
    echo "Cleanup:"
    echo "  openstack stack delete $STACK_NAME"
    exit 1
fi
