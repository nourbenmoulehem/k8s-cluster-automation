#!/bin/bash

# Heat + Ansible + Full Orchestration


set -e # exit on error


# change to demo-user
source "/home/controller/demo-openrc"

# Configuration :
STACK_NAME="k8s-stack"
HEAT_TEMPLATE="/home/controller/paas/heat/worker-instance.yml"
INVENTORY_FILE="/home/controller/paas/inventory.yml"
PLAYBOOK="/home/controller/paas/site.yml"

# static node information
MASTER_IP="192.168.1.201"
MASTER_USER="master-node"

WORKER2_IP="192.168.1.106"
WORKER2_USER="worker2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
	local MAX_RETRIES=30
	local RETRY_COUNT=0
	
	print_info "Waiting for $NAME to be SSH-ready..."
	
	while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        	if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$IP" "echo 'ready'" &>/dev/null; then
            		print_success "$NAME ($USER@$IP) is ready!"
            		return 0
        	fi
        	RETRY_COUNT=$((RETRY_COUNT + 1))
        	echo -n "."
        	sleep 10
    	done
    
    	echo ""
    	print_error "Timeout waiting for $NAME"
    	return 1
}


# MAIN DEPLOYMENT

print_header "K8s Cluster Deployment"
echo ""
echo "This script will:"
echo "  1. Deploy OpenStack instance for worker1 (via Heat)"
echo "  2. Generate Ansible inventory dynamically"
echo "  3. Deploy complete K8s cluster (master + 2 workers)"
echo "  4. Deploy monitoring stack"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Deployment cancelled"
    exit 1
fi


# --------------------------------------------------
# STEP 1: HEAT STACK WITH K8S CLEANUP
# --------------------------------------------------

print_header "Step 1/5: Deploying OpenStack Instance"

if openstack stack show "$STACK_NAME" &>/dev/null; then
    print_info "Existing stack found. Cleaning up K8s first..."
    
    # Clean up by node name (most reliable!)
    ssh -o StrictHostKeyChecking=no "$MASTER_USER@$MASTER_IP" bash << 'EOFCLEAN'
if kubectl get node worker1 &>/dev/null; then
    echo "Found worker1 in cluster"
    
    echo "Getting worker1 IP info:"
    kubectl get node worker1 -o wide
    
    echo ""
    echo "Collecting pods on worker1..."
    kubectl get pods -A --field-selector spec.nodeName=worker1 \
        --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace > /tmp/pods_to_delete.txt
    
    echo "Draining worker1..."
    kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data --force --timeout=30s || true
    
    echo "Deleting worker1 node..."
    kubectl delete node worker1
    
    echo "Force deleting orphaned pods..."
    while IFS= read -r line; do
        POD_NAME=$(echo $line | awk '{print $1}')
        NAMESPACE=$(echo $line | awk '{print $2}')
        if [ -n "$POD_NAME" ]; then
            kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        fi
    done < /tmp/pods_to_delete.txt
    
    rm -f /tmp/pods_to_delete.txt
    echo "✓ K8s cleanup complete"
else
    echo "worker1 not found in cluster (already removed or never joined)"
fi
EOFCLEAN
    
    print_success "K8s cleanup complete"
    
    # Delete Heat stack
    print_info "Deleting Heat stack..."
    openstack stack delete -y "$STACK_NAME"
    
    while openstack stack show "$STACK_NAME" &>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo ""
    print_success "Old stack deleted"
fi

# Create new stack
print_info "Creating Heat stack: $STACK_NAME"
openstack stack create -t "$HEAT_TEMPLATE" "$STACK_NAME"

if [ $? -ne 0 ]; then
    print_error "Failed to create Heat stack"
    exit 1
fi

print_success "Stack creation initiated"


# STEP 2: WAIT FOR HEAT COMPLETION

print_header "Step 2/5: Waiting for Stack Completion"

while true; do
	STATUS=$(openstack stack show "$STACK_NAME" -f value -c stack_status 2>/dev/null | tr -d '[]' || echo "UNKNOWN")
	
	if [ "$STATUS" == "CREATE_COMPLETE" ]; then
		print_success "Sack Created successfully!"
		break
	elif [ "$STATUS" == "CREATE_FAILED" ]; then
		print_error "Stack creation failed!"
		openstack stack show "${STACK_NAME}"
		exit 1
	fi
	echo -n "."
	sleep 5
