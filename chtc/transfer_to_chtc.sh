f=llm-starter

cd ../.. # cd just outside the repo
tar --exclude='.git' \
    --exclude='.idea'  \
    -czvf ${f}.tar.gz $f

USER="ncorrado"
HOSTNAME="ap2001.chtc.wisc.edu"
scp ${f}.tar.gz ${USER}@${HOSTNAME}:/staging/${USER}
rm ${f}.tar.gz