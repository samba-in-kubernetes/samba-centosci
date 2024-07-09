#!/bin/bash

scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "root@$(cat $WORKSPACE/hosts):/tmp/{test.out,*.tar.gz}" .
