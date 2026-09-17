#!/bin/bash
# usage: ./submit_realtimegym.sh [runtag] [seeds]
# env overrides: MODEL GAME LOAD PRESSURE IBUDGET REPEATS MAXSTEPS AVOID_HOSTS
# DRY_RUN=1 validates the submit file into dryrun.txt without submitting
set -e
cp ../.env .env            # transfer_input_files needs it beside the .sub
source .env
TAG=${1:-vanilla}
mkdir -p logs/${TAG}
condor_submit ${DRY_RUN:+-dry-run dryrun.txt} job_realtimegym.sub \
  runtag=${TAG} \
  model="${MODEL:-Qwen/Qwen3-8B}" \
  game=${GAME:-freeway} \
  load=${LOAD:-M} \
  pressure=${PRESSURE:-4096} \
  ibudget=${IBUDGET:-2048} \
  seeds=${2:-8} \
  repeats=${REPEATS:-1} \
  maxsteps=${MAXSTEPS:-} \
  maxlen=${MAXLEN:-40960} \
  gpumem=${GPUMEM:-40000} \
  mode=${MODE:-agile} \
  planning_model="${PLANNING_MODEL:-${MODEL:-Qwen/Qwen3-8B}}" \
  reactive_model="${REACTIVE_MODEL:-${MODEL:-Qwen/Qwen3-8B}}" \
  reasoning_parser="${REASONING_PARSER-qwen3}" \
  model_tag="${MODEL_TAG:-qwen3-8b}" \
  avoid_hosts="${AVOID_HOSTS:-none}"
