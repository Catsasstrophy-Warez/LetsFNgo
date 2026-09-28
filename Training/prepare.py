#!/usr/bin/env python3
"""Convert NexusDatasetGen JSONL into mlx-lm fine-tuning data.

    python3 Training/prepare.py --train train.jsonl --eval eval.jsonl --out Training/build/data

Writes ``train.jsonl``, ``valid.jsonl`` and ``test.jsonl`` in the layout
``mlx_lm.lora --data DIR`` expects. The generator's splits are preserved:
every ``eval`` example goes to ``test.jsonl`` and nothing else, and the
``train`` examples are divided into ``train.jsonl`` and ``valid.jsonl`` by a
stable hash of their id, so the same input always gives the same files.

Formats (``--format``):

* ``chat`` (default): ``{"messages": [...]}``, plus ``"tools"`` for tool
  transcripts. The last assistant message is the training target, so train
  with ``mask_prompt: true``.
* ``completions``: ``{"prompt": ..., "completion": ...}``; transcripts are
  flattened into the prompt as text.

Every target ends in two machine-readable lines that ``evaluate.py`` parses
back into the Swift evaluator's prediction fields::

    CAUSE: <answer.cause>
    NEXT_TEST: <answer.nextTest>        (only when the example has one)

Standard library only, so it runs (and is unit-tested) on Linux CI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

SYSTEM_PROMPT = (
    "You are Nexus's diagnostic assistant. Reason only from the values given; never invent a value. "
    "Label every value you cite with its truth class (observed, recorded, display, modeled, derived, claimed, "
    "agentInterpretation). End with a line 'CAUSE: <cause label>' and, when tests are offered, "
    "a line 'NEXT_TEST: <exact test title>'."
)

# WorldTools (Sources/NexusAgents/WorldTools.swift) the transcripts call, in
# the OpenAI function format that Hugging Face chat templates accept.
TOOLS: List[Dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "search_objects",
            "description": "Search the world model by text. Returns IDs, types and titles.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Words to search for"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_object",
            "description": "Read one object, with each attribute's truth class.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Object ID"}},
                "required": ["id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "related_objects",
            "description": "List objects related to an object and how.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Object ID"}},
                "required": ["id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_measurements",
            "description": "Readings at a test point, labeled observed/modeled/display/etc.",
            "parameters": {
                "type": "object",
                "properties": {"test_point": {"type": "string", "description": "Test point ID"}},
                "required": ["test_point"],
            },
        },
    },
]

CAUSE_PREFIX = "CAUSE:"
NEXT_TEST_PREFIX = "NEXT_TEST:"


# MARK: Reading


def read_jsonl(path: str) -> List[Dict[str, Any]]:
    examples = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                examples.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{number}: not JSON ({error})") from error
    return examples


def write_jsonl(path: str, rows: Iterable[Dict[str, Any]]) -> int:
    count = 0
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
            count += 1
    return count


# MARK: Rendering


def number(value: float) -> str:
    """Two decimals at most, trailing zeros dropped, like the Swift generator."""
    text = f"{round(float(value), 2):.2f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def cite(value: float, unit: str, truth: str) -> str:
    shown = number(value) if unit in ("bool", "ratio") else f"{number(value)} {unit}"
    return f"{shown} ({truth})"


def user_prompt(example: Dict[str, Any]) -> str:
    """The question plus everything the model may use, each value with its truth class."""
    lines = [example["prompt"].strip()]
    observations = example.get("observations") or []
    if observations:
        lines += ["", "Known values:"]
        for item in observations:
            lines.append(f"- {item['name']} at {item['object']}: {cite(item['value'], item['unit'], item['truth'])}, from {item['source']}")
    tests = example.get("tests") or []
    if tests:
        lines += ["", "Tests you may recommend:"]
        for test in tests:
            lines.append(f"- {test['title']} ({test['object']}, {number(test['cost'])} min, {test['safety']})")
    hypotheses = example.get("hypotheses") or []
    if hypotheses:
        lines += ["", "Candidate causes:"]
        for hypothesis in hypotheses:
            lines.append(f"- {hypothesis['cause']}: {hypothesis['statement']}")
    return "\n".join(lines)


def target(example: Dict[str, Any], text: Optional[str] = None) -> str:
    """The assistant's answer followed by the machine-readable cause and next test."""
    answer = example["answer"]
    lines = [(text if text is not None else answer["text"]).strip(), "", f"{CAUSE_PREFIX} {answer['cause']}"]
    if answer.get("nextTest"):
        lines.append(f"{NEXT_TEST_PREFIX} {answer['nextTest']}")
    return "\n".join(lines)


