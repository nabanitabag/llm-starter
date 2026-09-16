#!/bin/zsh
if [ -f .env ]; then
    set -a          # export all variables
    source .env
    set +a
else
    echo "Error: .env file missing from chtc/ directory. Please copy .env.template to .env and fill in the values."
    exit 1
fi

USER=${CHTC_USER}
HOSTNAME="ap2001.chtc.wisc.edu"
echo "Attempting to login as: ${USER} to ${HOSTNAME}"
ssh ${USER}@${HOSTNAME}