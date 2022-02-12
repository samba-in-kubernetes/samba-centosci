#!/bin/bash

SINK_OPERATOR_GIT_REPO="https://github.com/samba-in-kubernetes/samba-operator"
SINK_OPERATOR_GIT_BRANCH=${SINK_OPERATOR_GIT_BRANCH:-"master"}
ghprbTargetBranch=${ghprbTargetBranch:-"$SINK_OPERATOR_GIT_BRANCH"}

ROOK_VERSION=${ROOK_VERSION:-"master"}
ROOK_DEPLOY_TIMEOUT=${ROOK_DEPLOY_TIMEOUT:-600}
ROOK_URL="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"

MINIKUBE_ARCH=${MINIKUBE_ARCH:-"amd64"}
MINIKUBE_VERSION=${MINIKUBE_VERSION:-"latest"}
KUBE_VERSION=${KUBE_VERSION:-"latest"}
CONTAINER_CMD=${CONTAINER_CMD:-"podman"}

VM_DRIVER=${VM_DRIVER:-"kvm2"}
NODE_COUNT=${NODE_COUNT:-"3"}
MEMORY=${MEMORY:-"4096"}
CPUS=${CPUS:-"2"}
NUM_DISKS=${NUM_DISKS:-"2"}
DISK_SIZE=${DISK_SIZE:-"10g"}
DISK_CONFIG=${DISK_CONFIG:-" --extra-disks=${NUM_DISKS} --disk-size=${DISK_SIZE}"}


CI_IMG_REGISTRY="registry-samba.apps.ocp.ci.centos.org"
CI_IMG_TAG="ci-k8s-${KUBE_VERSION}-run"

# kubelet.resolv-conf needs to point to a file, not a symlink
# the default minikube VM has /etc/resolv.conf -> /run/systemd/resolve/resolv.conf
RESOLV_CONF="/run/systemd/resolve/resolv.conf"
if [[ ! -e "${RESOLV_CONF}" ]]; then
	# in case /run/systemd/resolve/resolv.conf does not exist, use the
	# standard /etc/resolv.conf (with symlink resolved)
	RESOLV_CONF="$(readlink -f /etc/resolv.conf)"
fi

EXTRA_CONFIG="${EXTRA_CONFIG} --extra-config=kubelet.resolv-conf=${RESOLV_CONF}"

# Exit immediately if a command exits with non-zero status
set -e

set -x

dnf -y install epel-release

# Install basic tools
dnf -y install git make jq podman skopeo

# Install libvirt, QEMU-KVM and related packages
dnf -y install qemu-kvm qemu-img libvirt libvirt-devel socat conntrack

# Install go build environment
dnf -y install go

