"""Require each live K XCTest leaf to pass; suite summaries are never execution evidence."""
import argparse
import json
from pathlib import Path


REQUIRED = tuple("AegisTests/AccessEmbeddedCoreLiveTests/" + name + "()" for name in (
    "testLocalConfigImportsAsRealityVision",
    "testEmbeddedCoreStartsAndDialsCleartextHTTP",
    "testProductPublisherStartsListenerAndConnectTunnel",
))


def evaluate(document):
    results = {identifier: [] for identifier in REQUIRED}

    def walk(node, bundle=""):
        if isinstance(node, list):
            for item in node:
                walk(item, bundle)
        elif isinstance(node, dict):
            kind = node.get("nodeType", "")
            if kind in ("Unit test bundle", "Test Bundle"):
                bundle = node.get("nodeIdentifier") or node.get("name", "")
                bundle = bundle.removesuffix(".xctest")
            # xcresult attaches skip/failure messages below a test case. Those
            # diagnostics do not turn the case into a suite or hide its outcome.
            diagnostic_children = all(
                isinstance(child, dict) and child.get("nodeType") in ("Skip Message", "Failure Message", "Attachment")
                for child in node.get("children", [])
            )
            if kind == "Test Case" and diagnostic_children:
                identifier = node.get("testIdentifier") or node.get("nodeIdentifier") or node.get("identifier", "")
                if identifier.startswith("AccessEmbeddedCoreLiveTests/") and bundle == "AegisTests":
                    identifier = bundle + "/" + identifier
                if identifier and not identifier.endswith("()"):
                    identifier += "()"
                if identifier in results:
                    results[identifier].append(node.get("result", "Unknown"))
            for key, value in node.items():
                if isinstance(value, (list, dict)):
                    walk(value, bundle)

    walk(document)
    return {"status": "PASS" if all(rows and all(row == "Passed" for row in rows)
                                     for rows in results.values()) else "FAIL",
            "requiredTestCases": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = evaluate(json.loads(args.tests.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "PASS" else 4


if __name__ == "__main__":
    raise SystemExit(main())
