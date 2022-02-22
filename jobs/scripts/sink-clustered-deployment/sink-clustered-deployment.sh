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

REGISTRY_AUTH_FILE="$(readlink -f .podman-auth.json)"
export REGISTRY_AUTH_FILE

setup_minikube

deploy_rook

image_pull ${CI_IMG_REGISTRY} "docker.io" "golang:1.17"

# Git clone samba-operator repository
git clone --depth=1 --branch="${SINK_OPERATOR_GIT_BRANCH}" "${SINK_OPERATOR_GIT_REPO}"

pushd samba-operator || exit 1

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

CI_IMG_OP="${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}"

# Build and push operator image to local CI registry
IMG="${CI_IMG_OP}" make image-build
IMG="${CI_IMG_OP}" make container-push

install_kustomize

#enable_ctdb

deploy_op

kubectl get pods -A

IMG="${CI_IMG_OP}" make test

# Deploy basic test ad server
./tests/test-deploy-ad-server.sh

# Run integration tests
SMBOP_TEST_EXPECT_MANAGER_IMG="${CI_IMG_OP}" ./tests/test.sh

teardown_op

popd || exit 1

# Mark current operator image for deletion from CI registry
skopeo delete "docker://${CI_IMG_OP}"

teardown_rook

destroy_minikube

exit 0
