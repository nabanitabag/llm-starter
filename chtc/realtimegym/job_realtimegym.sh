#!/bin/bash
# RealtimeGym vanilla baseline on CHTC: one GPU, one vLLM server,
# N eval processes hitting it concurrently (vLLM batches them).
set -e
source .env

# ---- knobs (override by exporting before running) -------------------------
MODEL=${MODEL:-Qwen/Qwen3-8B}
GAME=${GAME:-freeway}
LOAD=${LOAD:-M}
PRESSURE=${PRESSURE:-4096}
IBUDGET=${IBUDGET:-2048}
SEEDS=${SEEDS:-8}
REPEATS=${REPEATS:-1}
MAXSTEPS=${MAXSTEPS:-}          # empty = full episodes; set for smoke tests
PORT=${PORT:-8000}
RUNTAG=${RUNTAG:-vanilla}

# ---- caches into scratch so nothing lands in $HOME -------------------------
export HOME=$_CONDOR_SCRATCH_DIR
export HF_HOME=$_CONDOR_SCRATCH_DIR/hf_home
export XDG_CACHE_HOME=$_CONDOR_SCRATCH_DIR/xdg_cache
export XDG_CONFIG_HOME=$_CONDOR_SCRATCH_DIR/xdg_config
export TORCHINDUCTOR_CACHE_DIR=$_CONDOR_SCRATCH_DIR/torch_cache
export OUTLINES_CACHE_DIR=/tmp/.outlines
export VLLM_USAGE_DISABLE=1
export _USAGE_STATS_JSON_PATH=$_CONDOR_SCRATCH_DIR/vllm_usage
export USER=${CHTC_USER}

# headless: pygame is imported unconditionally by agile_eval
export SDL_VIDEODRIVER=dummy
# ProcessPoolExecutor forks after tokenizers load; silence the deadlock warning
export TOKENIZERS_PARALLELISM=false
export PYTHONUNBUFFERED=1

# CHTC sets CUDA_VISIBLE_DEVICES to GPU UUIDs (GPU-20e62ffc-...), but vLLM does
# int() on it and dies. Map each assigned UUID to its nvidia-smi index so we keep
# the GPU HTCondor actually gave us instead of blindly grabbing device 0.
if [[ "${CUDA_VISIBLE_DEVICES}" == GPU-* ]]; then
  echo "Remapping CUDA_VISIBLE_DEVICES from UUID(s): ${CUDA_VISIBLE_DEVICES}"
  _idx=""
  for _uuid in ${CUDA_VISIBLE_DEVICES//,/ }; do
    _i=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader \
         | grep -F "${_uuid}" | cut -d, -f1 | tr -d ' ')
    [ -n "${_i}" ] && _idx="${_idx}${_idx:+,}${_i}"
  done
  if [ -n "${_idx}" ]; then
    export CUDA_VISIBLE_DEVICES="${_idx}"
    echo "  -> CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
  else
    echo "  !! could not map UUID to index; falling back to 0"
    export CUDA_VISIBLE_DEVICES=0
  fi
fi

# ---- fetch code -----------------------------------------------------------
cd $_CONDOR_SCRATCH_DIR
# /staging is sharded by first letter of username: /staging/n/nbag
STAGING=${STAGING:-/staging/$(echo ${USER} | cut -c1)/${USER}}
echo "Fetching RealtimeGym from ${STAGING}/ ..."
if [ ! -f "${STAGING}/RealtimeGym.tar.gz" ]; then
  echo "!! No RealtimeGym.tar.gz in ${STAGING}"
  echo "   Contents:"; ls -la ${STAGING} 2>&1 | head -20
  echo "   Fix: re-run transfer_realtimegym_to_chtc.sh on your laptop."
  exit 1
fi
cp ${STAGING}/RealtimeGym.tar.gz .
tar -xzf RealtimeGym.tar.gz
rm RealtimeGym.tar.gz
cd RealtimeGym

