#!/bin/bash
# A script that reserve nodes from pool

mkdir -p ~/.config

cat > ~/.config/duffy <<EOF
client:
  url: https://duffy.ci.centos.org/api/v1
  auth:
    name: samba
    key: ${CICO_API_KEY}
EOF

if [[ "${JOB_NAME}" =~ rpms|containers ]]; then
	POOL_MATCH="^(virt-ec2)(.*)(centos-${CENTOS_VERSION}-${OS_ARCH})$"
else
	POOL_MATCH="^(metal-ec2)(.*)(centos-${CENTOS_VERSION}-${OS_ARCH})$"
fi

readarray -t POOLS < <(duffy client list-pools | jq -r '.pools[].name')

for i in "${POOLS[@]}"
do
	if [[ $i =~ ${POOL_MATCH} ]]; then
		POOL_FOUND=$i
		break
	fi
done

if [ -z "${POOL_FOUND}" ]; then
	echo "No matching pool found"
	exit 1
fi

for i in {1..30}
do
	NODES_READY=$(duffy client show-pool "${POOL_FOUND}" | jq -r '.pool.levels.ready')
	if [ "${NODES_READY}" -ge 1 ]; then
		SESSION=$(duffy client request-session pool="${POOL_FOUND}",quantity=1)
		echo "${SESSION}" | jq -r '.session.nodes[].ipaddr' > "${WORKSPACE}"/hosts
		echo "${SESSION}" | jq -r '.session.id' > "${WORKSPACE}"/session_id
		break
	fi

	sleep 60
	echo -n "."
done

if [ -z "${SESSION}" ]; then
	echo "Failed to reserve node"
	exit 1
fi
