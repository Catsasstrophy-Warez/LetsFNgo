"""Prints the failing tests and their failure messages from `xcresulttool` JSON."""
import json
import sys


def walk(node, depth=0):
    if node.get("result") == "Failed" or node.get("nodeType") == "Failure Message":
        print("  " * depth + node.get("nodeType", "") + ": " + node.get("name", ""))
    for child in node.get("children", []):
        walk(child, depth + 1)


for root in json.load(sys.stdin).get("testNodes", []):
    walk(root)
