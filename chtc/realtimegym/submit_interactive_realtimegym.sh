#!/bin/bash
# usage: ./submit_interactive_realtimegym.sh [n_gpu]
set -e
cp ../.env .env
source .env
mkdir -p logs/interactive
condor_submit -i job_i_realtimegym.sub n_gpu=${1:-1}
