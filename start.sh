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

# Functions
configure_docker_storage() {
    echo "$(date +"%T.%N"): Configuring docker storage"
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
    sudo systemctl restart docker || { echo "ERROR: Docker restart failed, exiting."; exit 1; }
    sudo docker run hello-world | grep "Hello from Docker!" || { echo "ERROR: Docker run failed, exiting."; exit 1; }
    echo "$(date +"%T.%N"): Docker storage configured"
}

disable_swap() {
    # Turn swap off and comment out swap entries in /etc/fstab
    sudo swapoff -a || { echo "***Error: Failed to turn off swap"; exit 1; }
    echo "$(date +"%T.%N"): Swap turned off"
    sudo sed -i.bak 's/UUID=.*swap/# &/' /etc/fstab
}

setup_secondary() {
    local node_ip="$1"
    # Start a netcat listener on the secondary node and wait for the join command
    coproc nc { nc -l "$node_ip" "$SECONDARY_PORT"; }
    while true; do
        echo "$(date +"%T.%N"): Waiting for join command (nc pid: $nc_PID)"
        read -r -u "${nc[0]}" cmd
        case "$cmd" in
            *"kube"*)
                MY_CMD="sudo ${cmd//\\/}"
                echo "$(date +"%T.%N"): Command received: $MY_CMD"
                break
                ;;
            *)
                echo "$(date +"%T.%N"): Read: $cmd"
                ;;
        esac
        if [ -z "$nc_PID" ]; then
            echo "$(date +"%T.%N"): Restarting listener via netcat..."
            coproc nc { nc -l "$node_ip" "$SECONDARY_PORT"; }
        fi
    done
    eval "$MY_CMD"
    echo "$(date +"%T.%N"): Secondary node joined Kubernetes cluster!"
}

