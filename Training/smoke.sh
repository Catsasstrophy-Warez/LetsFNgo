#!/usr/bin/env bash
# Linux smoke test of the training pipeline, without a model (CI runs this).
#
#   Training/smoke.sh [WORK_DIR]
#
# 1. Generates a small mixed train/eval dataset with NexusDatasetGen.
# 2. Runs the Python unit tests, including over that real output.
# 3. Converts it with prepare.py into mlx-lm train/valid/test files.
# 4. Feeds the reference targets through evaluate.py as a stand-in model, so
#    the prediction format is checked against the Swift evaluator.
# 5. Runs the promotion gate: the reference must pass over the baseline, the
#    baseline must be refused over the reference, and gate-selfcheck must pass.
#
# Expects `swift build` to have run (it uses `swift run --skip-build`).
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="${1:-.build/training-smoke}"
rm -rf "$WORK"
mkdir -p "$WORK"
gen() { swift run --skip-build NexusDatasetGen "$@"; }

gen --count 20 --seed 1 --domain mixed --out "$WORK/train.jsonl"
gen --count 10 --seed 1 --domain mixed --split eval --out "$WORK/eval.jsonl"

NEXUS_TRAIN_JSONL="$WORK/train.jsonl" NEXUS_EVAL_JSONL="$WORK/eval.jsonl" python3 -m unittest discover -s Training -v

python3 Training/prepare.py --train "$WORK/train.jsonl" --eval "$WORK/eval.jsonl" --out "$WORK/data"

python3 - "$WORK" <<'PY'
import json, os, sys
sys.path.insert(0, "Training")
import prepare
work = sys.argv[1]
rows = [{"id": e["id"], "text": prepare.to_chat(e)["messages"][-1]["content"]} for e in prepare.read_jsonl(os.path.join(work, "eval.jsonl"))]
prepare.write_jsonl(os.path.join(work, "responses.jsonl"), rows)
PY
python3 Training/evaluate.py --examples "$WORK/eval.jsonl" --responses "$WORK/responses.jsonl" --out "$WORK/reference.jsonl"

gen baseline --train "$WORK/train.jsonl" --examples "$WORK/eval.jsonl" --out "$WORK/baseline.jsonl"
gen evaluate --examples "$WORK/eval.jsonl" --predictions "$WORK/baseline.jsonl" --out "$WORK/baseline.json" >/dev/null
gen evaluate --examples "$WORK/eval.jsonl" --predictions "$WORK/reference.jsonl" --out "$WORK/reference.json"

echo "--- gate: reference over baseline (must pass)"
gen gate --candidate "$WORK/reference.json" --current "$WORK/baseline.json"
echo "--- gate: baseline over reference (must be refused)"
if gen gate --candidate "$WORK/baseline.json" --current "$WORK/reference.json"; then
    echo "error: the gate promoted a worse candidate" >&2
    exit 1
fi
echo "--- gate self-check"
gen gate-selfcheck --train "$WORK/train.jsonl" --examples "$WORK/eval.jsonl"
echo "training pipeline smoke test passed"
