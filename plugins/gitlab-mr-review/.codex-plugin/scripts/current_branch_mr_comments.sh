#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Fetch the merge request for the current branch and list its review comments.

Workflow implemented:
1) glab mr list --source-branch <current-branch>
2) glab mr comment list <mr-iid>
3) Print numbered comments so the user can choose which to fix.

Usage:
  current_branch_mr_comments.sh [--mr-index <1-based-index>] [--state <all|resolved|unresolved>] [--select <csv>] [--output-file <path>] [--quiet]

Options:
  --mr-index <n>      If multiple MRs are returned, pick this 1-based index (default: 1).
  --state <value>     Comment filter for glab mr comment list: all|resolved|unresolved (default: all).
  --select <csv>      Comma-separated comment indexes to mark as selected (for follow-up fixes).
  --output-file <p>   Write JSON output to file.
  --quiet             Suppress human-readable summary (JSON still produced).
  -h, --help          Show this help.

Examples:
  current_branch_mr_comments.sh
  current_branch_mr_comments.sh --state unresolved
  current_branch_mr_comments.sh --select 1,3,7
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_binary() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    fail "missing required binary: ${bin}"
  fi
}

extract_json() {
  python3 - <<'PY'
import json
import sys

raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit("No command output to parse as JSON")

decoder = json.JSONDecoder()
for i, ch in enumerate(raw):
    if ch not in "[{":
        continue
    try:
        obj, _ = decoder.raw_decode(raw[i:])
        print(json.dumps(obj))
        raise SystemExit(0)
    except json.JSONDecodeError:
        continue

raise SystemExit("Unable to parse JSON from glab output")
PY
}

run_glab_json() {
  local raw
  local parsed

  if ! raw="$("$@" 2>&1)"; then
    printf '%s\n' "${raw}" >&2
    fail "command failed: $*"
  fi

  if ! parsed="$(printf '%s' "${raw}" | extract_json 2>/tmp/glab_json_err.$$)"; then
    printf '%s\n' "${raw}" >&2
    printf '%s\n' "failed to parse JSON: $(cat /tmp/glab_json_err.$$)" >&2
    rm -f /tmp/glab_json_err.$$
    fail "unexpected non-JSON output from: $*"
  fi
  rm -f /tmp/glab_json_err.$$

  printf '%s' "${parsed}"
}

require_binary git
require_binary glab
require_binary python3

