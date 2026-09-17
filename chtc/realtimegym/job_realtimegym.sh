#!/bin/bash
# RealtimeGym vanilla baseline on CHTC: one GPU, one vLLM server,
# N eval processes hitting it concurrently (vLLM batches them).
set -e
set -o pipefail   # otherwise `eval | tee` reports tee's status (0) and hides crashes
source .env

# ---- knobs (override by exporting before running) -------------------------
MODEL=${MODEL:-Qwen/Qwen3-8B}
# Two-model setups (the paper's main design: V3 reactive + R1 planning).
# Default: one model for both threads.
PLANNING_MODEL=${PLANNING_MODEL:-$MODEL}
REACTIVE_MODEL=${REACTIVE_MODEL:-$MODEL}
REASONING_PARSER=${REASONING_PARSER-qwen3}   # empty = no --reasoning-parser flag
MODEL_TAG=${MODEL_TAG:-$(basename ${PLANNING_MODEL})}
GAME=${GAME:-freeway}
LOAD=${LOAD:-M}
PRESSURE=${PRESSURE:-4096}
MODE=${MODE:-agile}       # agile | reactive | planning
IBUDGET=${IBUDGET:-2048}
# check_args() asserts internal_budget==0 for planning and >0 otherwise.
if [ "${MODE}" = "planning" ]; then
  IBUDGET=0
  echo "MODE=planning -> forcing IBUDGET=0 (required by check_args)"
fi
SEEDS=${SEEDS:-8}
REPEATS=${REPEATS:-1}
MAXSTEPS=${MAXSTEPS:-}          # empty = full episodes; set for smoke tests
MAXLEN=${MAXLEN:-40960}    # lower this for big models (KV cache)
PORT=${PORT:-8000}
RUNTAG=${RUNTAG:-vanilla}

# ---- full transcript ------------------------------------------------------
RUN_LOG=${_CONDOR_SCRATCH_DIR:-/tmp}/run_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "${RUN_LOG}") 2>&1
echo "=========================================================="
echo " RealtimeGym baseline run"
echo " started : $(date '+%F %T')"
echo " host    : $(hostname)"
echo " scratch : ${_CONDOR_SCRATCH_DIR}"
echo " log     : ${RUN_LOG}"
echo "=========================================================="
step() { echo ""; echo "--- [$(date '+%T')] $* ---"; }

# ---- caches into scratch so nothing lands in $HOME -------------------------
export HOME=$_CONDOR_SCRATCH_DIR
export HF_HOME=$_CONDOR_SCRATCH_DIR/hf_home
export XDG_CACHE_HOME=$_CONDOR_SCRATCH_DIR/xdg_cache
export XDG_CONFIG_HOME=$_CONDOR_SCRATCH_DIR/xdg_config
export TORCHINDUCTOR_CACHE_DIR=$_CONDOR_SCRATCH_DIR/torch_cache
export OUTLINES_CACHE_DIR=/tmp/.outlines
export VLLM_USAGE_DISABLE=1
export _USAGE_STATS_JSON_PATH=$_CONDOR_SCRATCH_DIR/vllm_usage
# The container UID has no /etc/passwd entry ("I have no name!"), so
# pwd.getpwuid() raises. torch._inductor calls getpass.getuser() at IMPORT time;
# getuser() checks LOGNAME/USER/LNAME/USERNAME before falling back to pwd, so
# both must be non-empty or vllm dies before it even parses argv.
: "${CHTC_USER:?CHTC_USER is empty or unset -- check .env}"
export USER=${CHTC_USER}
export LOGNAME=${CHTC_USER}

# headless: pygame is imported unconditionally by agile_eval
# CHTC sets HTTP(S)_PROXY to a Squid proxy. Without this, every call to
# localhost:8000 -- the health probe AND the openai client inside the eval --
# gets routed through Squid and fails. This was the 30-minute "vLLM never came
# up" mystery: the server was fine, the probe could not reach it.
export NO_PROXY="127.0.0.1,localhost,::1"
export no_proxy="$NO_PROXY"

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
step "STEP 1/5  fetch code from staging"
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
step "STEP 2/5  install deps (--no-deps: container already has torch/vllm)"
pip install --no-deps -e . 
pip install --no-deps pygame python-dotenv

