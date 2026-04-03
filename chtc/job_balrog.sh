#!/bin/bash
set -e
source .env
pid=$1  # ranges from 0 to num_commands*num_jobs-1 
step=$2 # ranges from 0 to num_jobs-1
#cmd=`tr '*' ' ' <<< $3` # replace * with space
#echo $cmd

export HOME=$_CONDOR_SCRATCH_DIR
export TRANSFORMERS_CACHE=$_CONDOR_SCRATCH_DIR/models
export HF_DATASETS_CACHE=$_CONDOR_SCRATCH_DIR/datasets
export HF_MODULES_CACHE=$_CONDOR_SCRATCH_DIR/modules
export HF_METRICS_CACHE=$_CONDOR_SCRATCH_DIR/metrics
export HF_HOME=$_CONDOR_SCRATCH_DIR/hf_home

export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 # on CHTC machines, gpu names are *not* the usual 0-7 by default, so we rename them here
export TORCHINDUCTOR_CACHE_DIR=$_CONDOR_SCRATCH_DIR/torch_cache
export TORCH_COMPILE_CACHE=$_CONDOR_SCRATCH_DIR/torch_compile_cache
export XDG_CACHE_HOME=$_CONDOR_SCRATCH_DIR/xdg_cache
export XDG_CONFIG_HOME=$_CONDOR_SCRATCH_DIR/xdg_config
export _USAGE_STATS_JSON_PATH=$_CONDOR_SCRATCH_DIR/vllm_usage
export VLLM_USAGE_DISABLE=1

export VLLM_ATTENTION_BACKEND=FLASH_ATTN
export NCCL_P2P_DISABLE=1
export OUTLINES_CACHE_DIR='/tmp/.outlines'
export USER="nbag"
export RAY_TMPDIR=/tmp/ray_$USER
export CXXFLAGS="-std=c++17"

# Transfer Verlog and BALROG instead of open source verl
echo "Fetching Verlog and BALROG from /staging/${USER}..."
cp /staging/${USER}/Verlog.tar.gz .
tar -xzf Verlog.tar.gz
cd Verlog
python3.12 -m pip install -e .
python3.12 -m pip install packaging ray
cd ..

if [ -f "/staging/${USER}/BALROG.tar.gz" ]; then
    cp "/staging/${USER}/BALROG.tar.gz" .
    tar -xzf BALROG.tar.gz
    cd BALROG
    export CXXFLAGS="-std=c++17"
    pip install -e .
    cd ..
fi

echo "Installing llm-starter components..."
cp /staging/${USER}/llm-starter.tar.gz .
tar -xzf llm-starter.tar.gz
cd llm-starter

echo "Running exploratory BALROG script..."
PYTHONUNBUFFERED=1 python3 explore_balrog.py 2>&1 | tee balrog_demo.log