def _tool_call(call: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": call["id"], "type": "function", "function": {"name": call["name"], "arguments": call.get("arguments", {})}}


def transcript_messages(example: Dict[str, Any]) -> List[Dict[str, Any]]:
    """A tool transcript in the OpenAI message format, final answer as the target."""
    source = example.get("messages") or []
    if not source or source[-1]["role"] != "assistant" or source[-1].get("toolCalls"):
        raise ValueError(f"{example['id']}: a transcript must end with a plain assistant answer")
    messages: List[Dict[str, Any]] = []
    for index, message in enumerate(source):
        role = message["role"]
        if role == "system":
            messages.append({"role": "system", "content": message["content"] + " " + SYSTEM_PROMPT})
        elif role == "tool":
            messages.append({"role": "tool", "tool_call_id": message.get("toolCallID"), "content": message["content"]})
        elif role == "assistant" and message.get("toolCalls"):
            messages.append({"role": "assistant", "content": message.get("content", ""), "tool_calls": [_tool_call(c) for c in message["toolCalls"]]})
        elif role == "assistant" and index == len(source) - 1:
            messages.append({"role": "assistant", "content": target(example, message["content"])})
        else:
            messages.append({"role": role, "content": message["content"]})
    if messages[0]["role"] != "system":
        messages.insert(0, {"role": "system", "content": SYSTEM_PROMPT})
    return messages


def transcript_as_text(messages: List[Dict[str, Any]]) -> str:
    """Tool turns written out as text, for models or formats without tool support."""
    lines = []
    for message in messages:
        if message["role"] == "system":
            continue
        if message.get("tool_calls"):
            for call in message["tool_calls"]:
                arguments = json.dumps(call["function"]["arguments"], sort_keys=True)
                lines.append(f"[tool call {call['id']}] {call['function']['name']} {arguments}")
        elif message["role"] == "tool":
            lines.append(f"[tool result {message['tool_call_id']}]\n{message['content']}")
        else:
            lines.append(f"[{message['role']}] {message['content']}")
    return "\n".join(lines)


def to_chat(example: Dict[str, Any], tool_style: str = "openai") -> Dict[str, Any]:
    """One chat row. The last message is always the assistant target."""
    if example.get("kind") == "toolTranscript" and example.get("messages"):
        messages = transcript_messages(example)
        if tool_style == "openai":
            return {"messages": messages, "tools": TOOLS}
        context = transcript_as_text(messages[1:-1])
        return {
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": context},
                messages[-1],
            ]
        }
    return {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt(example)},
            {"role": "assistant", "content": target(example)},
        ]
    }


def to_completion(example: Dict[str, Any]) -> Dict[str, str]:
    chat = to_chat(example, tool_style="text")
    return {"prompt": SYSTEM_PROMPT + "\n\n" + chat["messages"][1]["content"], "completion": chat["messages"][-1]["content"]}


def prompt_messages(example: Dict[str, Any], tool_style: str = "openai") -> Tuple[List[Dict[str, Any]], Optional[List[Dict[str, Any]]]]:
    """What the model sees at evaluation: every message but the target, and the tools."""
    chat = to_chat(example, tool_style)
    return chat["messages"][:-1], chat.get("tools")


# MARK: Splits


def is_validation(example_id: str, fraction: float) -> bool:
    """Stable assignment of a train example to the validation file."""
    digest = hashlib.sha256(example_id.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / 2**64 < fraction


def check_splits(train: List[Dict[str, Any]], held_out: List[Dict[str, Any]]) -> None:
    for name, rows, split in (("--train", train, "train"), ("--eval", held_out, "eval")):
        wrong = [row["id"] for row in rows if row.get("split") != split]
        if wrong:
            raise ValueError(f"{name} holds examples from another split: {', '.join(wrong[:3])}")
        ids = [row["id"] for row in rows]
        if len(set(ids)) != len(ids):
            raise ValueError(f"{name} repeats example ids")
    shared = {row["seed"] for row in train} & {row["seed"] for row in held_out}
    if shared:
        raise ValueError(f"train and eval share scenario seeds: {sorted(shared)[:3]}")


def prepare(
    train_path: str,
    eval_path: str,
    out_dir: str,
    valid_fraction: float = 0.1,
    fmt: str = "chat",
    tool_style: str = "openai",
) -> Dict[str, int]:
    if not 0 < valid_fraction < 1:
        raise ValueError("--valid-fraction must be between 0 and 1")
    train = read_jsonl(train_path)
    held_out = read_jsonl(eval_path)
    check_splits(train, held_out)

    def row(example: Dict[str, Any]) -> Dict[str, Any]:
        return to_chat(example, tool_style) if fmt == "chat" else to_completion(example)

    training = [example for example in train if not is_validation(example["id"], valid_fraction)]
    validation = [example for example in train if is_validation(example["id"], valid_fraction)]
    if not validation and len(training) > 1:
        # Tiny runs: keep at least one validation example so mlx-lm reports a loss.
        validation, training = training[-1:], training[:-1]
    os.makedirs(out_dir, exist_ok=True)
    counts = {
        "train": write_jsonl(os.path.join(out_dir, "train.jsonl"), map(row, training)),
        "valid": write_jsonl(os.path.join(out_dir, "valid.jsonl"), map(row, validation)),
        "test": write_jsonl(os.path.join(out_dir, "test.jsonl"), map(row, held_out)),
    }
    return counts


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--train", required=True, help="NexusDatasetGen output with --split train")
    parser.add_argument("--eval", required=True, help="NexusDatasetGen output with --split eval (becomes test.jsonl)")
    parser.add_argument("--out", required=True, help="Directory for train/valid/test.jsonl")
    parser.add_argument("--valid-fraction", type=float, default=0.1)
    parser.add_argument("--format", choices=["chat", "completions"], default="chat")
    parser.add_argument("--tool-style", choices=["openai", "text"], default="openai", help="How transcripts carry tool calls")
    args = parser.parse_args(argv)
    try:
        counts = prepare(args.train, args.eval, args.out, args.valid_fraction, args.format, args.tool_style)
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(f"wrote {counts['train']} train, {counts['valid']} valid, {counts['test']} test rows to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