# realtimegym/prompts/__init__.py does `from . import freeway, overcooked, snake`,
# so EVERY game drags in overcooked -> `import gym`. Freeway never calls into it,
# but the import must succeed. Try the real package, fall back to a stub.
if ! python3 -c "import gym" 2>/dev/null; then
  echo "installing gym ..."
  pip install --no-deps gym gym_notices cloudpickle || true
fi
if ! python3 -c "import gym" 2>/dev/null; then
  echo "gym unavailable -- installing a minimal stub (import-only, never called)"
  STUB=$_CONDOR_SCRATCH_DIR/stubs
  mkdir -p $STUB/gym/envs
  cat > $STUB/gym/__init__.py <<'EOF'
from . import envs  # noqa: F401
class Env: pass
class Wrapper: pass
class Space: pass
class spaces: pass
EOF
  cat > $STUB/gym/envs/__init__.py <<'EOF'
from . import registration  # noqa: F401
EOF
  cat > $STUB/gym/envs/registration.py <<'EOF'
def register(*args, **kwargs):
    return None
EOF
  export PYTHONPATH=$STUB:$PYTHONPATH
fi
python3 -c "import gym; print('gym ok:', getattr(gym, '__file__', '?'))"
python3 -c "import pandas, numpy, yaml, openai, transformers, pygame, gym; print('deps ok')"
export PYTHONPATH=$(pwd)/src:$PYTHONPATH

# ---- start vLLM -----------------------------------------------------------
# The configs ship pinned to Qwen3-8B; retarget them at whatever MODEL serves,
# otherwise the eval requests a model the server does not have (404).
# realtimegym.prompts.__init__ eagerly imports overcooked, which drags in a long
# chain (gym, IPython, imageio, ...). --no-deps means none of it is present. Walk
# the chain, installing whatever is missing, BEFORE we spend 2 min starting vLLM.
step "STEP 2c/5  preflight: import the prompt chain"
for _attempt in 1 2 3 4 5 6 7 8; do
  _missing=$(python3 - 2>/dev/null <<'PYEOF'
import importlib
try:
    importlib.import_module("realtimegym.prompts.freeway")
except ModuleNotFoundError as e:
    print(e.name or "")
except Exception:
    pass
PYEOF
)
  [ -z "${_missing}" ] && break
  # import name != pip name for a few of these
  case "${_missing}" in
    IPython) _pkg=ipython ;;
    yaml)    _pkg=pyyaml ;;
    PIL)     _pkg=pillow ;;
    cv2)     _pkg=opencv-python-headless ;;
    sklearn) _pkg=scikit-learn ;;
    *)       _pkg="${_missing}" ;;
  esac
  echo "  missing '${_missing}' -> pip install ${_pkg}"
  pip install "${_pkg}" || pip install --no-deps "${_pkg}" || true
done
python3 -c "import realtimegym.prompts.freeway; print('prompt chain ok')"

# Gated models (Llama) need the token visible to vLLM's subprocesses.
if [ -n "${HF_TOKEN}" ]; then export HF_TOKEN HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"; fi

# Which servers does this mode actually need?
#   planning -> planning model only; reactive -> reactive model only;
#   agile    -> both (one server if they are the same model).
NEED_P=0; NEED_R=0
[ "${MODE}" != "reactive" ] && NEED_P=1
[ "${MODE}" != "planning" ] && NEED_R=1
P_PORT=8000
if [ "${NEED_P}" = 1 ] && [ "${NEED_R}" = 1 ] && [ "${PLANNING_MODEL}" != "${REACTIVE_MODEL}" ]; then
  R_PORT=8001; TWO=1; UTIL=0.44     # two 8B models share one 80GB card
else
  R_PORT=8000; TWO=0; UTIL=0.90
fi

step "STEP 2b/5  retarget configs  planning=${PLANNING_MODEL}  reactive=${REACTIVE_MODEL}"
PCFG=configs/chtc-qwen3-8b-planning.yaml
RCFG=configs/chtc-qwen3-8b-reactive.yaml
sed -i "s|^model: .*|model: ${PLANNING_MODEL}|; s|^tokenizer: .*|tokenizer: ${PLANNING_MODEL}|; s|^url: .*|url: http://127.0.0.1:${P_PORT}/v1|" ${PCFG}
sed -i "s|^model: .*|model: ${REACTIVE_MODEL}|; s|^url: .*|url: http://127.0.0.1:${R_PORT}/v1|" ${RCFG}
grep -H "^model:\|^tokenizer:\|^url:" ${PCFG} ${RCFG}

