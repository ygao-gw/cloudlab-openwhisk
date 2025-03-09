#!/bin/bash
set -x

# Use particular docker and kubernetes versions. When I've tried to upgrade, I've seen slowdowns in 
# pod creation.
DOCKER_VERSION_STRING=5:27.4.1-1~ubuntu.20.04~focal
KUBERNETES_VERSION_STRING=v1.32

# Unlike home directories, this directory will be included in the image
OW_USER_GROUP=owuser
INSTALL_DIR=/home/cloudlab-openwhisk

# General updates
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

# Openwhisk build dependencies
sudo apt install -y nodejs npm default-jre default-jdk

# In order to use wskdev commands, need to run this: 
# it will install python3 not 2 as in the original script.
sudo apt install -y python

# Pip is useful
sudo apt install -y python3-pip
python3 -m pip install --upgrade pip

# Install docker (https://docs.docker.com/engine/install/ubuntu/)
# Add Docker's official GPG key:
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

sudo apt install -y docker-ce=$DOCKER_VERSION_STRING docker-ce-cli=$DOCKER_VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin

# Set to use cgroupdriver
echo -e '{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker || (echo "ERROR: Docker installation failed, exiting." && exit -1)
sudo docker run hello-world | grep "Hello from Docker!" || (echo "ERROR: Docker installation failed, exiting." && exit -1)

# Install Kubernetes
sudo apt update
# apt-transport-https may be a dummy package; if so, you can skip that package
sudo apt install -y apt-transport-https gpg

# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
sudo mkdir -p -m 755 /etc/apt/keyrings
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION_STRING/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION_STRING/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Set to use private IP
sudo sed -i.bak "s/KUBELET_CONFIG_ARGS=--config=\/var\/lib\/kubelet\/config\.yaml/KUBELET_CONFIG_ARGS=--config=\/var\/lib\/kubelet\/config\.yaml --node-ip=REPLACE_ME_WITH_IP/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Download and install the OpenWhisk CLI
wget https://github.com/apache/openwhisk-cli/releases/download/latest/OpenWhisk_CLI-latest-linux-386.tgz
tar -xvf OpenWhisk_CLI-latest-linux-386.tgz
sudo mv wsk /usr/local/bin/wsk

# Download and install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
sudo ./get_helm.sh

# Create $OW_USER_GROUP group so $INSTALL_DIR can be accessible to everyone
sudo groupadd $OW_USER_GROUP
sudo mkdir $INSTALL_DIR
sudo chgrp -R $OW_USER_GROUP $INSTALL_DIR
sudo chmod -R o+rw $INSTALL_DIR

# Download openwhisk-deploy-kube repo
git clone https://github.com/apache/openwhisk-deploy-kube $INSTALL_DIR/openwhisk-deploy-kube
sudo chgrp -R $OW_USER_GROUP $INSTALL_DIR
sudo chmod -R o+rw $INSTALL_DIR

