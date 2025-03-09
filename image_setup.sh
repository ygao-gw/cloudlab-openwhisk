#!/bin/bash
set -e
set -x

# Logging helper
log_info() {
    echo "$(date +"%T.%N"): $1"
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y
}

# Install packages
install_packages() {
    sudo apt install -y "$@"
}

# Install OpenWhisk build dependencies and upgrade pip
install_openwhisk_dependencies() {
    log_info "Installing OpenWhisk build dependencies..."
    install_packages nodejs npm default-jre default-jdk python python3-pip
    python3 -m pip install --upgrade pip
}

# Install Docker and configure it
install_docker() {
    local DOCKER_VERSION_STRING="5:27.4.1-1~ubuntu.20.04~focal"
    log_info "Installing Docker..."
    install_packages ca-certificates curl

    # Set up Docker's official GPG key and repository
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update

    # Install Docker packages
    install_packages docker-ce=$DOCKER_VERSION_STRING docker-ce-cli=$DOCKER_VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin

    # Configure Docker daemon
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
    sudo systemctl restart docker || { log_info "Docker restart failed, exiting."; exit 1; }
    sudo docker run hello-world | grep "Hello from Docker!" || { log_info "Docker run test failed, exiting."; exit 1; }
    log_info "Docker installed successfully."
}

# Install Kubernetes components
install_kubernetes() {
    local KUBERNETES_VERSION_STRING="v1.32"
    log_info "Installing Kubernetes components..."
    sudo apt update
    install_packages apt-transport-https gpg
    sudo mkdir -p -m 755 /etc/apt/keyrings
    sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION_STRING/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION_STRING/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update
    install_packages kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl

    # Modify kubelet config to include a placeholder for private IP
    sudo sed -i.bak "s|KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml|KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml --node-ip=REPLACE_ME_WITH_IP|g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    log_info "Kubernetes installed successfully."
}

# Install the OpenWhisk CLI
install_openwhisk_cli() {
    log_info "Installing OpenWhisk CLI..."
    wget https://github.com/apache/openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-linux-386.tgz
    tar -xvf OpenWhisk_CLI-latest-linux-386.tgz
    sudo mv wsk /usr/local/bin/wsk
    rm OpenWhisk_CLI-latest-linux-386.tgz
    log_info "OpenWhisk CLI installed."
}

# Install Helm
install_helm() {
    log_info "Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    sudo ./get_helm.sh
    rm get_helm.sh
    log_info "Helm installed."
}

# Set up permissions and clone the OpenWhisk deployment repo
setup_permissions_and_repo() {
    local OW_USER_GROUP="owuser"
    local INSTALL_DIR="/home/cloudlab-openwhisk"
    log_info "Setting up user group and install directory..."
    sudo groupadd -f "$OW_USER_GROUP"
    sudo mkdir -p "$INSTALL_DIR"
    sudo chgrp -R "$OW_USER_GROUP" "$INSTALL_DIR"
    sudo chmod -R o+rw "$INSTALL_DIR"

    log_info "Cloning openwhisk-deploy-kube repository..."
    if [ ! -d "$INSTALL_DIR/openwhisk-deploy-kube" ]; then
        git clone https://github.com/apache/openwhisk-deploy-kube "$INSTALL_DIR/openwhisk-deploy-kube"
    else
        log_info "Repository already exists. Pulling latest changes..."
        (cd "$INSTALL_DIR/openwhisk-deploy-kube" && git pull)
    fi
    sudo chgrp -R "$OW_USER_GROUP" "$INSTALL_DIR"
    sudo chmod -R o+rw "$INSTALL_DIR"
}

# Main execution flow
main() {
    update_system
    install_openwhisk_dependencies
    install_docker
    install_kubernetes
    install_openwhisk_cli
    install_helm
    setup_permissions_and_repo
    log_info "Base image installation completed successfully."
}

main
