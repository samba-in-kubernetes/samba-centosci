#!/bin/bash

SINK_OPERATOR_GIT_REPO="https://github.com/samba-in-kubernetes/samba-operator"
SINK_OPERATOR_GIT_BRANCH=${SINK_OPERATOR_GIT_BRANCH:-"master"}

KUBE_VERSION=${KUBE_VERSION:-"latest"}
CONTAINER_CMD=${CONTAINER_CMD:-"podman"}

# Exit immediately if a command exits with non-zero status
set -e

source sink-common.sh

CI_IMG_REGISTRY="registry-samba.apps.ocp.ci.centos.org"
CI_IMG_TAG="ci-k8s-${KUBE_VERSION}-run"

${CONTAINER_CMD} login --authfile=".podman-auth.json" \
	--username="${IMG_REGISTRY_AUTH_USR}" \
	--password="${IMG_REGISTRY_AUTH_PASSWD}" ${CI_IMG_REGISTRY}

setup_minikube

deploy_rook

image_pull ${CI_IMG_REGISTRY} "docker.io" "golang:1.17"

# Git clone samba-operator repository
git clone --depth=1 --branch="${SINK_OPERATOR_GIT_BRANCH}" "${SINK_OPERATOR_GIT_REPO}"

pushd samba-operator
# Deploy basic test ad server
./tests/test-deploy-ad-server.sh

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

echo "Wait for operator deployment..."
for ((retry = 0; retry <= 60; retry = retry + 2)); do
	podstatus=$(kubectl -n samba-operator-system get pod \
			-l control-plane=controller-manager \
			-o jsonpath='{.items[0].status.phase}')
	kubectl -n samba-operator-system rollout status \
		deployment samba-operator-controller-manager
	deployment_status=$?
	if [ "${podstatus}" = "Running" ]; then
		if [ "${deployment_status}" -eq 0 ]; then
			echo "Operator deployed successfully [${retry}s]"
			break
		fi
	fi

	sleep 2
	echo -n "."
done

if [ "${retry}" -gt 60 ]; then
	echo "Operator deployment failed (timeout: 60s)"
	exit 1
fi

kubectl get pods -A

kubectl -n kube-system describe pod storage-provisioner

make delete-deploy

popd

# Mark current operator image for deletion from CI registry
skopeo delete --authfile=".podman-auth.json" \
	"docker://${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}"

teardown_rook

destroy_minikube

exit 0
