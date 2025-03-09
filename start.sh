#!/bin/bash
set -ex

# Constants
BASE_IP="10.10.1."
SECONDARY_PORT=3000
INSTALL_DIR="/home/cloudlab-openwhisk"
NUM_MIN_ARGS=3
PRIMARY_ARG="primary"
SECONDARY_ARG="secondary"
USAGE=$'Usage:\n\t./start.sh secondary <node_ip> <start_kubernetes>\n\t./start.sh primary <node_ip> <num_nodes> <start_kubernetes> <deploy_openwhisk> <invoker_count> <invoker_engine> <scheduler_enabled>'
NUM_PRIMARY_ARGS=8
PROFILE_GROUP="profileuser"

# Logging helper
log_info() {
    echo "$(date +"%T.%N"): $1"
}

# Configure Docker storage if extra disk is available
configure_docker_storage() {
    log_info "Configuring Docker storage..."
    sudo mkdir -p /mydata/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {"max-size": "100m"},
    "storage-driver": "overlay2",
    "data-root": "/mydata/docker"
}
EOF
    sudo systemctl restart docker || { log_info "Docker restart failed, exiting."; exit 1; }
    sudo docker run hello-world | grep "Hello from Docker!" || { log_info "Docker run test failed, exiting."; exit 1; }
    log_info "Docker storage configured."
}

# Disable swap and update /etc/fstab accordingly
disable_swap() {
    log_info "Disabling swap..."
    sudo swapoff -a || { log_info "Failed to disable swap"; exit 1; }
    sudo sed -i.bak 's/UUID=.*swap/# &/' /etc/fstab
    log_info "Swap disabled."
}

# Set up secondary node to join the Kubernetes cluster
setup_secondary() {
    local node_ip="$1"
    log_info "Setting up secondary node at IP: $node_ip"
    coproc nc { nc -l "$node_ip" "$SECONDARY_PORT"; }
    while true; do
        log_info "Waiting for join command (nc pid: $nc_PID)"
        read -r -u "${nc[0]}" cmd
        case "$cmd" in
            *"kube"*)
                MY_CMD="sudo ${cmd//\\/}"
                log_info "Command received: $MY_CMD"
                break
                ;;
            *)
                log_info "Received: $cmd"
                ;;
        esac
        if [ -z "$nc_PID" ]; then
            log_info "Restarting listener via netcat..."
            coproc nc { nc -l "$node_ip" "$SECONDARY_PORT"; }
        fi
    done
    eval "$MY_CMD"
    log_info "Secondary node joined Kubernetes cluster!"
}

