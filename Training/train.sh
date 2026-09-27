#!/usr/bin/env bash
# Fine-tune the base model in Training/lora.yaml with LoRA, report the
# held-out loss, and fuse the adapters into a standalone model.
#
#   Training/train.sh [DATA_DIR] [OUT_DIR]
#
# DATA_DIR holds train/valid/test.jsonl from prepare.py (default
# Training/build/data). OUT_DIR receives adapters/ and fused/ (default
# Training/build). Environment overrides:
#   CONFIG=path.yaml    another config (default Training/lora.yaml)
#   MODEL=repo-or-dir   another base model (default: `model:` in the config)
#   ITERS=N             another iteration count, e.g. ITERS=50 for a smoke run
#   DEQUANTIZE=1        fuse a quantized base back to full precision (needed
#                       before exporting to Core AI or GGUF)
#
# Needs Apple silicon and `pip install "mlx-lm>=0.31"`. It cannot run on the
# Linux CI; there, only prepare.py and evaluate.py's parsing are tested.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Training/lora.yaml}"
DATA="${1:-Training/build/data}"
OUT="${2:-Training/build}"
MODEL="${MODEL:-$(sed -n 's/^model:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$CONFIG" | head -n 1)}"

if ! command -v mlx_lm.lora >/dev/null 2>&1; then
    echo "mlx_lm.lora not found: pip install 'mlx-lm>=0.31' (Apple silicon only)" >&2
    exit 2
fi
for split in train valid test; do
    [[ -s "$DATA/$split.jsonl" ]] || { echo "missing $DATA/$split.jsonl: run Training/prepare.py first" >&2; exit 2; }
done
[[ -n "$MODEL" ]] || { echo "no base model: set MODEL or model: in $CONFIG" >&2; exit 2; }

extra=()
[[ -n "${ITERS:-}" ]] && extra+=(--iters "$ITERS")

# 1. Train LoRA adapters. The config supplies the hyperparameters; these flags
#    win over it. Checkpoints land in $OUT/adapters every save_every steps.
mlx_lm.lora --config "$CONFIG" --model "$MODEL" --train --data "$DATA" --adapter-path "$OUT/adapters" ${extra[@]+"${extra[@]}"}

# 2. Loss and perplexity on test.jsonl (the generator's eval split). This is a
#    sanity check only; promotion uses the Swift evaluator's metrics.
mlx_lm.lora --config "$CONFIG" --model "$MODEL" --test --data "$DATA" --adapter-path "$OUT/adapters"

# 3. Fuse the adapters into the base weights: $OUT/fused is a standalone MLX
#    model directory that evaluate.py, mlx_lm.generate and the registry use.
fuse=(--model "$MODEL" --adapter-path "$OUT/adapters" --save-path "$OUT/fused")
[[ "${DEQUANTIZE:-0}" == "1" ]] && fuse+=(--dequantize)
mlx_lm.fuse "${fuse[@]}"

echo "adapters: $OUT/adapters"
echo "fused model: $OUT/fused"
