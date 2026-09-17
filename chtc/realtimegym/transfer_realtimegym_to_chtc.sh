#!/bin/bash
# Package a CLEAN checkout of a RealtimeGym branch (default: main) and ship it
# to /staging. Uses `git archive`, so your local working tree and current
# branch are never touched. The untracked chtc-*.yaml configs are added on top.
set -e
source ../.env

BRANCH=${BRANCH:-main}
f=RealtimeGym
USER=${CHTC_USER}
HOSTNAME="ap2001.chtc.wisc.edu"

cd ../../..   # -> the directory holding both RealtimeGym/ and llm-starter/

echo "Packaging ${f} @ ${BRANCH} (working tree untouched)..."
rm -rf .rtg_pack && mkdir -p .rtg_pack/${f}
git -C ${f} archive ${BRANCH} | tar -x -C .rtg_pack/${f}
# configs are untracked, so git archive won't have them
cp ${f}/configs/chtc-*.yaml .rtg_pack/${f}/configs/
tar --no-xattrs -czf ${f}.tar.gz -C .rtg_pack ${f}
rm -rf .rtg_pack
echo "  packaged $(du -h ${f}.tar.gz | cut -f1)"

echo "Establishing SSH connection..."
ssh -o ControlMaster=auto -o ControlPath=~/.ssh/control-%r@%h:%p -o ControlPersist=10m -fN ${USER}@${HOSTNAME}

echo "Transferring to /staging/n/${USER}/ ..."
scp -o ControlPath=~/.ssh/control-%r@%h:%p ${f}.tar.gz ${USER}@${HOSTNAME}:/staging/n/${USER}/

# Also drop the job script into /staging so a RUNNING interactive job can
# pull the latest copy without re-queuing.
echo "Copying job_realtimegym.sh to staging..."
scp -o ControlPath=~/.ssh/control-%r@%h:%p \
    llm-starter/chtc/realtimegym/job_realtimegym.sh \
    ${USER}@${HOSTNAME}:/staging/n/${USER}/

echo "Syncing chtc scripts to home..."
rsync -avz -e "ssh -o ControlPath=~/.ssh/control-%r@%h:%p" llm-starter/chtc ${USER}@${HOSTNAME}:~/llm-starter/

rm ${f}.tar.gz
ssh -O exit -o ControlPath=~/.ssh/control-%r@%h:%p ${USER}@${HOSTNAME} 2>/dev/null
echo "Transferred ${f}@${BRANCH} at $(date '+%Y-%m-%d %H:%M:%S'). Done!"
