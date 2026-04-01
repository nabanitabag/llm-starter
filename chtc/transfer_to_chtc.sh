#!/bin/bash
source .env

f=Verlog
USER=${CHTC_USER}
HOSTNAME="ap2001.chtc.wisc.edu"

cd ../.. # cd just outside the repo

# Establish persistent SSH connection (ask password once)
echo "Establishing SSH connection..."
ssh -o ControlMaster=auto -o ControlPath=~/.ssh/control-%r@%h:%p -o ControlPersist=10m -fN ${USER}@${HOSTNAME}

# 1. Create the tarballs
tar --exclude='.git' \
    --exclude='.idea'  \
    --no-xattrs \
    -czvf ${f}.tar.gz $f

# Also tar BALROG if it exists
if [ -d "../../BALROG" ]; then
    echo "Packaging BALROG..."
    tar --exclude='.git' --no-xattrs -czvf BALROG.tar.gz -C ../.. BALROG
fi

echo "============================================"
echo "1. Transferring tarballs to CHTC Staging..."
echo "============================================"
scp -o ControlPath=~/.ssh/control-%r@%h:%p ${f}.tar.gz ${USER}@${HOSTNAME}:/staging/${USER}/
if [ -f "BALROG.tar.gz" ]; then
    scp -o ControlPath=~/.ssh/control-%r@%h:%p BALROG.tar.gz ${USER}@${HOSTNAME}:/staging/${USER}/
fi

echo "============================================"
echo "2. Syncing chtc folder to CHTC Home directory..."
echo "============================================"
rsync -avz -e "ssh -o ControlPath=~/.ssh/control-%r@%h:%p" ${f}/chtc ${USER}@${HOSTNAME}:~/${f}/

# Clean up
rm ${f}.tar.gz
rm -f BALROG.tar.gz

# Close SSH connection
ssh -O exit -o ControlPath=~/.ssh/control-%r@%h:%p ${USER}@${HOSTNAME} 2>/dev/null

echo "Transferred at $(date '+%Y-%m-%d %H:%M:%S'). Done!"