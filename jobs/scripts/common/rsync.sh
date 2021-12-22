set +x
ssh -t -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$(cat $WORKSPACE/hosts) "echo ${CICO_API_KEY} > ~/rsync.passwd"
ssh -t -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$(cat $WORKSPACE/hosts) "chmod 0600 ~/rsync.passwd"
