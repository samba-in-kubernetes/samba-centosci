#!/bin/bash
# A script that releases nodes from session ids

if [ ! -f "${WORKSPACE}/session_id" ]; then
	echo "No session_id file found, skipping node return"
	exit 0
fi

SESSION_ID=$(cat "${WORKSPACE}"/session_id)

if [ -z "${SESSION_ID}" ]; then
	echo "Empty session_id, skipping node return"
	exit 0
fi

duffy client retire-session "${SESSION_ID}" > /dev/null
