# Enable metallb for load balancing on cluster
# This will create 2 daemon sets controller and speaker and add a
# IPAddressPool and L2Advertisement with that range.
# Pool will only have one IP which is where port 80 and 443 are forearded from FW
# And is blocked from the DHCP internal server
# Run an node1
# Needed 2 IP's in the pool otherwise metallb never gave up an IP to ingress
# However *.11 is pinned in the ingress manifest
microk8s enable metallb:192.168.50.10-192.168.50.13

# Enable ingress controller on node1
microk8s enable ingress

# Check that ingress controller is running
kubectl get pods -n ingress

# Check metallb status should be 2 pods controller and speaker
kubectl get pods -n metallb-system

# Check if the ingress controller service got the external IP
kubectl get svc -n ingress

# Specifically look at the controller DaemonSet
kubectl get daemonset -n ingress
kubectl describe daemonset ingress-nginx-controller -n ingress | grep -i 'hostnetwork\|image'

# List the Service(s) it created
kubectl get svc -n ingress
kubectl describe svc ingress-nginx-controller -n ingress

# To test cert-manager deployed on whoami service. From outside of home netork
curl -vk https://whoami.svanbergs.net/