# --no-deps: the container already has torch/transformers/vllm and letting pip
# resolve RealtimeGym's deps can upgrade torch out from under vLLM.
pip install --no-deps -e . 
pip install --no-deps pygame python-dotenv
python3 -c "import pandas, numpy, yaml, openai, transformers, pygame; print('deps ok')"
export PYTHONPATH=$(pwd)/src:$PYTHONPATH

# ---- start vLLM -----------------------------------------------------------
echo "Starting vLLM for ${MODEL} ..."
vllm serve ${MODEL} \
  --port ${PORT} \
  --reasoning-parser qwen3 \
  --max-model-len 40960 \
  --gpu-memory-utilization 0.90 \
  > $_CONDOR_SCRATCH_DIR/vllm.log 2>&1 &
VLLM_PID=$!
trap "echo 'stopping vllm'; kill ${VLLM_PID} 2>/dev/null || true" EXIT

echo "Waiting for vLLM to become healthy (model download may take a few minutes)..."
for i in $(seq 1 180); do
  if curl -sf http://localhost:${PORT}/health > /dev/null; then
    echo "vLLM healthy after $((i*10))s"; break
  fi
  if ! kill -0 ${VLLM_PID} 2>/dev/null; then
    echo "!! vLLM died during startup. Last 50 lines:"; tail -50 $_CONDOR_SCRATCH_DIR/vllm.log; exit 1
  fi
  sleep 10
done
curl -sf http://localhost:${PORT}/health > /dev/null || { echo "!! vLLM never came up"; tail -50 $_CONDOR_SCRATCH_DIR/vllm.log; exit 1; }

# ---- sanity: is the reasoning trace actually visible? ----------------------
echo "--- checking reasoning_content is populated ---"
curl -s http://localhost:${PORT}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think briefly.\"}],\"max_tokens\":200}" \
  | python3 -c "import sys,json; m=json.load(sys.stdin)['choices'][0]['message']; rc=m.get('reasoning_content'); print('reasoning_content:', (rc[:120]+'...') if rc else 'MISSING'); print('content:', (m.get('content') or '')[:120])"
echo "--- end check ---"

# ---- run the eval ---------------------------------------------------------
LOGDIR=logs/${RUNTAG}
EXTRA=""
if [ -n "${MAXSTEPS}" ]; then
  if python3 -m realtimegym.agile_eval --help 2>&1 | grep -q -- "--max_steps"; then
    EXTRA="--max_steps ${MAXSTEPS}"
  else
    echo "NOTE: this branch has no --max_steps (that flag is a gap3 addition). Ignoring MAXSTEPS=${MAXSTEPS}."
    echo "      For a quick check on main use SEEDS=1 PRESSURE=2048 IBUDGET=1024 and Ctrl-C once CSV rows appear."
  fi
fi

echo "Running: ${GAME} load=${LOAD} tp=${PRESSURE} ib=${IBUDGET} seeds=${SEEDS} repeats=${REPEATS} ${EXTRA}"
time python3 -m realtimegym.agile_eval \
  --game ${GAME} --cognitive_load ${LOAD} --mode agile \
  --time_pressure ${PRESSURE} --internal_budget ${IBUDGET} \
  --planning-model-config configs/chtc-qwen3-8b-planning.yaml \
  --reactive-model-config configs/chtc-qwen3-8b-reactive.yaml \
  --seed_num ${SEEDS} --repeat_times ${REPEATS} \
  --log_dir ${LOGDIR} ${EXTRA} 2>&1 | tee $_CONDOR_SCRATCH_DIR/eval.log

# ---- collect results ------------------------------------------------------
cd $_CONDOR_SCRATCH_DIR
tar -czf results_${RUNTAG}.tar.gz \
    -C RealtimeGym ${LOGDIR} \
    -C $_CONDOR_SCRATCH_DIR vllm.log eval.log
mkdir -p ${STAGING}/rtg_results
cp results_${RUNTAG}.tar.gz ${STAGING}/rtg_results/
echo "Results in ${STAGING}/rtg_results/results_${RUNTAG}.tar.gz"
