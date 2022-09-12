#!/bin/bash

# Set up a centos8 machine with the required environment to
# run the tests from https://github.com/gluster/samba-integration.git
# and run the tests.

GIT_REPO_NAME="samba-integration"
GIT_REPO_URL="https://github.com/gluster/${GIT_REPO_NAME}.git"
TESTS_GIT_BRANCH="tests"
CENTOS_VERSION="${CENTOS_VERSION//[!0-9]}"
TEST_EXTRA_VARS=""
TEST_TARGET="test"
SCRIPT_GIT_BRANCH="centos-ci"
SCRIPT_NAME="$(basename $0)"
SCRIPT_PATH="$(realpath $0)"

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

# by default we clone the master branch, but maybe this was triggered through a PR?
if [ -n "${ghprbPullId}" ]
then
	if [ "${ghprbTargetBranch}" = "${TESTS_GIT_BRANCH}" ]; then
		# A PR against the tests branch:
		# Just invoke "make test" from master with the corresponding
		# parameters.
		TEST_EXTRA_VARS="test_repo=${GIT_REPO_URL} test_repo_pr=${ghprbPullId}"
	else
		git fetch origin "pull/${ghprbPullId}/head:pr_${ghprbPullId}"
		git checkout "pr_${ghprbPullId}"

		git rebase "origin/${ghprbTargetBranch}"
		if [ $? -ne 0 ] ; then
		    echo "Unable to automatically rebase to branch '${ghprbTargetBranch}'. Please rebase your PR!"
		    exit 1
		fi
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

dnf -y install make ansible-core ansible-collection-ansible-posix

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

# Prefetch the centos/8 vagrant box.
# We use the vagrant cloud rather than fetching directly from centos
# in order to get proper version metadata & caching support.
# (The echo is becuase of "set -e" and that an existing box will cause
#  vagrant to return non-zero.)
vagrant box add "https://vagrantcloud.com/centos/8" --provider "libvirt" \
	|| echo "Warning: the vagrant box may already exist OR an error occured"

#
# === Phase 3 ============================================================
#
# run the tests
#

EXTRA_VARS="${TEST_EXTRA_VARS}" make "${TEST_TARGET}"

# END