if [[ "${KUBE_VERSION}" == "latest" ]]; then
	# update the version string from latest with the real version
	KUBE_VERSION=$(curl -L https://storage.googleapis.com/kubernetes-release/release/stable.txt 2> /dev/null)
else
	KUBE_VERSION=$(curl -L https://api.github.com/repos/kubernetes/kubernetes/releases | \
			jq -r '.[].tag_name' | grep "${KUBE_VERSION}" | sort -V | tail -1)
fi

# Start libvrit daemon
systemctl enable --now libvirtd

# minikube wants the user to be in the libvirt group
getent group libvirt || groupadd --system libvirt
usermod -aG libvirt root

# Downlad and install minikube
curl -Lo minikube https://storage.googleapis.com/minikube/releases/"${MINIKUBE_VERSION}"/minikube-linux-"${MINIKUBE_ARCH}"
install minikube /usr/local/sbin/minikube

# Replace minikube's KVM driver with a custom compiled version
# https://github.com/kubernetes/minikube/issues/11459
curl -Lo docker-machine-driver-kvm2 https://anoopcs.fedorapeople.org/docker-machine-driver-kvm2
install docker-machine-driver-kvm2 /usr/local/sbin/docker-machine-driver-kvm2

# Download and install kubectl
curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/"${KUBE_VERSION}"/bin/linux/"${MINIKUBE_ARCH}"/kubectl
install kubectl /usr/local/sbin/kubectl

${CONTAINER_CMD} login --authfile=".podman-auth.json" \
	--username="${IMG_REGISTRY_AUTH_USR}" \
	--password="${IMG_REGISTRY_AUTH_PASSWD}" ${CI_IMG_REGISTRY}

${CONTAINER_CMD} pull --authfile=".podman-auth.json" \
	${CI_IMG_REGISTRY}/kindest/kindnetd:v20210326-1e038dc5 && \
	${CONTAINER_CMD} tag ${CI_IMG_REGISTRY}/kindest/kindnetd:v20210326-1e038dc5 \
	docker.io/kindest/kindnetd:v20210326-1e038dc5

# Start a kuberentes cluster using minikube
minikube start --force --driver="${VM_DRIVER}" --nodes="${NODE_COUNT}" \
	--memory="${MEMORY}" --cpus="${CPUS}" ${DISK_CONFIG} \
	-b kubeadm --kubernetes-version="${KUBE_VERSION}" ${EXTRA_CONFIG} \
	--delete-on-failure

minikube image load docker.io/kindest/kindnetd:v20210326-1e038dc5

for ((retry = 0; retry <= 20; retry = retry + 2)); do
	echo "Wait for basic k8s cluster ... ${retry}s" && sleep 2
	podstatus=$(kubectl -n kube-system get pod storage-provisioner \
			-o jsonpath='{.status.phase}')
	if [ "${podstatus}" = "Running" ]; then
		echo "Basic k8s cluster is up and running"
		break
	fi
done

if [ "${retry}" -gt 20 ]; then
	echo "Basic k8s cluster failed to come up (timeout)"
	exit 1
fi

kubectl cluster-info

# Configure nodes to authenticate to CI registry(copy config.json)
nodes=$(kubectl get nodes -o jsonpath='{range.items[*].metadata}{.name} {end}')
for n in $nodes; do
	cat < .podman-auth.json | ssh -o UserKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=no -i "$(minikube ssh-key -n "$n")" \
		-l docker "$(minikube ip -n "$n")" \
		"sudo tee /var/lib/kubelet/config.json > /dev/null";
done

# Git clone samba-operator repository
git clone --depth=1 --branch="${SINK_OPERATOR_GIT_BRANCH}" "${SINK_OPERATOR_GIT_REPO}"

pushd samba-operator
# Deploy basic test ad server
./tests/test-deploy-ad-server.sh


# Deploy ceph cluster using rook
TEMP_DIR="$(mktemp -d)"
curl -o "${TEMP_DIR}/crds.yaml" "${ROOK_URL}/crds.yaml"
curl -o "${TEMP_DIR}/common.yaml" "${ROOK_URL}/common.yaml"
curl -o "${TEMP_DIR}/operator.yaml" "${ROOK_URL}/operator.yaml"

kubectl create -f "${TEMP_DIR}/crds.yaml" \
		-f "${TEMP_DIR}/common.yaml" \
		-f "${TEMP_DIR}/operator.yaml"

curl -o "${TEMP_DIR}/cluster.yaml" "${ROOK_URL}/cluster.yaml"

# Use /data/rook as host path in case of minikube cluster
sed -i '/^ *dataDirHostPath/s/\/var\/lib\/rook/\/data\/rook/' "${TEMP_DIR}"/cluster.yaml

# Consume only extra added disks
sed -i '/^ *useAllDevices/s/true/false/' "${TEMP_DIR}"/cluster.yaml
dev_lst="\    devices:\n      - name: \"vdb\"\n      - name: \"vdc\""
sed -i "/^ *useAllDevices/a ${dev_lst}" "${TEMP_DIR}"/cluster.yaml

kubectl create -f "${TEMP_DIR}/cluster.yaml"


# Wait for Ceph cluster to be HEALTHY
for ((retry = 0; retry <= ROOK_DEPLOY_TIMEOUT; retry = retry + 10)); do
	echo "Wait for rook deploy... ${retry}s" && sleep 10
	CEPH_STATE=$(kubectl -n rook-ceph get cephclusters \
			-o jsonpath='{.items[0].status.state}')
	CEPH_HEALTH=$(kubectl -n rook-ceph get cephclusters \
			-o jsonpath='{.items[0].status.ceph.health}')
	echo "Checking Ceph cluster state: [$CEPH_STATE]"
	if [ "$CEPH_STATE" = "Created" ]; then
		if [ "$CEPH_HEALTH" = "HEALTH_OK" ]; then
			echo "Creating Ceph cluster is done. [$CEPH_HEALTH]"
			break
		fi
	fi
done

if [ "${retry}" -gt "$ROOK_DEPLOY_TIMEOUT" ]; then
	echo "Ceph cluster not in a healthy state (timeout)"
	exit 1
fi

# Install required Ceph tools
curl -o "${TEMP_DIR}/toolbox.yaml" "${ROOK_URL}/toolbox.yaml"
curl -o "${TEMP_DIR}/pool.yaml" "${ROOK_URL}/pool.yaml"
curl -o "${TEMP_DIR}/filesystem.yaml" "${ROOK_URL}/filesystem.yaml"

kubectl create -f "${TEMP_DIR}/toolbox.yaml" \
		-f "${TEMP_DIR}/pool.yaml" \
		-f "${TEMP_DIR}/filesystem.yaml"

# Install and make Ceph filesystem storage class the default
curl -o "${TEMP_DIR}/storageclass.yaml" "${ROOK_URL}/csi/cephfs/storageclass.yaml"

kubectl create -f "${TEMP_DIR}/storageclass.yaml"
kubectl patch storageclass rook-cephfs \
	-p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl patch storageclass standard \
	-p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

kubectl get pods -A

if [ -n "${ghprbPullId}" ]; then
	# We have to fetch the whole target branch to be able to rebase.
	git fetch --unshallow  origin

	git fetch origin "pull/${ghprbPullId}/head:pr_${ghprbPullId}"
	git checkout "pr_${ghprbPullId}"

	git rebase "origin/${ghprbTargetBranch}"
	ret=$?
	if [ $ret -ne 0 ] ; then
		echo "Unable to automatically rebase to \
			branch '${ghprbTargetBranch}'. Please rebase your PR!"
		exit 1
	fi

	CI_IMG_TAG="ci-k8s-${KUBE_VERSION}-pr${ghprbPullId}"
fi

${CONTAINER_CMD} pull --authfile="../.podman-auth.json" \
	${CI_IMG_REGISTRY}/golang:1.17 && ${CONTAINER_CMD} tag \
	${CI_IMG_REGISTRY}/golang:1.17 docker.io/golang:1.17

# Build and push samba-operator image to CI registry
IMG="${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}" make image-build
"${CONTAINER_CMD}" push --authfile="../.podman-auth.json" \
	"${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}"

# Enable experimental CTDB support
make kustomize
pushd config/default
../../.bin/kustomize edit add configmap controller-cfg --behavior=merge \
	--from-literal="SAMBA_OP_CLUSTER_SUPPORT=ctdb-is-experimental"
sed -i '$a\  namespace: system' kustomization.yaml
popd

# Finally, deploy
IMG="${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}" make deploy

for ((retry = 0; retry <= 60; retry = retry + 2)); do
	echo "Wait for operator deployment... ${retry}s" && sleep 2
	podstatus=$(kubectl -n samba-operator-system get pod \
			-l control-plane=controller-manager \
			-o jsonpath='{.items[0].status.phase}')
	kubectl -n samba-operator-system rollout status \
		deployment samba-operator-controller-manager
	deployment_status=$?
	if [ "${podstatus}" = "Running" ]; then
		if [ "${deployment_status}" -eq 0 ]; then
			echo "Operator deployed successfully"
			break
		fi
	fi
done

if [ "${retry}" -gt 60 ]; then
	echo "Operator deployment (timeout)"
	exit 1
fi

make delete-deploy

popd

# Mark current operator image for deletion from CI registry
skopeo delete --authfile=".podman-auth.json" \
	"docker://${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}"

# Teardown ceph cluster
kubectl delete -f "${TEMP_DIR}/storageclass.yaml"
kubectl delete -f "${TEMP_DIR}/toolbox.yaml" -f "${TEMP_DIR}/pool.yaml" -f "${TEMP_DIR}/filesystem.yaml"
kubectl delete -f "${TEMP_DIR}/cluster.yaml"
kubectl delete -f "${TEMP_DIR}/crds.yaml" -f "${TEMP_DIR}/common.yaml" -f "${TEMP_DIR}/operator.yaml"

rm -rf "${TEMP_DIR}"

# Delete minikube cluster
minikube delete

set +x
