#!/bin/bash

set -e
set -x
SCRIPT_BIN="$(basename $1)"
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$1" "root@$(cat $WORKSPACE/hosts):$SCRIPT_BIN"
