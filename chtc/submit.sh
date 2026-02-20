# make a temp commands file where spaces are replaced with * so that multi-word commands are properly parsed by the queue command
commands_file=commands/${1}.txt
commands_file_tmp=commands/${1}_tmp.txt
sed 's/ /*/g' "$commands_file" > "$commands_file_tmp"

# make directory to store results and logs
results_dir=results/${1}
log_dir=logs/${1}
mkdir -p ${results_dir}
mkdir -p ${log_dir}

condor_submit job.sub \
  results_dir=${results_dir} \
  log_dir=${log_dir} \
  commands_file=${commands_file_tmp} \
  num_jobs=${2:-1} \
  chtc_user=${CHTC_USER}

# remove temp commands file
rm $commands_file_tmp
