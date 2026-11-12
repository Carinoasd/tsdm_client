#!/usr/bin/env python3
"""Turn `flutter test --file-reporter json:<file>` reports into a Markdown summary.

Usage: ci_test_report.py <report.json> [<report.json> ...]

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
    path = path.replace("file://", "")
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
                test = tests.get(event["testID"], {})
                if event.get("skipped"):
                    result["skipped"] += 1
                elif event.get("result") == "success":
                    # Hidden entries are the per-file "loading" pseudo tests.
                    if not event.get("hidden"):
                        result["passed"] += 1
                else:
                    name = test.get("name") or "?"
                    file_path = suites.get(test.get("suiteID"), "?")
                    if name.startswith("loading "):
                        name = "(failed to load: compile error or crash in setup)"
                    line_no = test.get("root_line") or test.get("line")
                    result["failed"].append(
                        {
                            "file": file_path,
                            "line": line_no,
                            "name": name,
                            "error": "\n\n".join(errors.get(event["testID"], [])),
                        }
                    )
            elif kind == "done":
                result["finished"] = True
                result["success"] = bool(event.get("success"))
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


def main(paths):
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


if __name__ == "__main__":
    main(sys.argv[1:])
