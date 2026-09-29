#!/bin/bash
# Usage: ./create_k8s_nodes.sh <count> <start_from>
# Example: ./create_k8s_nodes.sh 3 5
# → creates k8s-node-5, k8s-node-6, k8s-node-7

TEMPLATE="debian13_k8s_node_template"
VM_PATH="/home/isidzukuri/second_ssd/qemu_kvm_vms"

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <number_of_vms> <start_from>"
  exit 1
fi

COUNT=$1
START=$2

for i in $(seq 0 $((COUNT-1))); do
  INDEX=$((START + i))
  VM_NAME="k8s-node-${INDEX}"
  DISK_PATH="$VM_PATH/${VM_NAME}.qcow2"

  echo ">>> Creating $VM_NAME"

  # Clone VM
  virt-clone --original "$TEMPLATE" --name "$VM_NAME" --auto-clone

  # Customize hostname and hosts file
  sudo guestfish -i -a "$DISK_PATH" <<EOF
write /etc/hostname "${VM_NAME}\n"
download /etc/hosts /tmp/hosts-${VM_NAME}
! sed -i "s/127.0.1.1.*/127.0.1.1\t${VM_NAME}/" /tmp/hosts-${VM_NAME}
upload /tmp/hosts-${VM_NAME} /etc/hosts
! rm /tmp/hosts-${VM_NAME}
EOF

  # Start VM
  virsh start "$VM_NAME"
done
