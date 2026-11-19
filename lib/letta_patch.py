#!/usr/bin/env python3
"""Apply local hotfix patches to the installed @letta-ai/letta-code package.

Each patch is a directory under the patches dir:

    <id>/patch.json        {"description", "upstream", "target", "obsolete_if", "edits": [...]}
    <id>/edits/NN-*.find   exact text that must occur once in the target
    <id>/edits/NN-*.replace  its replacement

A patch applies all of its edits or none. Applied patches leave a marker line at
the end of the target so re-runs are no-ops; `npm i -g` replaces the file, after
which the patch is applied again. A patch is "obsolete" when the target already
contains its `obsolete_if` text (the fix landed upstream), and "broken" when an
edit's text is missing or ambiguous (the upstream code changed).

Usage: letta_patch.py apply|status PATCHES_DIR PACKAGE_DIR [--disabled id,id]
Prints one tab-separated line per patch: id, status, version, detail.
Statuses: applied (now), active (already applied), pending (status only: would
apply), obsolete, broken, disabled.
"""

import hashlib
import json
import os
import sys
import tempfile

MARKER = "// letta-server-ops patch: "


def load_patch(patch_dir):
    with open(os.path.join(patch_dir, "patch.json"), encoding="utf-8") as f:
        meta = json.load(f)
    edits = []
    for edit in meta["edits"]:
        with open(os.path.join(patch_dir, "edits", edit["find"]), encoding="utf-8") as f:
            find = f.read()
        with open(os.path.join(patch_dir, "edits", edit["replace"]), encoding="utf-8") as f:
            replace = f.read()
        edits.append((edit["find"], find, replace))
    digest = hashlib.sha256(
        json.dumps(meta, sort_keys=True).encode()
        + b"".join(f.encode() + r.encode() for _, f, r in edits)
    ).hexdigest()[:12]
    return meta, edits, digest


def write_atomic(path, content):
    mode = os.stat(path).st_mode
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".letta-ops-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def process(action, patches_dir, package_dir, disabled):
    with open(os.path.join(package_dir, "package.json"), encoding="utf-8") as f:
        version = json.load(f).get("version", "?")
    contents = {}
    results = []
    for patch_id in sorted(os.listdir(patches_dir)):
        patch_dir = os.path.join(patches_dir, patch_id)
        if not os.path.isfile(os.path.join(patch_dir, "patch.json")):
            continue
        if patch_id in disabled or os.path.exists(os.path.join(patch_dir, "disabled")):
            results.append((patch_id, "disabled", ""))
            continue
        try:
            meta, edits, digest = load_patch(patch_dir)
        except (OSError, ValueError, KeyError) as err:
            results.append((patch_id, "broken", f"invalid patch definition: {err}"))
            continue
        target = os.path.join(package_dir, meta.get("target", "letta.js"))
        if target not in contents:
            with open(target, encoding="utf-8") as f:
                contents[target] = f.read()
        text = contents[target]
        marker = f"{MARKER}{patch_id} {digest}\n"
        if marker in text:
            results.append((patch_id, "active", ""))
            continue
        if f"{MARKER}{patch_id} " in text:
            results.append((patch_id, "broken", "an older version of this patch is applied; reinstall letta-code to reapply"))
            continue
        obsolete_if = meta.get("obsolete_if")
        if obsolete_if and obsolete_if in text:
            results.append((patch_id, "obsolete", f"target already contains {obsolete_if!r}"))
            continue
        problems = []
        for name, find, _ in edits:
            count = text.count(find)
            if count != 1:
                problems.append(f"{name}: expected 1 match, found {count}")
        if problems:
            results.append((patch_id, "broken", "; ".join(problems)))
            continue
        if action == "status":
            results.append((patch_id, "pending", "not applied yet"))
            continue
        for _, find, replace in edits:
            text = text.replace(find, replace, 1)
        if not text.endswith("\n"):
            text += "\n"
        contents[target] = text + marker
        write_atomic(target, contents[target])
        results.append((patch_id, "applied", meta.get("description", "")))
    for patch_id, status, detail in results:
        print(f"{patch_id}\t{status}\t{version}\t{detail}")


def main(argv):
    if len(argv) < 4 or argv[1] not in ("apply", "status"):
        print("usage: letta_patch.py apply|status PATCHES_DIR PACKAGE_DIR [--disabled id,id]", file=sys.stderr)
        return 2
    disabled = set()
    if "--disabled" in argv:
        disabled = {p for p in argv[argv.index("--disabled") + 1].split(",") if p}
    process(argv[1], argv[2], argv[3], disabled)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
