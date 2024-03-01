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

#
# === Phase 1 ============================================================
#
# Install git and fetch the git repo.

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
		git fetch origin "pull/${ghprbPullId}/head:pr_${ghprbPullId}"
		git checkout "pr_${ghprbPullId}"

		git rebase "origin/${ghprbTargetBranch}"
		if [ $? -ne 0 ] ; then
			echo "Unable to automatically rebase to branch '${ghprbTargetBranch}'. Please rebase your PR!"
			exit 1
		fi
	fi

	TEST_EXTRA_VARS="${TEST_EXTRA_VARS} test_sanity_only=1"
fi

#
# === Phase 2 ============================================================
#
# Prepare the system:
# - install packages
# - start libvirt
#

# enable additional sources for dnf:
dnf -y install epel-release epel-next-release

dnf -y install make ansible-core

if [ "${CENTOS_VERSION}" -eq 8 ]; then
	dnf -y install python3.12-pip
	dnf -y install ansible-collection-ansible-posix \
		ansible-collection-ansible-utils
	pip3.12 install netaddr
else
	dnf config-manager --set-enabled crb
	dnf -y install python3-pip
	ansible-galaxy collection install ansible.posix ansible.utils
	pip3 install netaddr
fi


# Install QEMU-KVM and Libvirt packages
dnf -y install qemu-kvm qemu-img libvirt libvirt-devel

# Use Fedora COPR maintained builds for vagrant and its dependencies.
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

set +e

EXTRA_VARS="${TEST_EXTRA_VARS}" make "${TEST_TARGET}"
ret=$?

EXTRA_VARS="${TEST_EXTRA_VARS}" make statedump

pushd /tmp
find "sit_statedump" -name test.out -exec cp {} . \;
tar -zcvf "sit_statedump.tar.gz" "sit_statedump"
popd

exit $ret
# END