setup_primary() {
    local node_ip="$1"
    echo "$(date +"%T.%N"): Initializing Kubernetes primary node..."
    sudo kubeadm init --apiserver-advertise-address="$node_ip" --pod-network-cidr=10.11.0.0/16 > "$INSTALL_DIR/k8s_install.log" 2>&1 \
        || { echo "***Error: kubeadm init failed. See $INSTALL_DIR/k8s_install.log"; exit 1; }
    echo "$(date +"%T.%N"): kubeadm init complete; log in $INSTALL_DIR/k8s_install.log"
    
    # Configure kubectl for all users
    for user_dir in /users/*; do
        CURRENT_USER=$(basename "$user_dir")
        sudo mkdir -p "/users/$CURRENT_USER/.kube"
        sudo cp /etc/kubernetes/admin.conf "/users/$CURRENT_USER/.kube/config"
        sudo chown -R "$CURRENT_USER:$PROFILE_GROUP" "/users/$CURRENT_USER/.kube"
        echo "$(date +"%T.%N"): Configured kubectl for user: $CURRENT_USER"
    done
}

apply_calico() {
    echo "$(date +"%T.%N"): Adding Calico Helm repo..."
    helm repo add projectcalico https://projectcalico.docs.tigera.io/charts > "$INSTALL_DIR/calico_install.log" 2>&1 \
        || { echo "***Error: Failed to add Calico Helm repo. See $INSTALL_DIR/calico_install.log"; exit 1; }
    echo "$(date +"%T.%N"): Installing Calico..."
    helm install calico projectcalico/tigera-operator --version v3.22.0 >> "$INSTALL_DIR/calico_install.log" 2>&1 \
        || { echo "***Error: Failed to install Calico. See $INSTALL_DIR/calico_install.log"; exit 1; }
    echo "$(date +"%T.%N"): Waiting for Calico pods to run..."
    while true; do
        NUM_PODS=$(kubectl get pods -n calico-system | wc -l)
        NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
        [ $((NUM_PODS - NUM_RUNNING)) -eq 0 ] && break
        sleep 1
        printf "."
    done
    echo "$(date +"%T.%N"): Calico pods running!"
    
    echo "$(date +"%T.%N"): Waiting for kube-system pods to run..."
    while true; do
        NUM_PODS=$(kubectl get pods -n kube-system | wc -l)
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
        [ $((NUM_PODS - NUM_RUNNING)) -eq 0 ] && break
        sleep 1
        printf "."
    done
    echo "$(date +"%T.%N"): Kubernetes system pods running!"
}

add_cluster_nodes() {
    local total_nodes="$1"
    local remote_cmd
    remote_cmd=$(tail -n 2 "$INSTALL_DIR/k8s_install.log")
    echo "$(date +"%T.%N"): Remote join command: $remote_cmd"
    
    local expected=$((total_nodes))
    local registered
    local counter=0
    while true; do
        registered=$(kubectl get nodes | wc -l)
        if [ "$registered" -ge "$expected" ]; then
            break
        fi
        echo "$(date +"%T.%N"): Attempt #$counter: $registered/$expected nodes registered"
        for (( i=2; i<=total_nodes; i++ )); do
            SECONDARY_IP="$BASE_IP$i"
            echo "$remote_cmd" | nc "$SECONDARY_IP" "$SECONDARY_PORT"
        done
        counter=$((counter + 1))
        sleep 2
    done

    echo "$(date +"%T.%N"): Waiting for all nodes to be Ready..."
    while true; do
        local num_ready
        num_ready=$(kubectl get nodes | grep " Ready" | wc -l)
        [ "$num_ready" -ge "$expected" ] && break
        sleep 1
        printf "."
    done
    echo "$(date +"%T.%N"): All nodes are Ready!"
}

prepare_for_openwhisk() {
    # Args: 1 = IP, 2 = num_nodes, 3 = invoker_count, 4 = invoker_engine, 5 = scheduler_enabled
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
            echo "$(date +"%T.%N"): Skipping labeling non-invoker node $node_name"
        else
            kubectl label nodes "$node_name" openwhisk-role=invoker \
                || { echo "***Error: Failed to label node $node_name as invoker"; exit 1; }
            echo "$(date +"%T.%N"): Labeled node $node_name as openwhisk invoker"
        fi
        counter=$((counter + 1))
    done <<< "$NODE_NAMES"

    echo "$(date +"%T.%N"): Creating openwhisk namespace..."
    kubectl create namespace openwhisk || { echo "***Error: Failed to create openwhisk namespace"; exit 1; }
    
    cp /local/repository/mycluster.yaml "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_IP/$1/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_ENGINE/$4/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_COUNT/$3/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sed -i.bak "s/REPLACE_ME_WITH_SCHEDULER_ENABLED/$5/g" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sudo chown "$USER:$PROFILE_GROUP" "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    sudo chmod g+rw "$INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"
    echo "$(date +"%T.%N"): Updated mycluster.yaml for OpenWhisk deployment"
    
    if [ "$4" = "docker" ] && [ -d "/mydata" ]; then
        sed -i.bak "s/\/var\/lib\/docker\/containers/\/mydata\/docker\/containers/g" "$INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl"
        echo "$(date +"%T.%N"): Updated dockerrootdir in _invoker-helpers.tpl"
    fi
}

deploy_openwhisk() {
    local cluster_ip="$1"
    echo "$(date +"%T.%N"): Deploying OpenWhisk via Helm..."
    pushd "$INSTALL_DIR/openwhisk-deploy-kube" > /dev/null
    helm install owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml > "$INSTALL_DIR/ow_install.log" 2>&1 \
        || { echo "***Error: Helm install failed. Check $INSTALL_DIR/ow_install.log"; exit 1; }
    popd > /dev/null
    echo "$(date +"%T.%N"): Helm install initiated. Monitoring deployment..."

    while true; do
        local deploy_complete
        deploy_complete=$(kubectl get pods -n openwhisk | grep owdev-install-packages | grep Completed | wc -l)
        [ "$deploy_complete" -eq 1 ] && break
        sleep 2
    done
    echo "$(date +"%T.%N"): OpenWhisk deployment complete!"

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
echo "$(date +"%T.%N"): Script arguments: $*"

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

# Configure additional docker storage if mountpoint exists
if [ -d "/mydata" ]; then
    configure_docker_storage
fi

# Add all users to the docker and profile groups, and fix INSTALL_DIR permissions
sudo groupadd "$PROFILE_GROUP" || true
for user_dir in /users/*; do
    CURRENT_USER=$(basename "$user_dir")
    sudo gpasswd -a "$CURRENT_USER" "$PROFILE_GROUP"
    sudo gpasswd -a "$CURRENT_USER" docker
done
sudo chown -R "$USER:$PROFILE_GROUP" "$INSTALL_DIR"
sudo chmod -R g+rw "$INSTALL_DIR"

# Branch based on primary vs secondary
if [ "$1" = "$SECONDARY_ARG" ]; then
    if [ "$3" = "False" ]; then
        echo "$(date +"%T.%N"): Kubernetes start set to False; exiting secondary setup."
        exit 0
    fi
    sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    setup_secondary "$2"
    exit 0
fi

# Primary node branch: check argument count
if [ "$#" -ne "$NUM_PRIMARY_ARGS" ]; then
    echo "***Error: Expected $NUM_PRIMARY_ARGS arguments for primary mode."
    echo "$USAGE"
    exit 1
fi

if [ "$4" = "False" ]; then
    echo "$(date +"%T.%N"): Kubernetes start set to False; exiting primary setup."
    exit 0
fi

sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
setup_primary "$2"
apply_calico
add_cluster_nodes "$3"

if [ "$5" = "False" ]; then
    echo "$(date +"%T.%N"): OpenWhisk deployment set to False; exiting."
    exit 0
fi

prepare_for_openwhisk "$2" "$3" "$6" "$7" "$8"
deploy_openwhisk "$2"

echo "$(date +"%T.%N"): Profile setup completed!"