step "STEP 3/5  start vLLM"
PARSER_FLAG=""
[ -n "${REASONING_PARSER}" ] && PARSER_FLAG="--reasoning-parser ${REASONING_PARSER}"
PIDS=""; PORTS=""
_serve() {   # model port logname
  echo "Starting vLLM: $1 on :$2 (util ${UTIL})"
  vllm serve "$1" --port "$2" ${PARSER_FLAG} \
    --max-model-len ${MAXLEN} --gpu-memory-utilization ${UTIL} \
    > $_CONDOR_SCRATCH_DIR/$3 2>&1 &
  PIDS="${PIDS} $!"; PORTS="${PORTS} $2"
}
if [ "${NEED_P}" = 1 ]; then _serve "${PLANNING_MODEL}" ${P_PORT} vllm.log; fi
if [ "${NEED_R}" = 1 ] && { [ "${NEED_P}" = 0 ] || [ "${TWO}" = 1 ]; }; then
  # second server: wait for the first to finish grabbing memory, so the two
  # memory profilers do not both claim the same free VRAM
  if [ "${TWO}" = 1 ]; then
    until python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:${P_PORT}/health',timeout=5)" 2>/dev/null; do sleep 10; done
    _serve "${REACTIVE_MODEL}" ${R_PORT} vllm_reactive.log
  else
    _serve "${REACTIVE_MODEL}" ${R_PORT} vllm.log
  fi
fi
trap "echo 'stopping vllm'; kill ${PIDS} 2>/dev/null || true" EXIT

# curl exists but CHTC's Squid proxy breaks it for localhost; use python.
_healthy() {
  python3 - "$1" <<'PYEOF' 2>/dev/null
import sys, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=5) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
}

for PT in ${PORTS}; do
  echo "Waiting for vLLM on :${PT} ..."
  for i in $(seq 1 180); do
    if _healthy ${PT}; then echo "vLLM :${PT} healthy after $((i*10))s"; break; fi
    for PID in ${PIDS}; do
      if ! kill -0 ${PID} 2>/dev/null; then
        echo "!! a vLLM server died during startup:"; tail -50 $_CONDOR_SCRATCH_DIR/vllm*.log; exit 1
      fi
    done
    sleep 10
  done
  _healthy ${PT} || { echo "!! vLLM :${PT} never came up"; tail -80 $_CONDOR_SCRATCH_DIR/vllm*.log; exit 1; }
done

# ---- sanity: reasoning trace visible on planning, short answer on reactive --
step "STEP 4/5  sanity check"
_probe() {   # port model label
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys, urllib.request
port, model, label = sys.argv[1:4]
body = json.dumps({"model": model,
                   "messages": [{"role": "user", "content": "What is 17*23? Think briefly."}],
                   "max_tokens": 200}).encode()
req = urllib.request.Request("http://127.0.0.1:%s/v1/chat/completions" % port,
                             data=body, headers={"Content-Type": "application/json"})
m = json.load(urllib.request.urlopen(req, timeout=180))["choices"][0]["message"]
rc, c = m.get("reasoning_content"), (m.get("content") or "")
print("[%s] %s" % (label, model))
print("  reasoning_content:", (rc[:120] + "...") if rc else "MISSING")
print("  content:", c[:120].replace("\n", " "))
PYEOF
}
[ "${NEED_P}" = 1 ] && _probe ${P_PORT} "${PLANNING_MODEL}" planning
[ "${NEED_R}" = 1 ] && _probe ${R_PORT} "${REACTIVE_MODEL}" reactive
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

mkdir -p ${LOGDIR}
printf "model_tag: %s\nplanning_model: %s\nreactive_model: %s\n" \
  "${MODEL_TAG}" "${PLANNING_MODEL}" "${REACTIVE_MODEL}" > ${LOGDIR}/model.txt

# Checkpoint logs to /staging every 15 min. Results are otherwise only packaged
# at the end, so a job killed at the 12h short-tier limit (or on a node where
# condor_ssh_to_job is disabled) would leave nothing. args.log in the checkpoint
# lists every seed that has already finished.
mkdir -p ${STAGING}/rtg_results/partial
( while sleep 900; do
    tar -czf ${STAGING}/rtg_results/partial/${RUNTAG}.tar.gz.tmp -C $_CONDOR_SCRATCH_DIR/RealtimeGym ${LOGDIR} 2>/dev/null \
      && mv ${STAGING}/rtg_results/partial/${RUNTAG}.tar.gz.tmp ${STAGING}/rtg_results/partial/${RUNTAG}.tar.gz
  done ) &