done

echo ""


print_header "Step 3/5: Generating Inventory"

# Get worker1 floating IP from Heat output
WORKER1_IP=$(openstack stack output show "$STACK_NAME" worker_floating_ip -f value -c output_value)

if [ -z "$WORKER1_IP" ]; then
    print_error "Failed to get worker1 IP from Heat stack"
    exit 1
fi

print_info "Master:  $MASTER_IP (user: $MASTER_USER)"
print_info "Worker1: $WORKER1_IP (user: ubuntu) ← From Heat"
print_info "Worker2: $WORKER2_IP (user: $WORKER2_USER)"


# Generate inventory.yml
cat > "$INVENTORY_FILE" <<EOF
# ============================================
# Kubernetes Cluster Inventory
# Auto-generated by deploy.sh
# Generated: $(date)
# ============================================

all:
  vars:
    ansible_ssh_private_key_file: ~/.ssh/id_ed25519
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
    ansible_python_interpreter: /usr/bin/python3
  
  children:
    k8s_master:
      hosts:
        master:
          ansible_host: $MASTER_IP
          ansible_user: $MASTER_USER
    
    k8s_workers:
      hosts:
        worker1:
          ansible_host: $WORKER1_IP
          ansible_user: ubuntu
        
        worker2:
          ansible_host: $WORKER2_IP
          ansible_user: $WORKER2_USER
EOF

print_success "Inventory generated: $INVENTORY_FILE"




# STEP 4: WAIT FOR SSH ACCESS

print_header "Step 4/5: Waiting for SSH Access"

# Wait for all nodes to be SSH-ready
wait_for_ssh "$MASTER_IP" "$MASTER_USER" "Master" || exit 1
wait_for_ssh "$WORKER1_IP" "ubuntu" "Worker1" || exit 1
wait_for_ssh "$WORKER2_IP" "$WORKER2_USER" "Worker2" || exit 1

echo ""
print_success "All nodes are SSH-ready!"

# Test Ansible connectivity
print_info "Testing Ansible connectivity..."
ansible all -i "$INVENTORY_FILE" -m ping

if [ $? -ne 0 ]; then
    print_error "Ansible connectivity test failed"
    exit 1
fi

print_success "Ansible connectivity confirmed!"


# STEP 5: DEPLOY KUBERNETES CLUSTER
print_header "Step 5/5: Deploying Kubernetes Cluster"

echo ""
echo "This will run the complete playbook:"
echo "  - Prepare all nodes (common, container-runtime, kubernetes)"
echo "  - Initialize master node"
echo "  - Join worker nodes"
echo "  - Deploy monitoring stack"
echo ""
echo "Estimated time: 10-15 minutes"
echo ""

# Run the complete playbook
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK"

PLAYBOOK_EXIT_CODE=$?

if [ $PLAYBOOK_EXIT_CODE -eq 0 ]; then
    print_success "Deployment completed successfully!"
    echo ""
    echo "Cluster Information:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Nodes:"
    echo "  Master:  ssh $MASTER_USER@$MASTER_IP"
    echo "  Worker1: ssh ubuntu@$WORKER1_IP (OpenStack instance)"
    echo "  Worker2: ssh $WORKER2_USER@$WORKER2_IP"
    echo ""
    echo "Monitoring:"
    echo "  Prometheus: http://$MASTER_IP:31000"
    echo "  Grafana:    http://$MASTER_IP:32000"
    echo "    Username: admin"
    echo "    Password: admin123"
    echo ""
    echo "Verification Commands:"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo "  kubectl get pods -n monitoring"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_success "Kubernetes cluster is ready! 🎉"
else
    print_error "Deployment failed!"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check logs above for errors"
    echo "  2. Verify inventory: cat $INVENTORY_FILE"
    echo "  3. Test connectivity: ansible all -i $INVENTORY_FILE -m ping"
    echo "  4. Re-run: ./deploy.sh"
    exit 1
fi








































































