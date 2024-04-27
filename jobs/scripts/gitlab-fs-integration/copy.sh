#!/bin/bash

set -e
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "root@$(cat $WORKSPACE/hosts):/tmp/{test.out,*.tar.gz}" .
