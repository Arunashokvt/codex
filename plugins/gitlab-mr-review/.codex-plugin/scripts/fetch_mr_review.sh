#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Fetch a GitLab merge request and its review comments using glab.

Usage:
  fetch_mr_review.sh --mr-url <url> [--hostname <host>] [--no-notes] [--no-discussions] [--output-file <path>]
  fetch_mr_review.sh --project <group/project> --iid <mr_iid> [--hostname <host>] [--no-notes] [--no-discussions] [--output-file <path>]

Examples:
  fetch_mr_review.sh --mr-url "https://gitlab.com/my-group/my-project/-/merge_requests/42"
  fetch_mr_review.sh --project "my-group/my-project" --iid 42 --hostname gitlab.com

Notes:
  - Requires an authenticated glab session (run: glab auth status).
  - Output JSON includes:
      - merge_request
      - discussions (unless --no-discussions)
      - notes (unless --no-notes)
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

url_encode_project() {
  local raw="$1"
  python3 - "${raw}" <<'PY'
import sys
import urllib.parse

value = sys.argv[1]
if value.isdigit():
    print(value)
else:
    print(urllib.parse.quote(value, safe=""))
PY
}

parse_mr_url() {
  local mr_url="$1"

  local stripped="${mr_url#http://}"
  stripped="${stripped#https://}"

  local host_part="${stripped%%/*}"
  local rest="${stripped#*/}"

  if [[ "${rest}" =~ ^(.+)/-/merge_requests/([0-9]+)(/?)(\?.*)?$ ]]; then
    local project_from_url="${BASH_REMATCH[1]}"
    local iid_from_url="${BASH_REMATCH[2]}"
    echo "${host_part}"$'\t'"${project_from_url}"$'\t'"${iid_from_url}"
    return 0
  fi

  return 1
}

require_binary glab
require_binary python3

PROJECT=""
IID=""
MR_URL=""
HOSTNAME=""
OUTPUT_FILE=""
INCLUDE_NOTES=1
INCLUDE_DISCUSSIONS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || fail "--project requires a value"
      PROJECT="$2"
      shift 2
      ;;
    --iid)
      [[ $# -ge 2 ]] || fail "--iid requires a value"
      IID="$2"
      shift 2
      ;;
    --mr-url)
      [[ $# -ge 2 ]] || fail "--mr-url requires a value"
      MR_URL="$2"
      shift 2
      ;;
    --hostname)
      [[ $# -ge 2 ]] || fail "--hostname requires a value"
      HOSTNAME="$2"
      shift 2
      ;;
    --output-file)
      [[ $# -ge 2 ]] || fail "--output-file requires a value"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --no-notes)
      INCLUDE_NOTES=0
      shift
      ;;
    --no-discussions)
      INCLUDE_DISCUSSIONS=0
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

if [[ -n "${MR_URL}" ]]; then
  if ! parsed="$(parse_mr_url "${MR_URL}")"; then
    fail "unable to parse --mr-url. Expected .../<group>/<project>/-/merge_requests/<iid>"
  fi

  parsed_host="$(echo "${parsed}" | cut -f1)"
  parsed_project="$(echo "${parsed}" | cut -f2)"
  parsed_iid="$(echo "${parsed}" | cut -f3)"

  if [[ -z "${HOSTNAME}" ]]; then
    HOSTNAME="${parsed_host}"
  fi

  if [[ -n "${PROJECT}" && "${PROJECT}" != "${parsed_project}" ]]; then
    fail "--project does not match project parsed from --mr-url"
  fi

  if [[ -n "${IID}" && "${IID}" != "${parsed_iid}" ]]; then
    fail "--iid does not match iid parsed from --mr-url"
  fi

  PROJECT="${parsed_project}"
  IID="${parsed_iid}"
fi

if [[ -z "${PROJECT}" || -z "${IID}" ]]; then
  fail "provide either --mr-url, or both --project and --iid"
fi

if ! [[ "${IID}" =~ ^[0-9]+$ ]]; then
  fail "--iid must be numeric (merge request IID)"
fi

project_id="$(url_encode_project "${PROJECT}")"
endpoint="projects/${project_id}/merge_requests/${IID}"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

host_args=()
if [[ -n "${HOSTNAME}" ]]; then
  host_args=(--hostname "${HOSTNAME}")
fi

glab api "${host_args[@]}" "${endpoint}" > "${tmp_dir}/mr.json"

if [[ "${INCLUDE_DISCUSSIONS}" -eq 1 ]]; then
  glab api "${host_args[@]}" --paginate "${endpoint}/discussions" > "${tmp_dir}/discussions.json"
fi

if [[ "${INCLUDE_NOTES}" -eq 1 ]]; then
  glab api "${host_args[@]}" --paginate "${endpoint}/notes" > "${tmp_dir}/notes.json"
fi

result="$(python3 - "${tmp_dir}/mr.json" "${tmp_dir}/discussions.json" "${tmp_dir}/notes.json" "${PROJECT}" "${IID}" "${HOSTNAME}" <<'PY'
import json
import sys
from pathlib import Path

mr_path = Path(sys.argv[1])
discussions_path = Path(sys.argv[2])
notes_path = Path(sys.argv[3])
project = sys.argv[4]
iid = sys.argv[5]
hostname = sys.argv[6]

with mr_path.open() as f:
    mr = json.load(f)

def load_optional(path: Path):
    if not path.exists():
        return None
    with path.open() as f:
        return json.load(f)

payload = {
    "source": {
        "project": project,
        "merge_request_iid": int(iid),
    },
    "merge_request": mr,
}

if hostname:
    payload["source"]["hostname"] = hostname

discussions = load_optional(discussions_path)
if discussions is not None:
    payload["discussions"] = discussions

notes = load_optional(notes_path)
if notes is not None:
    payload["notes"] = notes

print(json.dumps(payload, indent=2))
PY
)"

if [[ -n "${OUTPUT_FILE}" ]]; then
  printf '%s\n' "${result}" > "${OUTPUT_FILE}"
else
  printf '%s\n' "${result}"
fi
