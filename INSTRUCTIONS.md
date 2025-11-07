# Instructions for AI Assistant

## Project Context
This is a Kubernetes project using microk8s... It contains of three nodes. But for now only one is running on 192.168.50.2. The external IP for the cluster should be only one IP 192.168.50.10.

## Goals
- Enable ingress and metallb
- Configure ingress controller so it is ready for work
- Do I need a ingress controller or does that get created for me when i enable ingress
- The end goal is to have a cluster that listens on 192.168.50.10 and is ready for deploying of services with ingress.
- I dont care about cert-manager right now just want the cluster to start working
- I dont need livness nor readiness probes
