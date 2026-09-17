#!/bin/bash
# Submit one Llama-family cell.
#   reactive thread: meta-llama/Llama-3.1-8B-Instruct
#   planning thread: deepseek-ai/DeepSeek-R1-Distill-Llama-8B
#
# usage: ./submit_llama.sh <agile|reactive|planning> <E|M|H> [pressure] [seeds]
#   ./submit_llama.sh agile E
#   ./submit_llama.sh planning M 8192
#
# Runs as its own process, so none of these settings leak into your shell and
# turn a later Qwen submit into a Llama one.
set -e
MODE_ARG=${1:?mode: agile|reactive|planning}
LOAD_ARG=${2:?load: E|M|H}
PRESSURE_ARG=${3:-4096}
SEEDS_ARG=${4:-8}

export PLANNING_MODEL=deepseek-ai/DeepSeek-R1-Distill-Llama-8B
export REACTIVE_MODEL=meta-llama/Llama-3.1-8B-Instruct
export REASONING_PARSER=
export MODEL_TAG=llama3.1-8b
export MODE=${MODE_ARG} LOAD=${LOAD_ARG} PRESSURE=${PRESSURE_ARG}

case "${MODE_ARG}" in
  agile)    export GPUMEM=78000 ;;              # two 8B models on one card
  reactive) export IBUDGET=4096 ;;              # full step budget, as for Qwen
  planning) ;;                                  # IBUDGET forced to 0 by the job
  *) echo "unknown mode ${MODE_ARG}"; exit 1 ;;
esac

TAG=llama_${MODE_ARG}_${LOAD_ARG}
[ "${PRESSURE_ARG}" != "4096" ] && TAG=${TAG}_${PRESSURE_ARG}
echo "submitting ${TAG}"
./submit_realtimegym.sh "${TAG}" "${SEEDS_ARG}"
