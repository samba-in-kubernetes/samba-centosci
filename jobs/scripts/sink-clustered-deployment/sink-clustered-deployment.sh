#!/bin/bash

SINK_OPERATOR_GIT_REPO="https://github.com/samba-in-kubernetes/samba-operator"
SINK_OPERATOR_GIT_BRANCH=${SINK_OPERATOR_GIT_BRANCH:-"master"}

KUBE_VERSION=${KUBE_VERSION:-"latest"}
CONTAINER_CMD=${CONTAINER_CMD:-"podman"}

CI_IMG_REGISTRY="registry-samba.apps.ocp.ci.centos.org"
CI_IMG_TAG="ci-k8s-${KUBE_VERSION}-run"

# Exit immediately if a command exits with non-zero status
set -e

dnf -y install git podman skopeo

${CONTAINER_CMD} login --authfile=".podman-auth.json" \
	--username="${IMG_REGISTRY_AUTH_USR}" \
	--password="${IMG_REGISTRY_AUTH_PASSWD}" ${CI_IMG_REGISTRY}

REGISTRY_AUTH_FILE="$(readlink -f .podman-auth.json)"

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

	skip=0
	declare -a SKIP_FILES=(^docs/ .md$ LICENSE .codespellignore \
				.codespellrc .github .gitignore .golangci.yaml \
				.revive.toml .yamllint.yaml)

	readarray FILES_CHANGED < <(git diff --name-only origin/"${ghprbTargetBranch}")

	for i in "${FILES_CHANGED[@]}"
	do
		for j in "${SKIP_FILES[@]}"
		do
			if ! [[ "$i" =~ "$j" ]]; then
				skip=1
			fi
		done
	done

	if [ ${skip} -eq 0 ]; then
		echo "Doc/Format-Spec only change, skipping..."
		exit 0
	fi

	CI_IMG_TAG="ci-k8s-${KUBE_VERSION}-pr${ghprbPullId}"
fi

CI_IMG_OP="${CI_IMG_REGISTRY}/sink/samba-operator:${CI_IMG_TAG}"

export CONTAINER_CMD REGISTRY_AUTH_FILE CI_IMG_REGISTRY CI_IMG_OP

./tests/centosci/sink-clustered-deployment.sh

# Mark current operator image for deletion from CI registry
skopeo delete "docker://${CI_IMG_OP}"

popd || exit 1

exit 0
