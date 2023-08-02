#!/bin/bash

# Set up a centos8 machine with the required environment to
# run the tests from https://github.com/samba-in-kubernetes/sit-test-cases.git
# and run the tests.

GIT_REPO_NAME="sit-environment"
GIT_REPO_URL="https://github.com/samba-in-kubernetes/${GIT_REPO_NAME}.git"
GIT_TARGET_REPO="${GIT_REPO}"
GIT_TARGET_REPO_URL="https://github.com/samba-in-kubernetes/${GIT_TARGET_REPO}.git"
BACKEND="${FILE_SYSTEM:-glusterfs}"
CENTOS_VERSION="${CENTOS_VERSION//[!0-9]}"
TEST_EXTRA_VARS=""
TEST_TARGET="test"

# if anything fails, we'll abort
set -e

# TODO: disable debugging
set -x

#
# === Phase 1 ============================================================
#
# Install git, fetch the git repo and possibly restart updated script if
# we are detecting that we are running on a PR that changes this script.
#

dnf -y install git

rm -rf tests
mkdir tests
cd tests
git clone "${GIT_REPO_URL}"
cd "${GIT_REPO_NAME}"

TEST_EXTRA_VARS="backend=${BACKEND}"
if [ "${GIT_TARGET_REPO}" = "sit-test-cases" ]; then
	if [ -n "${ghprbPullId}" ]; then
		# Just invoke "make test" with the corresponding parameters.
		TEST_EXTRA_VARS="${TEST_EXTRA_VARS} \
					test_repo=${GIT_TARGET_REPO_URL} \
					test_repo_pr=${ghprbPullId}"
	fi
else
	if [ -n "${ghprbPullId}" ]; then
		# Run sanity tests only for pull requests on sit-environment
		TEST_EXTRA_VARS="${TEST_EXTRA_VARS} test_sanity_only=1"

		git fetch origin "pull/${ghprbPullId}/head:pr_${ghprbPullId}"
		git checkout "pr_${ghprbPullId}"

		git rebase "origin/${ghprbTargetBranch}"
		if [ $? -ne 0 ] ; then
			echo "Unable to automatically rebase to branch '${ghprbTargetBranch}'. Please rebase your PR!"
			exit 1
		fi
	else
		echo "Skipping scheduled run"
		exit 0
	fi
fi

#
# === Phase 2 ============================================================
#
# Prepare the system:
# - install packages
# - start libvirt
# - prefetch vm image
#

# enable additional sources for dnf:
dnf -y install epel-release epel-next-release

dnf -y install make ansible-core ansible-collection-ansible-posix \
               ansible-collection-ansible-utils python3.11-netaddr

# Install QEMU-KVM and Libvirt packages
dnf -y install qemu-kvm qemu-img libvirt libvirt-devel

# "Development Tools" are needed to run "vagrant plugin install"
dnf -y group install "Development Tools"

# Use Fedora COPR maintained builds for vagrant and its dependencies
# including libvirt plugin instead of upstream version with added
# difficulty of rebuilding krb5 and libssh libraries.
dnf -y copr enable pvalena/vagrant
dnf -y install vagrant vagrant-libvirt rsync

# QEMU would require search permission inside root's home for accessing
# libvirt specific images under /root/.local/share/libvirt/images/
setfacl -m u:qemu:x /root/

# Vagrant needs libvirtd running
systemctl start libvirtd

# Log the virsh capabilites so that we know the
# environment in case something goes wrong.
virsh capabilities

#
# === Phase 3 ============================================================
#
# run the tests
#

EXTRA_VARS="${TEST_EXTRA_VARS}" make "${TEST_TARGET}"

# END
