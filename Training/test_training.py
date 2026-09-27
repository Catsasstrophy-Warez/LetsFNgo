"""Unit tests for prepare.py and evaluate.py: python3 -m unittest discover Training

Fixture examples below have the NexusDatasetGen shape. When the environment
names generated files (NEXUS_TRAIN_JSONL, NEXUS_EVAL_JSONL, as the CI step
does), the tests also run over real generator output.
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import evaluate  # noqa: E402
import prepare  # noqa: E402


def diagnosis(example_id, split, seed, cause="openWire", next_test="Clamp meter on the loop current"):
    return {
        "id": example_id,
        "kind": "diagnosis",
        "split": split,
        "seed": seed,
        "prompt": "LT-391 reads -25 % on the HMI against a 90 % setpoint.",
        "observations": [
            {"name": "measuredLevel", "object": "AI card slot 7 ch 3", "value": -25, "unit": "%", "truth": "display", "source": "HMI"},
            {"name": "highLevelAlarm", "object": "LSH-391", "value": 1, "unit": "bool", "truth": "recorded", "source": "alarm log"},
        ],
        "tests": [
            {"title": next_test, "object": "TB-8 terminals 23/24", "quantity": "loopCurrent", "unit": "mA", "cost": 4.5, "safety": "routine"},
        ],
        "hypotheses": [{"cause": cause, "statement": "Open circuit in the loop wiring", "predictions": []}],
        "answer": {"cause": cause, "nextTest": next_test, "text": "Next test: %s. Cause: [%s]." % (next_test, cause)},
    }


def transcript(example_id, split, seed):
    return {
        "id": example_id,
        "kind": "toolTranscript",
        "split": split,
        "seed": seed,
        "prompt": "What should I measure next?",
        "observations": [],
        "messages": [
            {"role": "system", "content": "You are Nexus's diagnostic assistant."},
            {"role": "user", "content": "LT-698 reads 17.39 %. What should I measure next?"},
            {"role": "assistant", "content": "", "toolCalls": [{"id": "call-1", "name": "search_objects", "arguments": {"query": "LT-698"}}]},
            {"role": "tool", "content": "38a45ea7-90d5-4998-a8f7-c47a879239fd [sensor] LT-698 level transmitter", "toolCallID": "call-1"},
            {"role": "assistant", "content": "LT-698 shows 17.39 % (display). Next test: Compare the sight glass with the HMI."},
        ],
        "answer": {"cause": "contactResistance", "nextTest": "Compare the sight glass with the HMI", "text": "LT-698 shows 17.39 % (display)."},
    }


def ladder(example_id, split, seed):
    return {
        "id": example_id,
        "kind": "ladderWhy",
        "split": split,
        "seed": seed,
        "prompt": "Why isn't Pump_Start on?\nRung 0: XIC(VFD_Ready) XIO(Low_Air) OTE(Pump_Start)",
        "observations": [{"name": "Low_Air", "object": "PumpStartLogic", "value": 1, "unit": "bool", "truth": "recorded", "source": "tags"}],
        "answer": {"cause": "Low_Air", "text": "Pump_Start is off. Root condition: Low_Air (recorded from the controller)."},
    }


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def write(directory, name, rows):
    path = os.path.join(directory, name)
    prepare.write_jsonl(path, rows)
    return path


class PrepareTests(unittest.TestCase):
    def test_chat_rows_end_with_the_answer_and_machine_lines(self):
        row = prepare.to_chat(diagnosis("train-1-diagnosis", "train", 1))
        roles = [message["role"] for message in row["messages"]]
        self.assertEqual(roles, ["system", "user", "assistant"])
        user = row["messages"][1]["content"]
        self.assertIn("measuredLevel at AI card slot 7 ch 3: -25 % (display), from HMI", user)
        self.assertIn("highLevelAlarm at LSH-391: 1 (recorded)", user)
        self.assertIn("- Clamp meter on the loop current (TB-8 terminals 23/24, 4.5 min, routine)", user)
        self.assertIn("- openWire: Open circuit in the loop wiring", user)
        self.assertTrue(row["messages"][2]["content"].endswith("CAUSE: openWire\nNEXT_TEST: Clamp meter on the loop current"))
        self.assertNotIn("tools", row)

    def test_questions_without_tests_have_no_next_test_line(self):
        target = prepare.to_chat(ladder("train-2-ladderWhy", "train", 2))["messages"][-1]["content"]
        self.assertTrue(target.endswith("\n\nCAUSE: Low_Air"))
        self.assertNotIn("NEXT_TEST", target)

    def test_transcripts_use_openai_tool_calls(self):
        row = prepare.to_chat(transcript("train-3-toolTranscript", "train", 3))
        self.assertEqual([tool["function"]["name"] for tool in row["tools"]], ["search_objects", "get_object", "related_objects", "get_measurements"])
        messages = row["messages"]
        self.assertEqual([m["role"] for m in messages], ["system", "user", "assistant", "tool", "assistant"])
        call = messages[2]["tool_calls"][0]
        self.assertEqual(call, {"id": "call-1", "type": "function", "function": {"name": "search_objects", "arguments": {"query": "LT-698"}}})
        self.assertEqual(messages[3]["tool_call_id"], "call-1")
        self.assertTrue(messages[4]["content"].startswith("LT-698 shows 17.39 % (display). Next test"))
        self.assertTrue(messages[4]["content"].endswith("CAUSE: contactResistance\nNEXT_TEST: Compare the sight glass with the HMI"))

        text = prepare.to_chat(transcript("train-3-toolTranscript", "train", 3), tool_style="text")
        self.assertNotIn("tools", text)
        self.assertIn('[tool call call-1] search_objects {"query": "LT-698"}', text["messages"][1]["content"])
        self.assertIn("[tool result call-1]", text["messages"][1]["content"])

    def test_completions_format(self):
        row = prepare.to_completion(diagnosis("train-1-diagnosis", "train", 1))
        self.assertEqual(sorted(row), ["completion", "prompt"])
        self.assertTrue(row["prompt"].startswith(prepare.SYSTEM_PROMPT))
        self.assertIn("CAUSE: openWire", row["completion"])

    def test_splits_are_preserved_and_stable(self):
        train = [diagnosis(f"train-{i}-diagnosis", "train", i) for i in range(60)] + [transcript("train-99-toolTranscript", "train", 99)]
        held_out = [diagnosis("eval-1000-diagnosis", "eval", 1000), ladder("eval-1001-ladderWhy", "eval", 1001)]
        with tempfile.TemporaryDirectory() as directory:
            train_path = write(directory, "train.jsonl", train)
            eval_path = write(directory, "eval.jsonl", held_out)
            out = os.path.join(directory, "data")
            counts = prepare.prepare(train_path, eval_path, out, valid_fraction=0.2)
            self.assertEqual(counts["test"], 2)
            self.assertEqual(counts["train"] + counts["valid"], len(train))
            self.assertGreater(counts["valid"], 0)
            first = {name: read(os.path.join(out, f"{name}.jsonl")) for name in ("train", "valid", "test")}
            prepare.prepare(train_path, eval_path, out, valid_fraction=0.2)
            second = {name: read(os.path.join(out, f"{name}.jsonl")) for name in ("train", "valid", "test")}
            self.assertEqual(first, second)
            test_targets = [json.loads(line)["messages"][-1]["content"] for line in first["test"].splitlines()]
            self.assertEqual([t.split("CAUSE: ")[1].split("\n")[0] for t in test_targets], ["openWire", "Low_Air"])
            # Validation membership depends only on the id.
            valid_ids = {example["id"] for example in train if prepare.is_validation(example["id"], 0.2)}
            self.assertEqual(len(valid_ids), counts["valid"])

    def test_rejects_mixed_or_overlapping_splits(self):
        with tempfile.TemporaryDirectory() as directory:
            train_path = write(directory, "train.jsonl", [diagnosis("train-1-diagnosis", "train", 1)])
            wrong = write(directory, "wrong.jsonl", [diagnosis("train-2-diagnosis", "train", 2)])
            overlap = write(directory, "overlap.jsonl", [diagnosis("eval-1-diagnosis", "eval", 1)])
            with self.assertRaisesRegex(ValueError, "another split"):
                prepare.prepare(train_path, wrong, os.path.join(directory, "a"))
            with self.assertRaisesRegex(ValueError, "share scenario seeds"):
                prepare.prepare(train_path, overlap, os.path.join(directory, "b"))
            self.assertEqual(prepare.main(["--train", train_path, "--eval", wrong, "--out", os.path.join(directory, "c")]), 2)

    def test_number_formatting_matches_the_swift_generator(self):
        self.assertEqual([prepare.number(v) for v in (12, 3.70, -25, 0.001, -0.001, 17.385)], ["12", "3.7", "-25", "0", "0", "17.39"])
        self.assertEqual(prepare.cite(12.03, "V", "observed"), "12.03 V (observed)")
        self.assertEqual(prepare.cite(1, "bool", "recorded"), "1 (recorded)")


class EvaluateTests(unittest.TestCase):
    def test_parses_cause_and_next_test_lines(self):
        parsed = evaluate.parse_completion("<think>hmm 99 V</think>LT-1 shows 5 % (display).\n\nCAUSE: openWire\nNEXT_TEST: Clamp meter on the loop current\n")
        self.assertEqual(parsed, {"answer": "LT-1 shows 5 % (display).", "predictedCause": "openWire", "predictedNextTest": "Clamp meter on the loop current"})
        loose = evaluate.parse_completion("**cause:** `supplySag`\nCause: wrongScaling")
        self.assertEqual(loose["predictedCause"], "wrongScaling")
        self.assertIsNone(loose["answer"])
        self.assertEqual(evaluate.parse_completion("no labels"), {"answer": "no labels", "predictedCause": None, "predictedNextTest": None})

    def test_predictions_omit_missing_fields(self):
        self.assertEqual(evaluate.prediction("x", "Cause unclear."), {"id": "x", "answer": "Cause unclear."})
        self.assertEqual(evaluate.prediction("y", ""), {"id": "y"})

    def test_reference_targets_round_trip_to_the_answer_key(self):
        examples = [diagnosis("eval-1-diagnosis", "eval", 1), transcript("eval-2-toolTranscript", "eval", 2), ladder("eval-3-ladderWhy", "eval", 3)]
        predictions = evaluate.predict_all(examples, lambda e: prepare.to_chat(e)["messages"][-1]["content"])
        for example, prediction in zip(examples, predictions):
            self.assertEqual(prediction["id"], example["id"])
            self.assertEqual(prediction["predictedCause"], example["answer"]["cause"])
            self.assertEqual(prediction.get("predictedNextTest"), example["answer"].get("nextTest"))
        self.assertEqual(predictions[0]["answer"], examples[0]["answer"]["text"])

    def test_command_line_with_recorded_responses(self):
        examples = [diagnosis("eval-1-diagnosis", "eval", 1), ladder("eval-3-ladderWhy", "eval", 3)]
        with tempfile.TemporaryDirectory() as directory:
            examples_path = write(directory, "eval.jsonl", examples)
            responses = write(directory, "responses.jsonl", [{"id": "eval-1-diagnosis", "text": "Guess.\nCAUSE: supplySag"}])
            out = os.path.join(directory, "predictions.jsonl")
            self.assertEqual(evaluate.main(["--examples", examples_path, "--responses", responses, "--out", out]), 0)
            rows = prepare.read_jsonl(out)
            self.assertEqual(rows, [{"id": "eval-1-diagnosis", "answer": "Guess.", "predictedCause": "supplySag"}, {"id": "eval-3-ladderWhy"}])


@unittest.skipUnless(os.environ.get("NEXUS_TRAIN_JSONL") and os.environ.get("NEXUS_EVAL_JSONL"), "set NEXUS_TRAIN_JSONL and NEXUS_EVAL_JSONL")
class GeneratedDatasetTests(unittest.TestCase):
    def test_real_generator_output_converts(self):
        train_path = os.environ["NEXUS_TRAIN_JSONL"]
        eval_path = os.environ["NEXUS_EVAL_JSONL"]
        held_out = prepare.read_jsonl(eval_path)
        with tempfile.TemporaryDirectory() as directory:
            counts = prepare.prepare(train_path, eval_path, directory)
            self.assertEqual(counts["test"], len(held_out))
            self.assertEqual(counts["train"] + counts["valid"], len(prepare.read_jsonl(train_path)))
            for name in ("train", "valid", "test"):
                for row in prepare.read_jsonl(os.path.join(directory, f"{name}.jsonl")):
                    self.assertEqual(row["messages"][-1]["role"], "assistant")
                    self.assertIn("\nCAUSE: ", row["messages"][-1]["content"])
        predictions = evaluate.predict_all(held_out, lambda e: prepare.to_chat(e)["messages"][-1]["content"])
        for example, prediction in zip(held_out, predictions):
            self.assertEqual(prediction["predictedCause"], example["answer"]["cause"])
            self.assertEqual(prediction.get("predictedNextTest"), example["answer"].get("nextTest"))


if __name__ == "__main__":
    unittest.main()
