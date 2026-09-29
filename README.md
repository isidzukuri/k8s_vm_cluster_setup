# Kubernetes cluster on VMs

kubernetes cluster built for educational purpose.

## Architecture

- 1 external load balancer in front of the Gateway API cluster
- 3 Gateway API nodes
- 3 control plane nodes
- 3 DB Statefull nodes
- 3 replicas of storage on two nodes
- 1-3 worker nodes for fronend
- 1-n worker nodes

<!-- <img src="images/cluster_diagram.png" title="cluster_diagram" alt="cluster_diagram" width="100%"> -->

## Tools

- page resource for monitoring (Prometheus + headlamp, k9s)
- logs agregator (Prometheus)
- request tracing (Jaeger)
- resource usage alert (Prometheus stack)


## VM setup

### Configuration

Host machine: Ubuntu 22.04, QEMU/KVM installed.

VMs OS: [Debian 13.5.0-netinst](https://www.debian.org/distrib/netinst) ([iso](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso))


### Setup 

Create a base ISO template for k8s nodes.

Debian netinst is selected to make it smaller size but bit more practical and user-friendly than alpine release. 

Download OS image https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso

Create new VM in QEMU/KVM. At least 2G of ram and 20G+ of disc space. 

Next steps are straight forward until "network setup". Pick here "bridge". In field "device name" enter value from result of command 
executed on host machine `ip l`. Example:
```
user@hostcomputer:~$ ip l
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: wlp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DORMANT group default qlen 1000
    link/ether f4:8c:50:7e:dc:4d brd ff:ff:ff:ff:ff:ff
3: virbr0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default qlen 1000
    link/ether 52:54:00:g7:1c:98 brd ff:ff:ff:ff:ff:ff
```

In my case it will be `virbr0`.
 
Why this works for my K8s architecture: virt-manager will automatically place all my VMs onto the 192.168.122.X subnet. Because they are all on the same virtual switch (virbr0), all Kubernetes nodes (Control Plane, Workers, Gateway API, DBs) will be able to talk to each other with perfect local speed, and they will still have internet access to pull images. Your host machine will also be able to talk to them directly.

At the following steps:

- disable ui. Leave ssh and utilities.
- disk partitioning choose "For servers"
- delete swap and continue
- Credentials: `user: node_admin`, `pass: 12345`

When OS instalation comleated and terminal loaded type `ip a` to get ip address of machine.

Now it can be accessed via ssh from the host machine: `ssh node_admin@192.168.122.197`

From the root account add user to sudoers: 

```
su 
usermod -aG sudo node_admin

apt install sudo -y

/sbin/usermod -aG sudo node_admin
```

Post instalation configuration:

```
sudo vi /etc/apt/sources.list

sudo apt update && apt upgrade -y

sudo apt install -y curl apt-transport-https ca-certificates gnupg2 conntrack socat

sudo cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo /sbin/modprobe overlay
sudo /sbin/modprobe br_netfilter

sudo cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo systemctl enable systemd-networkd
sudo systemctl start systemd-networkd
```

Run:
```
sudo nano /etc/systemd/network/20-wired.network
```
and paste:
```
[Match]
Name=en*

[Network]
DHCP=yes
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
ClientIdentifier=mac
```

Install containerd:
```
sudo sysctl --system

sudo rm -f /etc/network/interfaces

sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd

containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

sudo nano /etc/containerd/config.toml
```

change to:
```
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

Few more commands:
```
sudo systemctl restart containerd
sudo systemctl enable containerd

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet

sudo mkdir -p /usr/lib
sudo ln -s /opt/cni/bin /usr/lib/cni

sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

rm-f /etc/netplan/*.bak

sudo apt-get clean
history -c

sudo poweroff
```

Node template is ready.




## Host machine load balancer setup
<!-- 
                      ┌──────────────────────────────┐
                      │ Host Machine HAProxy         │
                      │ (External Load Balancer)     │
                      └──────────────┬───────────────┘
                                     │
                    Split by Port    │    Split by Port
                    6443 (TCP)       │    80/443 (HTTP/S)
            ┌────────────────────────┴────────────────────────┐
            ▼                                                 ▼
┌───────────────────────────┐                     ┌───────────────────────────┐
│ Control Plane Cluster     │                     │ Gateway API Cluster       │
│ (Nodes: .11, .12, .13)    │                     │ (Nodes: .21, .22, .23)    │
├───────────────────────────┤                     ├───────────────────────────┤
│ Runs: kube-apiserver      │                     │ Runs: Envoy / NGINX       │
│                           │                     │       Data Plane          │
│ Role: Manages the cluster │                     │                           │
│       state and database. │                     │ Role: Routes traffic to   │
│                           │                     │       your apps/workers.  │
└───────────────────────────┘                     └─────────────┬─────────────┘
                                                                │
                                                                ▼
                                                  ┌───────────────────────────┐
                                                  │ Worker Nodes (Backend/FE) │
                                                  │ (Apps & Microservices)    │
                                                  └───────────────────────────┘
 -->

On host machine:
```
sudo apt update && sudo apt install -y sshpass
sudo apt update && sudo apt install -y libguestfs-tools
sudo apt update && sudo apt install -y haproxy
sudo nano /etc/haproxy/haproxy.cfg
```
paste:
```
# ==========================================
# 1. KUBERNETES CONTROL PLANE LOAD BALANCING
# ==========================================
frontend k8s-control-plane
    bind 192.168.122.1:6443
    mode tcp
    option tcplog
    default_backend k8s-cp-backends

backend k8s-cp-backends
    mode tcp
    option tcp-check
    balance roundrobin
    server k8s-cp-1 192.168.122.11:6443 check
    server k8s-cp-2 192.168.122.12:6443 check
    server k8s-cp-3 192.168.122.13:6443 check

# ==========================================
# 2. GATEWAY API CLUSTER LOAD BALANCING (HTTP)
# ==========================================
frontend k8s-gateway-http
    bind 192.168.122.1:80
    mode tcp
    option tcplog
    default_backend k8s-gw-http-backends

backend k8s-gw-http-backends
    mode tcp
    option tcp-check
    balance roundrobin
    server k8s-gw-1 192.168.122.21:80 check
    server k8s-gw-2 192.168.122.22:80 check
    server k8s-gw-3 192.168.122.23:80 check

# ==========================================
# 3. GATEWAY API CLUSTER LOAD BALANCING (HTTPS)
# ==========================================
frontend k8s-gateway-https
    bind 192.168.122.1:443
    mode tcp
    option tcplog
    default_backend k8s-gw-https-backends

backend k8s-gw-https-backends
    mode tcp
    option tcp-check
    balance roundrobin
    server k8s-gw-1 192.168.122.21:443 check
    server k8s-gw-2 192.168.122.22:443 check
    server k8s-gw-3 192.168.122.23:443 check
```

Restart load balncer:
```
sudo systemctl restart haproxy
```
Check status:
```
sudo hatop -s /run/haproxy/admin.sock
```

Now, when you clone your Debian template to spin up control plane node (k8s-cp-1), you can immediately run kubeadm init --control-plane-endpoint "192.168.122.1:6443", and the host load balancer will be completely ready to capture and route the traffic.



## VMs management

Usefull commands:
```
virsh net-destroy default
virsh net-start default
virsh net-dhcp-leases default
virsh net-edit default

# All Graceful Shutdown
for vm in $(virsh list --state-running --name); do virsh shutdown "$vm"; done

# All Immediate Stop (Force Off / Pull the Plug)
for vm in $(virsh list --state-running --name); do virsh destroy "$vm"; done
```

Scripts:

Spin up worker nodes:

```
# Usage: ./create_k8s_nodes.sh <count> <start_from>
# Example: ./create_k8s_nodes.sh 3 5
# → creates k8s-node-5, k8s-node-6, k8s-node-7
```

virsh folders which contains IPs
```
/var/lib/libvirt/dnsmasq
```


## Cluster setup

### Control Plane Setup 

Create the 3 Control Plane Clones:
```
virt-clone --original debian13_k8s_node_template --name k8s-cp-1 --auto-clone
virt-clone --original debian13_k8s_node_template --name k8s-cp-2 --auto-clone
virt-clone --original debian13_k8s_node_template --name k8s-cp-3 --auto-clone
```

Grab the Generated MAC Addresses:
```
virsh domiflist k8s-cp-1
virsh domiflist k8s-cp-2
virsh domiflist k8s-cp-3
```

Bind the MAC Addresses to IPs:
```
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:49:1b:a6" name="k8s-cp-1" ip="192.168.122.11"/>' --current
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:d2:c5:44" name="k8s-cp-2" ip="192.168.122.12"/>' --current
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:ae:19:01" name="k8s-cp-3" ip="192.168.122.13"/>' --current
```

Update hostnames of created VMs from host:
```
sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-cp-1.qcow2 <<EOF
write /etc/hostname "k8s-cp-1\n"
download /etc/hosts /tmp/hosts-cp1
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-cp-1/' /tmp/hosts-cp1
upload /tmp/hosts-cp1 /etc/hosts
! rm /tmp/hosts-cp1
EOF


sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-cp-2.qcow2 <<EOF
write /etc/hostname "k8s-cp-2\n"
download /etc/hosts /tmp/hosts-cp2
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-cp-2/' /tmp/hosts-cp2
upload /tmp/hosts-cp2 /etc/hosts
! rm /tmp/hosts-cp2
EOF


sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-cp-3.qcow2 <<EOF
write /etc/hostname "k8s-cp-3\n"
download /etc/hosts /tmp/hosts-cp3
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-cp-3/' /tmp/hosts-cp3
upload /tmp/hosts-cp3 /etc/hosts
! rm /tmp/hosts-cp3
EOF
```

Boot the nodes:
```
virsh start k8s-cp-1
virsh start k8s-cp-2
virsh start k8s-cp-3
```

check if they successfully checked in with their target IPs by running (wait 20+ seconds):
```
virsh net-dhcp-leases default
```

Log into `k8s-cp-1` via SSH from your host machine:
```
ssh node_admin@192.168.122.11
```

Explicitly pass --control-plane-endpoint pointing to host's HAProxy load balancer IP (192.168.122.1:6443), and use --upload-certs so the secondary master nodes can automatically sync security certificates.

Run this command on k8s-cp-1:
```
sudo kubeadm init \
  --control-plane-endpoint "192.168.122.1:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

When this completes successfully, the output will print a block of text at the very bottom. Scroll down and look for the specific kubeadm join command meant for Control Plane nodes. It will look like this:

```
kubeadm join 192.168.122.1:6443 --token w2beek.19b34k7eg53en9ig \
        --discovery-token-ca-cert-hash sha256:ab66f53016b0c1e7fc16fe77d2a65945d9e68414e7f775065650f25eef411a43 \
        --control-plane --certificate-key 150da3f28295e3a95a4222d9bd03960b3d2da7a0c965e9a733823bf24bd692f6
```

Join `k8s-cp-2` and `k8s-cp-3`. Open two new terminals on host machine and SSH into the other two nodes:
```
ssh node_admin@192.168.122.12 
ssh node_admin@192.168.122.13
```

In both nodes run:
```
sudo kubeadm join 192.168.122.1:6443 --token w2beek.19b34k7eg53en9ig \
        --discovery-token-ca-cert-hash sha256:ab66f53016b0c1e7fc16fe77d2a65945d9e68414e7f775065650f25eef411a43 \
        --control-plane --certificate-key 150da3f28295e3a95a4222d9bd03960b3d2da7a0c965e9a733823bf24bd692f6
```

Wait about 30–60 seconds for the network pods to initialize across all nodes, then run this final check on k8s-cp-1
```
kubectl get nodes
```

You should see all three machines (k8s-cp-1, k8s-cp-2, k8s-cp-3) with a status of `Ready` and roles of `control-plane`.

On host check `sudo hatop -s /run/haproxy/admin.sock` should be changes of "CHECK" column to "L4OK"



#### (Optional) Add cluster config to host`s kubectl

```
ssh node_admin@192.168.122.11

sudo cp /etc/kubernetes/admin.conf $HOME/temp_admin.conf
sudo chown $(id -u):$(id -g) $HOME/temp_admin.conf
```

from host

```
scp node_admin@192.168.122.11:~/temp_admin.conf $HOME/.kube/new_config
ssh node_admin@192.168.122.11 "rm ~/temp_admin.conf"
KUBECONFIG=$HOME/.kube/config:$HOME/.kube/new_config kubectl config view --flatten > $HOME/.kube/merged_config
mv $HOME/.kube/merged_config $HOME/.kube/config
rm $HOME/.kube/new_config
chmod 600 $HOME/.kube/config
```
Now cluster can be managed from host.



### Gateway API nodes setup

Prepare VMs:
```
virt-clone --original debian13_k8s_node_template --name k8s-gw-1 --auto-clone
virt-clone --original debian13_k8s_node_template --name k8s-gw-2 --auto-clone
virt-clone --original debian13_k8s_node_template --name k8s-gw-3 --auto-clone

virsh domiflist k8s-gw-1
virsh domiflist k8s-gw-2
virsh domiflist k8s-gw-3

sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-gw-1.qcow2 <<EOF
write /etc/hostname "k8s-gw-1\n"
download /etc/hosts /tmp/hosts-gw1
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-gw-1/' /tmp/hosts-gw1
upload /tmp/hosts-gw1 /etc/hosts
! rm /tmp/hosts-gw1
EOF


sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-gw-2.qcow2 <<EOF
write /etc/hostname "k8s-gw-2\n"
download /etc/hosts /tmp/hosts-gw2
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-gw-2/' /tmp/hosts-gw2
upload /tmp/hosts-gw2 /etc/hosts
! rm /tmp/hosts-gw2
EOF


sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-gw-3.qcow2 <<EOF
write /etc/hostname "k8s-gw-3\n"
download /etc/hosts /tmp/hosts-gw3
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-gw-3/' /tmp/hosts-gw3
upload /tmp/hosts-gw3 /etc/hosts
! rm /tmp/hosts-gw3
EOF
```

Bind the MAC Addresses to IPs:
```
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:04:97:09" name="k8s-gw-1" ip="192.168.122.21"/>' --current
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:16:96:43" name="k8s-gw-2" ip="192.168.122.22"/>' --current
virsh net-update default add ip-dhcp-host '<host mac="52:54:00:c9:38:33" name="k8s-gw-3" ip="192.168.122.23"/>' --current

virsh start k8s-gw-1
virsh start k8s-gw-2
virsh start k8s-gw-3
```

Run this on k8s-cp-1 to get join command:
```
sudo kubeadm token create --print-join-command
```

SSH into each Gateway VM from your host:
```
ssh node_admin@192.168.122.21
ssh node_admin@192.168.122.22
ssh node_admin@192.168.122.23
```

and run generated join command generated on control plane node:
```
kubeadm join 192.168.122.1:6443 --token n0wjow.kar7bh82a21qtxpc --discovery-token-ca-cert-hash sha256:1dba1c4dd343fe97bfb70b6c1c6f50a812c2181b00ea6e05de18684c4b2add04
```
Within a minute, all three k8s-gw nodes should turn `Ready`.

Label nodes:
```
kubectl label node k8s-gw-1 node-role.kubernetes.io/gateway=true gateway-api=dataplane
kubectl label node k8s-gw-2 node-role.kubernetes.io/gateway=true gateway-api=dataplane
kubectl label node k8s-gw-3 node-role.kubernetes.io/gateway=true gateway-api=dataplane
```
To isolate these nodes so only Gateway API managed proxies run on them, apply a specific taint:
```
kubectl taint nodes k8s-gw-1 gateway-api=dataplane:NoSchedule
kubectl taint nodes k8s-gw-2 gateway-api=dataplane:NoSchedule
kubectl taint nodes k8s-gw-3 gateway-api=dataplane:NoSchedule
```

When deploying Gateway API proxy daemonset or deployment, pod template spec will look clean and role-specific:
```
spec:
  tolerations:
  - key: "gateway-api"
    operator: "Equal"
    value: "dataplane"
    effect: "NoSchedule"
  nodeSelector:
    gateway-api: "dataplane"
```

#### Gateway API implementation setup

Setup envoy:

```
helm repo add envoygateway https://helm.envoygateway.io
helm repo update

helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.1 \
  --namespace envoy-gateway-system \
  --create-namespace \
  -f envoy_setup_values.yaml

kubectl apply -f k8s-gateway.yaml
```

### Frondend nodes setup

Prepare VM:
```
virt-clone --original debian13_k8s_node_template --name k8s-fe-1 --auto-clone

sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-fe-1.qcow2 <<EOF
write /etc/hostname "k8s-fe-1\n"
download /etc/hosts /tmp/hosts-fe1
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-fe-1/' /tmp/hosts-fe1
upload /tmp/hosts-fe1 /etc/hosts
! rm /tmp/hosts-fe1
EOF

virsh start k8s-fe-1
```

Get ip and ssh into fe vm to run join cluster command.

Taint and label:
```
kubectl label node k8s-fe-1 app.kubernetes.io/tier=frontend
kubectl taint nodes k8s-fe-1 tier=frontend:NoSchedule
```

Apply HTTPRoute and app deployment:
```
kubectl apply -f frontend-route.yaml

kubectl apply -f frontend-deployment.yaml
```

Status page should be available http://192.168.122.1/



### Storage setup

Create the 3 Clones:
```
# use script
sh create_k8s_nodes.sh 3 0
```

or repate 3 times, dont forget to change id:
```
virt-clone --original debian13_k8s_node_template --name k8s-node-2 --auto-clone

sudo guestfish -i -a /home/isidzukuri/second_ssd/qemu_kvm_vms/k8s-node-2.qcow2 <<EOF
write /etc/hostname "k8s-node-2\n"
download /etc/hosts /tmp/hosts-node2
! sed -i 's/127.0.1.1.*/127.0.1.1\tk8s-node-2/' /tmp/hosts-node2
upload /tmp/hosts-node2 /etc/hosts
! rm /tmp/hosts-node2
EOF

virsh start k8s-node-2
```

Log into each new VM and join it to k8s cluster.

Run: 

```
kubectl apply -f local-path-storage.yaml

kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Can be verified with pvc_example.yaml, dont forget to tear it down `kubectl delete -f pvc_example.yaml`.


### Database setup

Dont forget to complete setup of storage before.

```
helm install test-postgresql bitnami/postgresql --version 18.7.3 -n test-postgresql --create-namespace
```

Now it should be possible to enter pods terminal and run `psql` cli. To get password generated by instalation:
```
kubectl get secret --namespace test-postgresql test-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d
```

Install pgadmin 
```
k apply -f pgadmin.yaml
```

Get node ip where pgadmin is installed add port 32000, and open in browser `http://192.168.122.101:32000/pgadmin/`

Connect pgadmin to DB:
```
kubectl get svc -A
```
Construct the Connection String (Host Name):
```
<service-name>.<namespace>.svc.cluster.local

test-postgresql.test-postgresql.svc.cluster.local
```

If Gateway API is configured you can access via `http://192.168.122.1/pgadmin/`


### Prometheus setup

```
helm install my-prometheus prometheus-community/kube-prometheus-stack \
  -n prometheus-monitoring --create-namespace \
  --set prometheus.prometheusSpec.externalUrl=http://192.168.122.1/cluster_prometheus/ \
  --set prometheus.prometheusSpec.routePrefix=/ \
  --set grafana.enabled=false
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=5Gi

kubectl apply -f prometheus-route.yaml
kubectl apply -f prometheus-alert-manager-route.yaml
```

Should be available now:
http://192.168.122.1/cluster_prometheus/ 
http://192.168.122.1/cluster_alertmanager/


Set alerts to check it works:
```
k apply -f alert-rules.yaml
```

Check alert manager or type into Prometheus UI query:
```
ALERTS{alertname="WatchdogTestAlert"}
```

### Headlamp Setup

```
kubectl apply -f kubernetes-headlamp.yaml
```

Should be avalable now http://192.168.122.1/headlamp/c/main/nodes

Read more https://headlamp.dev/docs/latest/installation/in-cluster/


im not sure if its required:
```
kubectl create clusterrolebinding headlamp-prometheus-proxy \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:headlamp-admin
```

### Jaeger setup
```
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm install jaeger jaegertracing/jaeger
```

### Autoscaling setup

#### HPA

Run metrics server:
```
k apply -f  hpa_example/metrics-server.yaml
```

Create test deployment:
```
k apply -f  hpa_example/php-apache-deployment.yaml
```

Enable HPA
```
k apply -f  hpa_example/hpa.yaml
```

Generate load and watch pod quantity change
```
kubectl run -i --tty --rm load-generator --image=busybox:1.28 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```


___


TODO:

- RBAC
- copy all external yamls into vm_cluster foder
- convert all helm instalation to yaml
- draw scheme
- automate VMs provisioning
- simple app which goes thru FE -> BE -> DB
- k8s testing tools
