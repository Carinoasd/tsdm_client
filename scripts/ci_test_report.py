#!/usr/bin/env python3
"""Turn `flutter test --file-reporter json:<file>` reports into a Markdown summary.

Usage: ci_test_report.py [--strict] [--jobs-result <result>] <report.json> [...]

--strict             exit 1 when a report is missing or incomplete
--jobs-result <r>    result of the jobs that wrote the reports (e.g. "failure");
                     a non-success result is shown even when every test passed

Writes Markdown to stdout (meant for $GITHUB_STEP_SUMMARY): totals, then every
failed test with its file and name, and the first lines of each error in a
collapsed block. A report that is missing or ends without a `done` event is
reported as such, so a crashed or cancelled run never looks green here.
"""

import html
import json
import os
import sys

MAX_DETAILED = 40
MAX_ERROR_LINES = 30
MAX_ERROR_CHARS = 4000


def relative(path):
    if not path:
        return "?"
    path = path.removeprefix("file://")
    cwd = os.getcwd().rstrip("/") + "/"
    if path.startswith(cwd):
        path = path[len(cwd):]
    return path


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ").strip()


def parse(report_path):
    result = {
        "path": report_path,
        "missing": False,
        "finished": False,
        "success": False,
        "passed": 0,
        "failed": [],
        "skipped": 0,
        "seconds": None,
    }
    if not os.path.exists(report_path):
        result["missing"] = True
        return result
    suites = {}
    tests = {}
    errors = {}
    outcomes = {}
    last_time = 0
    with open(report_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            last_time = max(last_time, event.get("time") or 0)
            kind = event.get("type")
            if kind == "suite":
                suite = event["suite"]
                suites[suite["id"]] = relative(suite.get("path"))
            elif kind == "testStart":
                test = event["test"]
                tests[test["id"]] = test
            elif kind == "error":
                text = (event.get("error") or "").rstrip()
                stack = (event.get("stackTrace") or "").rstrip()
                if stack:
                    text = f"{text}\n{stack}"
                errors.setdefault(event["testID"], []).append(text)
            elif kind == "testDone":
                outcomes[event["testID"]] = event
            elif kind == "done":
                result["finished"] = True
                result["success"] = bool(event.get("success"))
    # Outcomes are read after the whole file: an error can arrive after `testDone`
    # ("This test failed after it had already completed"), and it fails that test.
    for test_id, event in outcomes.items():
        test = tests.get(test_id, {})
        if event.get("skipped") and test_id not in errors:
            result["skipped"] += 1
        elif event.get("result") == "success" and test_id not in errors:
            # Hidden entries are the per-file "loading" pseudo tests.
            if not event.get("hidden"):
                result["passed"] += 1
        else:
            name = test.get("name") or "?"
            if name.startswith("loading "):
                name = "(failed to load: compile error or crash in setup)"
            result["failed"].append(
                {
                    "file": suites.get(test.get("suiteID"), "?"),
                    "line": test.get("root_line") or test.get("line"),
                    "name": name,
                    "error": "\n\n".join(errors.get(test_id, [])),
                }
            )
    result["seconds"] = round(last_time / 1000) if last_time else None
    return result


def trim(text):
    lines = text.splitlines()
    clipped = len(lines) > MAX_ERROR_LINES
    text = "\n".join(lines[:MAX_ERROR_LINES])
    if len(text) > MAX_ERROR_CHARS:
        text = text[:MAX_ERROR_CHARS]
        clipped = True
    if clipped:
        text += "\n..."
    return text.replace("```", "'''")


def main(argv):
    strict = False
    jobs_result = None
    paths = []
    args = iter(argv)
    for arg in args:
        if arg == "--strict":
            strict = True
        elif arg == "--jobs-result":
            jobs_result = next(args, None)
        else:
            paths.append(arg)
    if not paths:
        sys.exit(__doc__)
    results = [parse(path) for path in paths]
    out = []
    failed = [f for r in results for f in r["failed"]]
    broken = [r for r in results if r["missing"] or not r["finished"]]
    # A run can fail without a failed test to point at (e.g. an error in tearDownAll).
    unlocated = [r for r in results if r["finished"] and not r["success"] and not r["failed"]]

    if failed:
        out.append(f"### :x: {len(failed)} failed test(s)")
    elif broken:
        out.append("### :warning: Test run incomplete")
    elif unlocated:
        out.append("### :x: Test run failed outside any single test; see the job log")
    elif jobs_result and jobs_result != "success":
        out.append(f"### :x: Shard jobs: {jobs_result} (tests passed; analyzing or setup failed, see the logs)")
    else:
        out.append("### :white_check_mark: All tests passed")
    out.append("")
    out.append("| Report | Passed | Failed | Skipped | Time |")
    out.append("| --- | ---: | ---: | ---: | ---: |")
    for r in results:
        label = os.path.basename(os.path.dirname(r["path"])) or r["path"]
        if r["missing"]:
            out.append(f"| {cell(label)} | - | - | - | report missing |")
            continue
        seconds = r["seconds"]
        time = f"{seconds // 60}m {seconds % 60:02d}s" if seconds is not None else "-"
        if not r["finished"]:
            time += " (incomplete)"
        elif not r["success"] and not r["failed"]:
            time += " (failed, see log)"
        out.append(f"| {cell(label)} | {r['passed']} | {len(r['failed'])} | {r['skipped']} | {time} |")
    out.append("")

    if failed:
        out.append("| File | Test |")
        out.append("| --- | --- |")
        for f in failed:
            where = f["file"] + (f":{f['line']}" if f["line"] else "")
            out.append(f"| `{cell(where)}` | {cell(f['name'])} |")
        out.append("")
        for f in failed[:MAX_DETAILED]:
            out.append(
                f"<details><summary><code>{html.escape(f['file'])}</code>: "
                f"{html.escape(f['name'].replace(chr(10), ' '))}</summary>"
            )
            out.append("")
            out.append("```")
            out.append(trim(f["error"]) or "(no error output)")
            out.append("```")
            out.append("</details>")
        if len(failed) > MAX_DETAILED:
            out.append("")
            out.append(f"Errors of the remaining {len(failed) - MAX_DETAILED} failures are in the job logs.")
    print("\n".join(out))
    if strict and broken:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
