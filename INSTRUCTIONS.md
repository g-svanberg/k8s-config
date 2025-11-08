# Instructions for AI Assistant

## Project Context
This is a Kubernetes project using microk8s... It contains of three nodes. But for now only one is running on 192.168.50.2. The external IP for the cluster is 192.168.50.11. And ingress and Metallb is working fine right now.

## Goals
- dns is enabled
- The end goal is to have a cluster working with cert-manager and ACME/Lets's encrypt
- my domain is hosted on godaddy and ic called svanbergs.net
- my email address is gurkan.svanberg@gmail.com
- I want to have instructions on which modules i need to enable besides ingress and metallb which is already working fine.
- You can create the manifests you see fit in this repository
- I dont need livness nor readiness probes
