#!/bin/bash
# A script that releases nodes from session ids

SESSION_ID=$(cat "${WORKSPACE}"/session_id)

duffy client retire-session "${SESSION_ID}" > /dev/null
