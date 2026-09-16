#!/bin/bash
# usage: ./submit_realtimegym.sh [runtag] [seeds]
# env overrides: MODEL GAME LOAD PRESSURE IBUDGET REPEATS MAXSTEPS
set -e
cp ../.env .env            # transfer_input_files needs it beside the .sub
source .env
TAG=${1:-vanilla}
mkdir -p logs/${TAG}
condor_submit job_realtimegym.sub \
  runtag=${TAG} \
  model="${MODEL:-Qwen/Qwen3-8B}" \
  game=${GAME:-freeway} \
  load=${LOAD:-M} \
  pressure=${PRESSURE:-4096} \
  ibudget=${IBUDGET:-2048} \
  seeds=${2:-8} \
  repeats=${REPEATS:-1} \
  maxsteps=${MAXSTEPS:-}
