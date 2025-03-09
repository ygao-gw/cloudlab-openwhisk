#!/usr/bin/env python3
"""
Refactored Python cluster creation script for CloudLab/OpenWhisk.

This script defines experiment parameters, creates a LAN,
provisions nodes with IP addresses, and assigns startup services.
For full documentation, see:
https://github.com/CU-BISON-LAB/cloudlab-openwhisk
"""

import geni.portal as portal
import geni.rspec.pg as rspec

BASE_IP = "10.10.1"
BANDWIDTH = 10000000
IMAGE = 'urn:publicid:IDN+wisc.cloudlab.us+image+gwcloudlab-PG0:openwsk-v1:0'

def define_parameters():
    pc = portal.Context()
    pc.defineParameter("nodeCount",
                       "Number of nodes in the experiment. It is recommended that at least 3 be used.",
                       portal.ParameterType.INTEGER, 3)
    pc.defineParameter("nodeType",
                       "Node Hardware Type",
                       portal.ParameterType.NODETYPE, "m510",
                       longDescription="Tested primarily with m510 and xl170 nodes.")
    pc.defineParameter("startKubernetes",
                       "Create Kubernetes cluster",
                       portal.ParameterType.BOOLEAN, True,
                       longDescription="Set up a Kubernetes cluster with default configuration (Calico networking, etc.)")
    pc.defineParameter("deployOpenWhisk",
                       "Deploy OpenWhisk",
                       portal.ParameterType.BOOLEAN, True,
                       longDescription="Deploy OpenWhisk using Helm.")
    pc.defineParameter("numInvokers",
                       "Number of Invokers",
                       portal.ParameterType.INTEGER, 1,
                       longDescription="Number of invokers for OpenWhisk. Non-invoker nodes become core nodes.")
    pc.defineParameter("invokerEngine",
                       "Invoker Engine",
                       portal.ParameterType.STRING, "kubernetes",
                       legalValues=[('kubernetes', 'Kubernetes Container Engine'), ('docker', 'Docker Container Engine')],
                       longDescription="Determines how the invoker creates containers.")
    pc.defineParameter("schedulerEnabled",
                       "Enable OpenWhisk Scheduler",
                       portal.ParameterType.BOOLEAN, False,
                       longDescription="Enable the OpenWhisk scheduler component (and etcd).")
    pc.defineParameter("tempFileSystemSize",
                       "Temporary Filesystem Size (in GB)",
                       portal.ParameterType.INTEGER, 0,
                       advanced=True,
                       longDescription="Size of temporary file system for each node (0 GB indicates maximum available).")
    params = pc.bindParameters()
    if not params.startKubernetes and params.deployOpenWhisk:
        perr = portal.ParameterWarning("A Kubernetes cluster must be created to deploy OpenWhisk", ['startKubernetes'])
        pc.reportError(perr)
    pc.verifyParameters()
    return pc, params

def create_node(name, nodes, lan, params):
    node = request.RawPC(name)
    node.disk_image = IMAGE
    node.hardware_type = params.nodeType
    iface = node.addInterface("if1")
    ip_suffix = 1 + len(nodes)
    iface.addAddress(rspec.IPv4Address(f"{BASE_IP}.{ip_suffix}", "255.255.255.0"))
    lan.addInterface(iface)
    bs = node.Blockstore(name + "-bs", "/mydata")
    bs.size = f"{params.tempFileSystemSize}GB"
    bs.placement = "any"
    nodes.append(node)
    print(f"Created node {name} with IP {BASE_IP}.{ip_suffix}")

def main():
    global request  # Allows create_node to access the global 'request'
    pc, params = define_parameters()
    request = pc.makeRequestRSpec()

    nodes = []
    lan = request.LAN()
    lan.bandwidth = BANDWIDTH

    # Create nodes
    for i in range(params.nodeCount):
        name = f"ow{i+1}"
        create_node(name, nodes, lan, params)

    # Add startup service to secondary nodes
    for i, node in enumerate(nodes[1:], start=2):
        node.addService(rspec.Execute(shell="bash",
            command=f"/local/repository/start.sh secondary {BASE_IP}.{i} {params.startKubernetes} > /home/cloudlab-openwhisk/start.log 2>&1 &"))
    
    # Add startup service to primary node
    primary_cmd = (f"/local/repository/start.sh primary {BASE_IP}.1 {params.nodeCount} "
                   f"{params.startKubernetes} {params.deployOpenWhisk} {params.numInvokers} "
                   f"{params.invokerEngine} {params.schedulerEnabled} > /home/cloudlab-openwhisk/start.log 2>&1")
    nodes[0].addService(rspec.Execute(shell="bash", command=primary_cmd))

    pc.printRequestRSpec()

if __name__ == '__main__':
    main()