MR_INDEX=1
COMMENT_STATE="all"
SELECT_CSV=""
OUTPUT_FILE=""
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mr-index)
      [[ $# -ge 2 ]] || fail "--mr-index requires a value"
      MR_INDEX="$2"
      shift 2
      ;;
    --state)
      [[ $# -ge 2 ]] || fail "--state requires a value"
      COMMENT_STATE="$2"
      shift 2
      ;;
    --select)
      [[ $# -ge 2 ]] || fail "--select requires a value"
      SELECT_CSV="$2"
      shift 2
      ;;
    --output-file)
      [[ $# -ge 2 ]] || fail "--output-file requires a value"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if ! [[ "${MR_INDEX}" =~ ^[0-9]+$ ]] || [[ "${MR_INDEX}" -lt 1 ]]; then
  fail "--mr-index must be a positive integer"
fi

case "${COMMENT_STATE}" in
  all|resolved|unresolved) ;;
  *)
    fail "--state must be one of: all, resolved, unresolved"
    ;;
esac

branch="$(git branch --show-current)"
[[ -n "${branch}" ]] || fail "could not determine current branch"

mrs_json="$(run_glab_json glab mr list --source-branch "${branch}" --output json)"

selection_tmp="$(mktemp)"
printf '%s' "${SELECT_CSV}" > "${selection_tmp}"

meta_json="$(python3 - "${mrs_json}" "${branch}" "${MR_INDEX}" <<'PY'
import json
import sys

mrs = json.loads(sys.argv[1])
branch = sys.argv[2]
mr_index = int(sys.argv[3])

if not isinstance(mrs, list):
    raise SystemExit("Expected a JSON array from glab mr list")

if not mrs:
    raise SystemExit(f"No merge request found for source branch '{branch}'")

if mr_index > len(mrs):
    raise SystemExit(f"--mr-index {mr_index} is out of range (found {len(mrs)} merge requests)")

selected_mr = mrs[mr_index - 1]
iid = selected_mr.get("iid")
if iid is None:
    iid = selected_mr.get("id")
if iid is None:
    raise SystemExit("Could not find merge request iid in glab output")

payload = {
    "branch": branch,
    "mr_count": len(mrs),
    "selected_mr_index": mr_index,
    "selected_mr_iid": int(iid),
    "selected_mr": selected_mr,
    "merge_requests": mrs,
}

print(json.dumps(payload))
PY
)"

mr_iid="$(python3 - "${meta_json}" <<'PY'
import json
import sys

meta = json.loads(sys.argv[1])
print(meta["selected_mr_iid"])
PY
)"

comments_raw_json="$(run_glab_json glab mr comment list "${mr_iid}" --state "${COMMENT_STATE}" --output json)"

result="$(python3 - "${meta_json}" "${comments_raw_json}" "${selection_tmp}" <<'PY'
import json
import re
import sys
from pathlib import Path

meta = json.loads(sys.argv[1])
discussions = json.loads(sys.argv[2])
select_csv = Path(sys.argv[3]).read_text().strip()

if not isinstance(discussions, list):
    raise SystemExit("Expected a JSON array from glab mr comment list")

def clean_text(text: str) -> str:
    text = text.replace("\r", " ").replace("\n", " ").strip()
    return re.sub(r"\s+", " ", text)

comments = []
for discussion in discussions:
    discussion_id = discussion.get("id")
    resolved = discussion.get("resolved")
    notes = discussion.get("notes") or []

    for note in notes:
        body = note.get("body") or ""
        body_clean = clean_text(body)
        author = note.get("author") or {}
        position = note.get("position") or {}

        file_path = (
            position.get("new_path")
            or position.get("old_path")
            or note.get("file_path")
            or ""
        )
        line = (
            position.get("new_line")
            or position.get("old_line")
            or note.get("line")
        )

        comments.append({
            "discussion_id": discussion_id,
            "note_id": note.get("id"),
            "resolved": resolved,
            "system": bool(note.get("system")),
            "author": author.get("username") or author.get("name") or "unknown",
            "created_at": note.get("created_at"),
            "file_path": file_path,
            "line": line,
            "body": body,
            "body_summary": body_clean[:280],
        })

for idx, comment in enumerate(comments, start=1):
    comment["index"] = idx

selected_indices = []
if select_csv:
    for part in select_csv.split(","):
        token = part.strip()
        if not token:
            continue
        if not token.isdigit():
            raise SystemExit(f"Invalid comment index in --select: {token}")
        selected_indices.append(int(token))

selected = []
if selected_indices:
    valid = {c["index"] for c in comments}
    for idx in selected_indices:
        if idx not in valid:
            raise SystemExit(f"Selected comment index out of range: {idx}")
    wanted = set(selected_indices)
    selected = [c for c in comments if c["index"] in wanted]

payload = {
    "branch": meta["branch"],
    "mr_count": meta["mr_count"],
    "selected_mr_index": meta["selected_mr_index"],
    "selected_mr_iid": meta["selected_mr_iid"],
    "selected_mr": meta["selected_mr"],
    "comment_count": len(comments),
    "comments": comments,
    "selected_comment_indices": selected_indices,
    "selected_comments": selected,
}

print(json.dumps(payload, indent=2))
PY
)"

rm -f "${selection_tmp}"

if [[ "${QUIET}" -eq 0 ]]; then
  python3 - "${result}" <<'PY' >&2
import json
import sys

payload = json.loads(sys.argv[1])
mr = payload["selected_mr"]
iid = payload["selected_mr_iid"]
title = mr.get("title", "(no title)")
url = mr.get("web_url", "")

print(f"Branch: {payload['branch']}")
print(f"Selected MR: !{iid} - {title}")
if url:
    print(f"MR URL: {url}")
print(f"Comments found: {payload['comment_count']}")
print("")

for c in payload["comments"]:
    status = "resolved" if c.get("resolved") else "unresolved"
    loc = ""
    if c.get("file_path"):
        loc = c["file_path"]
        if c.get("line") is not None:
            loc = f"{loc}:{c['line']}"
    if not loc:
        loc = "general"

    summary = c.get("body_summary") or ""
    print(f"[{c['index']}] ({status}) {loc} - {summary}")

if payload["comment_count"]:
    print("")
    print("Next: pick comment indexes to fix, then rerun with --select <csv>.")
PY
fi

if [[ -n "${OUTPUT_FILE}" ]]; then
  printf '%s\n' "${result}" > "${OUTPUT_FILE}"
else
  printf '%s\n' "${result}"
fi
