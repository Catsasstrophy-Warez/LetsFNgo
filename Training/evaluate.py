#!/usr/bin/env python3
"""Run a fine-tuned model on the held-out set and write predictions for the Swift evaluator.

    python3 Training/evaluate.py --model Training/build/fused --examples eval.jsonl --out predictions.jsonl
    swift run NexusDatasetGen evaluate --examples eval.jsonl --predictions predictions.jsonl --out candidate.json

Each output line is a ``ModelPrediction`` (Sources/NexusTrainingData/Evaluator.swift)::

    {"id": "...", "predictedCause": "...", "predictedNextTest": "...", "answer": "..."}

The model sees exactly what ``prepare.py`` puts before the training target
(system prompt, question, known values, tests, candidate causes; for tool
transcripts, the recorded tool calls and results) and is decoded greedily.
Its ``CAUSE:`` and ``NEXT_TEST:`` lines become ``predictedCause`` and
``predictedNextTest``; the rest is the ``answer`` the evaluator checks for
invented numbers and truth-class labels. Tool-call validity is scored by the
Swift agent evals, not here.

``--responses FILE`` skips the model and reads ``{"id", "text"}`` lines
instead (another runtime's raw output, or a test fixture). Only that path
runs without mlx-lm, which needs Apple silicon.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Callable, Dict, Iterable, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import prepare  # noqa: E402

THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def parse_completion(text: str) -> Dict[str, Optional[str]]:
    """Splits a completion into the answer and its CAUSE / NEXT_TEST lines.

    Reasoning blocks (``<think>…</think>``) are dropped. When a label repeats,
    the last one wins; labels are matched case-insensitively.
    """
    text = THINK_BLOCK.sub("", text)
    cause: Optional[str] = None
    next_test: Optional[str] = None
    kept: List[str] = []
    for line in text.splitlines():
        stripped = line.strip().strip("*").strip()
        upper = stripped.upper()
        if upper.startswith(prepare.CAUSE_PREFIX):
            cause = stripped[len(prepare.CAUSE_PREFIX):].strip().strip("`").strip() or None
        elif upper.startswith(prepare.NEXT_TEST_PREFIX):
            next_test = stripped[len(prepare.NEXT_TEST_PREFIX):].strip().strip("`").strip() or None
        else:
            kept.append(line)
    answer = "\n".join(kept).strip()
    return {"answer": answer or None, "predictedCause": cause, "predictedNextTest": next_test}


def prediction(example_id: str, text: str) -> Dict[str, Any]:
    """A ModelPrediction line; missing fields are omitted, as the evaluator expects."""
    parsed = parse_completion(text)
    record: Dict[str, Any] = {"id": example_id}
    for key in ("predictedCause", "predictedNextTest", "answer"):
        if parsed[key] is not None:
            record[key] = parsed[key]
    return record


def predict_all(examples: Iterable[Dict[str, Any]], generate: Callable[[Dict[str, Any]], str]) -> List[Dict[str, Any]]:
    return [prediction(example["id"], generate(example)) for example in examples]


def mlx_generator(
    model_path: str, adapter_path: Optional[str], max_tokens: int, tool_style: str, template_kwargs: Dict[str, Any]
) -> Callable[[Dict[str, Any]], str]:
    """Greedy generation with mlx-lm, using the model's own chat template."""
    from mlx_lm import generate, load  # Apple silicon only; imported lazily.

    model, tokenizer = load(model_path, adapter_path=adapter_path)

    def run(example: Dict[str, Any]) -> str:
        messages, tools = prepare.prompt_messages(example, tool_style)
        prompt = tokenizer.apply_chat_template(messages, tools=tools, add_generation_prompt=True, tokenize=False, **template_kwargs)
        tokens = tokenizer.encode(prompt, add_special_tokens=False)
        return generate(model, tokenizer, prompt=tokens, max_tokens=max_tokens, verbose=False)

    return run


def responses_generator(path: str) -> Callable[[Dict[str, Any]], str]:
    texts = {row["id"]: row["text"] for row in prepare.read_jsonl(path)}
    return lambda example: texts.get(example["id"], "")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--examples", required=True, help="NexusDatasetGen --split eval output")
    parser.add_argument("--out", required=True, help="Predictions JSONL for `NexusDatasetGen evaluate`")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--model", help="Fused model directory or base model (with --adapter-path)")
    source.add_argument("--responses", help="Pre-generated {id, text} JSONL instead of a model")
    parser.add_argument("--adapter-path", help="LoRA adapters from mlx_lm.lora, when --model is the base model")
    parser.add_argument("--max-tokens", type=int, default=768)
    parser.add_argument("--limit", type=int, help="Only the first N examples")
    parser.add_argument("--tool-style", choices=["openai", "text"], default="openai", help="Must match prepare.py")
    parser.add_argument(
        "--template-kwargs", default="{}", help='JSON passed to the chat template, e.g. \'{"enable_thinking": false}\' for Qwen3'
    )
    args = parser.parse_args(argv)

    examples = prepare.read_jsonl(args.examples)
    if args.limit:
        examples = examples[: args.limit]
    if args.model:
        generate = mlx_generator(args.model, args.adapter_path, args.max_tokens, args.tool_style, json.loads(args.template_kwargs))
    else:
        generate = responses_generator(args.responses)
    rows = []
    for index, example in enumerate(examples, 1):
        rows.append(prediction(example["id"], generate(example)))
        if args.model and index % 20 == 0:
            print(f"{index}/{len(examples)}", file=sys.stderr)
    count = prepare.write_jsonl(args.out, rows)
    print(f"wrote {count} predictions to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
