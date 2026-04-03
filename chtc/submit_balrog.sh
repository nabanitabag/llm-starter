# make directory to store results and logs
results_dir=results/${1:-balrog_test}
log_dir=logs/${1:-balrog_test}
mkdir -p ${results_dir}
mkdir -p ${log_dir}

condor_submit job_balrog.sub \
  results_dir=${results_dir} \
  log_dir=${log_dir}
