#!/bin/bash

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
export RAY_TMPDIR=/tmp/ray_$USER

# fetch code from /staging/
CODENAME=llm-starter
USER=ncorrado
cp /staging/${USER}/${CODENAME}.tar.gz .
tar -xzf ${CODENAME}.tar.gz
rm ${CODENAME}.tar.gz
cd ${CODENAME}

#wandb login <your wandb key>
#huggingface-cli login --token <your hf token>

export PYTHONPATH=.:$PYTHONPATH
git clone https://github.com/verl-project/verl.git -b v0.7.0
pip install -e verl

# You can pass a string containing a general python command to execute here
#$cmd

# make gsm8k dataset
python3 verl/examples/data_preprocess/gsm8k.py --local_save_dir ~/data/gsm8k

PYTHONUNBUFFERED=1 python3 -m verl.trainer.main_ppo \
  data.train_files=$HOME/data/gsm8k/train.parquet \
  data.val_files=$HOME/data/gsm8k/test.parquet \
  data.train_batch_size=256 \
  data.max_prompt_length=512 \
  data.max_response_length=512 \
  actor_rollout_ref.model.path=Qwen/Qwen2.5-0.5B-Instruct \
  actor_rollout_ref.actor.optim.lr=1e-6 \
  actor_rollout_ref.actor.ppo_mini_batch_size=64 \
  actor_rollout_ref.actor.ppo_micro_batch_size_per_gpu=4 \
  actor_rollout_ref.rollout.name=vllm \
  actor_rollout_ref.rollout.log_prob_micro_batch_size_per_gpu=8 \
  actor_rollout_ref.rollout.tensor_model_parallel_size=1 \
  actor_rollout_ref.rollout.gpu_memory_utilization=0.4 \
  actor_rollout_ref.ref.log_prob_micro_batch_size_per_gpu=4 \
  critic.optim.lr=1e-5 \
  critic.model.path=Qwen/Qwen2.5-0.5B-Instruct \
  critic.ppo_micro_batch_size_per_gpu=4 \
  algorithm.kl_ctrl.kl_coef=0.001 \
  trainer.logger=console \
  trainer.val_before_train=False \
  trainer.n_gpus_per_node=1 \
  trainer.nnodes=1 \
  trainer.save_freq=10 \
  trainer.test_freq=10 \
  trainer.total_epochs=15 2>&1 | tee verl_demo.log