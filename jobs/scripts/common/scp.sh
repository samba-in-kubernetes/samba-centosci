set +x
scp -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /duffy-ssh-key/ssh-privatekey root@$(cat $WORKSPACE/hosts):
ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$(cat $WORKSPACE/hosts) "chmod 0600 ~/ssh-privatekey"