CKPT_PID=$!

# Slow-node watchdog. Measured on finished runs: normal nodes do 117-430 steps/h
# (all 8 seeds combined); slow nodes 35-56 steps/h, which cannot finish 800 steps
# inside the 12h short-tier limit. After WATCH_MIN minutes of eval, if progress is
# below WATCH_STEPS, kill the eval so the job exits non-zero. on_exit_hold +
# periodic_release in the .sub then retry it on a machine it has not used.
# A seed that already finished counts as 100 steps of progress.
WATCH_MIN=${WATCH_MIN:-60}        # grace period before the first check
WATCH_RATE=${WATCH_RATE:-55}      # required steps/hour, measured cumulatively
WATCH_EVERY=${WATCH_EVERY:-1200}  # re-check every 20 min (a node can slow down later)
( sleep $((WATCH_MIN * 60))
  t0=$(date +%s)
  while true; do
    n=$(grep -c "position:" $_CONDOR_SCRATCH_DIR/eval.log 2>/dev/null); n=${n:-0}
    f=$(grep -c "finished the game" $_CONDOR_SCRATCH_DIR/eval.log 2>/dev/null); f=${f:-0}
    prog=$((n + 100 * f))
    elapsed_min=$(( ($(date +%s) - t0) / 60 + WATCH_MIN ))
    need=$(( WATCH_RATE * elapsed_min / 60 ))
    echo "[watchdog] ${elapsed_min} min: ${n} steps, ${f} seeds done (progress ${prog}, need ${need})"
    if [ ${prog} -lt ${need} ]; then
      echo "!! WATCHDOG: ${prog} progress after ${elapsed_min} min on $(hostname) (< ${WATCH_RATE}/h) -- slow node, exiting so HTCondor retries elsewhere"
      nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv || true
      touch $_CONDOR_SCRATCH_DIR/SLOW_NODE
      pkill -f "realtimegym.agile_eval" || true
      exit 0
    fi
    sleep ${WATCH_EVERY}
  done ) &
WATCH_PID=$!
PIDS="${PIDS} ${CKPT_PID} ${WATCH_PID}"   # the EXIT trap kills PIDS
trap "echo 'stopping vllm + checkpointer'; kill ${PIDS} 2>/dev/null || true" EXIT

step "STEP 5/5  run eval"
echo "Running: ${GAME} mode=${MODE} load=${LOAD} tp=${PRESSURE} ib=${IBUDGET} seeds=${SEEDS} repeats=${REPEATS} ${EXTRA}"
time python3 -m realtimegym.agile_eval \
  --game ${GAME} --cognitive_load ${LOAD} --mode ${MODE} \
  --time_pressure ${PRESSURE} --internal_budget ${IBUDGET} \
  --planning-model-config configs/chtc-qwen3-8b-planning.yaml \
  --reactive-model-config configs/chtc-qwen3-8b-reactive.yaml \
  --seed_num ${SEEDS} --repeat_times ${REPEATS} \
  --log_dir ${LOGDIR} ${EXTRA} 2>&1 | tee $_CONDOR_SCRATCH_DIR/eval.log

# ---- collect results ------------------------------------------------------
cd $_CONDOR_SCRATCH_DIR
tar -czf results_${RUNTAG}.tar.gz \
    -C RealtimeGym ${LOGDIR} \
    -C $_CONDOR_SCRATCH_DIR $(cd $_CONDOR_SCRATCH_DIR && ls vllm*.log) eval.log
mkdir -p ${STAGING}/rtg_results
cp results_${RUNTAG}.tar.gz ${STAGING}/rtg_results/
kill ${CKPT_PID} 2>/dev/null || true
rm -f ${STAGING}/rtg_results/partial/${RUNTAG}.tar.gz ${STAGING}/rtg_results/partial/${RUNTAG}.tar.gz.tmp
echo ""; echo "[$(date '+%T')] DONE."
echo "Full transcript: ${RUN_LOG}"
echo "Results in ${STAGING}/rtg_results/results_${RUNTAG}.tar.gz"