# Initialize the primary node for Kubernetes
setup_primary() {
    local node_ip="$1"
    log_info "Initializing Kubernetes primary node at IP: $node_ip..."
    sudo kubeadm init --apiserver-advertise-address="$node_ip" --pod-network-cidr=10.11.0.0/16 > "$INSTALL_DIR/k8s_install.log" 2>&1 \
        || { log_info "kubeadm init failed. See $INSTALL_DIR/k8s_install.log"; exit 1; }
    log_info "kubeadm init complete; log available at $INSTALL_DIR/k8s_install.log"
    
    # Configure kubectl for all users
    for user_dir in /users/*; do
        CURRENT_USER=$(basename "$user_dir")
        sudo mkdir -p "/users/$CURRENT_USER/.kube"
        sudo cp /etc/kubernetes/admin.conf "/users/$CURRENT_USER/.kube/config"
        sudo chown -R "$CURRENT_USER:$PROFILE_GROUP" "/users/$CURRENT_USER/.kube"
        log_info "Configured kubectl for user: $CURRENT_USER"
    done
}

# Install Calico networking using Helm
apply_calico() {
    log_info "Adding Calico Helm repo and installing Calico..."
    helm repo add projectcalico https://projectcalico.docs.tigera.io/charts > "$INSTALL_DIR/calico_install.log" 2>&1 \
        || { log_info "Failed to add Calico Helm repo. See $INSTALL_DIR/calico_install.log"; exit 1; }
    helm install calico projectcalico/tigera-operator --version v3.22.0 >> "$INSTALL_DIR/calico_install.log" 2>&1 \
        || { log_info "Failed to install Calico. See $INSTALL_DIR/calico_install.log"; exit 1; }
    
    log_info "Waiting for Calico pods to be fully running..."
    while true; do
        NUM_PODS=$(kubectl get pods -n calico-system | wc -l)
        NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
        [ $((NUM_PODS - NUM_RUNNING)) -eq 0 ] && break
        sleep 1
        printf "."
    done
    log_info "Calico pods are running."
    
    log_info "Waiting for kube-system pods to be fully running..."
    while true; do
        NUM_PODS=$(kubectl get pods -n kube-system | wc -l)
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
        [ $((NUM_PODS - NUM_RUNNING)) -eq 0 ] && break
        sleep 1
        printf "."
    done
    log_info "Kubernetes system pods are running."
}

# Add all nodes to the cluster by issuing the join command to secondaries
add_cluster_nodes() {
    local total_nodes="$1"
    local remote_cmd
    remote_cmd=$(tail -n 2 "$INSTALL_DIR/k8s_install.log")
    log_info "Remote join command: $remote_cmd"
    
    local expected=$((total_nodes))
    local registered
    local counter=0
    while true; do
        registered=$(kubectl get nodes | wc -l)
        if [ "$registered" -ge "$expected" ]; then
            break
        fi
        log_info "Attempt #$counter: $registered/$expected nodes registered"
        for (( i=2; i<=total_nodes; i++ )); do
            SECONDARY_IP="$BASE_IP$i"
            echo "$remote_cmd" | nc "$SECONDARY_IP" "$SECONDARY_PORT"
        done
        counter=$((counter + 1))
        sleep 2
    done

    log_info "Waiting for all nodes to be in the Ready state..."
    while true; do
        local num_ready
        num_ready=$(kubectl get nodes | grep " Ready" | wc -l)
        [ "$num_ready" -ge "$expected" ] && break
        sleep 1
        printf "."
    done
    log_info "All nodes are Ready!"
}

# Prepare OpenWhisk deployment configuration
prepare_for_openwhisk() {
    pushd "$INSTALL_DIR/openwhisk-deploy-kube" > /dev/null
    git pull
    popd > /dev/null

    local NODE_NAMES
    NODE_NAMES=$(kubectl get nodes -o name)
    local core_nodes=$(( $2 - $3 ))
    local counter=0

    while IFS= read -r node; do
        local node_name=${node:5}
        if [ "$counter" -lt "$core_nodes" ]; then
            log_info "Skipping labeling non-invoker node $node_name"
        else
            kubectl label nodes "$node_name" openwhisk-role=invoker \
                || { log_info "Failed to label node $node_name as invoker"; exit 1; }
            log_info "Labeled node $node_name as OpenWhisk invoker"
        fi
        counter=$((counter + 1))
    done <<< "$NODE_NAMES"

    log_info "Creating openwhisk namespace..."
    kubectl create namespace openwhisk || { log_info "Failed to create openwhisk namespace"; exit 1; }
    
    cp /local/repository/mycluster.yaml "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_IP/$1/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_ENGINE/$4/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_COUNT/$3/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_SCHEDULER_ENABLED/$5/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sudo chown "$USER:$PROFILE_GROUP" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sudo chmod g+rw "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    log_info "Updated mycluster.yaml for OpenWhisk deployment"
    
    if [ "$4" = "docker" ] && [ -d "/mydata" ]; then
        sed -i.bak "s/\/var\/lib\/docker\/containers/\/mydata\/docker\/containers/g" "$INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl"
        log_info "Updated dockerrootdir in _invoker-helpers.tpl"
    fi
}

# Deploy OpenWhisk using Helm
deploy_openwhisk() {
    local cluster_ip="$1"
    log_info "Deploying OpenWhisk via Helm..."
    pushd "$INSTALL_DIR/openwhisk-deploy-kube" > /dev/null
    helm install owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml > "$INSTALL_DIR/ow_install.log" 2>&1 \
        || { log_info "Helm install failed. Check $INSTALL_DIR/ow_install.log"; exit 1; }
    popd > /dev/null
    log_info "Helm install initiated. Monitoring deployment..."

    while true; do
        local deploy_complete
        deploy_complete=$(kubectl get pods -n openwhisk | grep owdev-install-packages | grep Completed | wc -l)
        [ "$deploy_complete" -eq 1 ] && break
        sleep 2
    done
    log_info "OpenWhisk deployment complete!"

    for user_dir in /users/*; do
        local CURRENT_USER
        CURRENT_USER=$(basename "$user_dir")
        cat <<EOF | sudo tee "/users/$CURRENT_USER/.wskprops"
APIHOST=${cluster_ip}:31001
AUTH=23bc46b1-71f6-4ed5-8c54-816aa4f8c502:123zO3xZCLrMN6v2BKK1dXYFpXlPkccOFqm12CdAsMgRU4VrNZ9lyGVCGuMDGIwP
EOF
        sudo chown "$CURRENT_USER:$PROFILE_GROUP" "/users/$CURRENT_USER/.wskprops"
    done
}

# Main script execution
log_info "Script arguments: $*"

if [ "$#" -lt "$NUM_MIN_ARGS" ]; then
    echo "***Error: Expected at least $NUM_MIN_ARGS arguments."
    echo "$USAGE"
    exit 1
fi

if [ "$1" != "$PRIMARY_ARG" ] && [ "$1" != "$SECONDARY_ARG" ]; then
    echo "***Error: First argument must be '$PRIMARY_ARG' or '$SECONDARY_ARG'."
    echo "$USAGE"
    exit 1
fi

# Disable swap for Kubernetes
disable_swap

# Configure additional Docker storage if /mydata exists
if [ -d "/mydata" ]; then
    configure_docker_storage
fi

# Add all users to the docker and profile groups, then fix INSTALL_DIR permissions
sudo groupadd "$PROFILE_GROUP" || true
for user_dir in /users/*; do
    CURRENT_USER=$(basename "$user_dir")
    sudo gpasswd -a "$CURRENT_USER" "$PROFILE_GROUP"
    sudo gpasswd -a "$CURRENT_USER" docker
done
sudo chown -R "$USER:$PROFILE_GROUP" "$INSTALL_DIR"
sudo chmod -R g+rw "$INSTALL_DIR"

if [ "$1" = "$SECONDARY_ARG" ]; then
    if [ "$3" = "False" ]; then
        log_info "Kubernetes start set to False; exiting secondary setup."
        exit 0
    fi
    sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    setup_secondary "$2"
    exit 0
fi

if [ "$#" -ne "$NUM_PRIMARY_ARGS" ]; then
    echo "***Error: Expected $NUM_PRIMARY_ARGS arguments for primary mode."
    echo "$USAGE"
    exit 1
fi

if [ "$4" = "False" ]; then
    log_info "Kubernetes start set to False; exiting primary setup."
    exit 0
fi

sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
setup_primary "$2"
apply_calico
add_cluster_nodes "$3"

if [ "$5" = "False" ]; then
    log_info "OpenWhisk deployment set to False; exiting."
    exit 0
fi

prepare_for_openwhisk "$2" "$3" "$6" "$7" "$8"
deploy_openwhisk "$2"
log_info "Profile setup completed!"
