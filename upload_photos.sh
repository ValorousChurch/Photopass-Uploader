#!/bin/zsh

set -euo pipefail
setopt null_glob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${UPLOAD_CONFIG_FILE:-$SCRIPT_DIR/upload_config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

INCLUDE_QR=false
INCLUDE_UNKNOWN=false
VERBOSE=false
DRY_RUN=false
ITEM_PATH=""

usage() {
  cat <<'EOF'
Usage:
  ./upload_photos.sh [options] path/to/file-or-folder

Options:
  --include-qr        Upload _QR-* marker images. By default they are skipped.
  --include-unknown   Upload files in folders named "unknown". By default they are skipped.
  --dry-run           Print the files that would upload without contacting Rock.
  --verbose, -v       Print upload details for each file.
  --help, -h          Show this help.

Environment:
  UPLOAD_CONFIG_FILE  Optional. Defaults to ./upload_config.env next to this script.
  ROCK_URL            Required. Base url of your Rock server.
  ROCK_API_KEY        Required. Rock API key. See README.ms for required permissions.
  FILE_TYPE_GUID      Required. The GUID of the Rock file type to use for uploads.
  WORKFLOW_TYPE_ID    Required. The ID of the Rock workflow type to fire for each upload.
  FILE_ATTRIBUTE_KEY  Required. The workflow attribute key to use for passing the uploaded file's GUID.
  CODE_ATTRIBUTE_KEY  Required. The workflow attribute key to use for passing the code for the file.
EOF
}

die() {
  print -u2 -- "Error: $*"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-qr)
      INCLUDE_QR=true
      ;;
    --include-unknown)
      INCLUDE_UNKNOWN=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --verbose|-v)
      VERBOSE=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -n "$ITEM_PATH" ]]; then
        die "Only one file or folder path may be provided."
      fi
      ITEM_PATH="$1"
      ;;
  esac
  shift
done

[[ -n "$ITEM_PATH" ]] || {
  usage
  exit 1
}

[[ -n "${ROCK_URL:-}" ]] || die "ROCK_URL is required. Configure it in upload_config.env or the environment."
[[ -n "${ROCK_API_KEY:-}" ]] || die "ROCK_API_KEY is required. Configure it in upload_config.env or the environment."
[[ -n "${FILE_TYPE_GUID:-}" ]] || die "FILE_TYPE_GUID is required. Configure it in upload_config.env or the environment."
[[ -n "${WORKFLOW_TYPE_ID:-}" ]] || die "WORKFLOW_TYPE_ID is required. Configure it in upload_config.env or the environment."
[[ -n "${FILE_ATTRIBUTE_KEY:-}" ]] || die "FILE_ATTRIBUTE_KEY is required. Configure it in upload_config.env or the environment."
[[ -n "${CODE_ATTRIBUTE_KEY:-}" ]] || die "CODE_ATTRIBUTE_KEY is required. Configure it in upload_config.env or the environment."
[[ -e "$ITEM_PATH" ]] || die "Invalid file or directory: $ITEM_PATH"

is_supported_image() {
  local file="$1"
  case "${file:l}" in
    *.jpg|*.jpeg|*.png|*.heic|*.heif|*.tif|*.tiff|*.bmp|*.gif|*.webp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

should_upload_file() {
  local file="$1"
  local name="${file:t}"
  local parent="${file:h:t}"

  is_supported_image "$file" || return 1

  if [[ "$INCLUDE_QR" == false && "$name" == _QR-* ]]; then
    return 1
  fi

  if [[ "$INCLUDE_UNKNOWN" == false && "${parent:l}" == "unknown" ]]; then
    return 1
  fi

  return 0
}

json_field() {
  local field="$1"
  python3 -c 'import json, sys
field = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = data.get(field)
if value is None:
    sys.exit(1)
print(value)' "$field"
}

url_encode() {
  python3 -c 'import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

code_for_file() {
  local file="$1"
  print -r -- "${file:h:t}"
}

print_upload_progress() {
  local current="$1"
  local total="$2"

  if [[ -t 1 ]]; then
    printf '\rUploading %d of %d images' "$current" "$total"
  else
    printf 'Uploading %d of %d images\n' "$current" "$total"
  fi
}

upload_file() {
  local file="$1"
  local response_file http_status guid

  response_file="$(mktemp /tmp/photo_pass_upload_response.XXXXXX)"
  http_status="$(
    curl \
      --silent \
      --show-error \
      --output "$response_file" \
      --write-out "%{http_code}" \
      --request POST \
      --header "Authorization-Token: $ROCK_API_KEY" \
      --form "Files=@${file}" \
      "$ROCK_URL/ImageUploader.ashx?isBinaryFile=T&fileId=&fileTypeGuid=$FILE_TYPE_GUID"
  )"

  if [[ "$http_status" != "200" ]]; then
    print -u2 -- "Upload failed for $file. Response: [$http_status] $(<"$response_file")"
    rm -f "$response_file"
    exit 1
  fi

  if ! guid="$(json_field Guid < "$response_file")" || [[ -z "$guid" ]]; then
    print -u2 -- "Upload failed for $file. Response: [$http_status] $(<"$response_file")"
    rm -f "$response_file"
    exit 1
  fi

  rm -f "$response_file"
  print -r -- "$guid"
}

fire_workflow() {
  local file_guid="$1"
  local code="$2"
  local response_file http_status
  local encoded_guid encoded_code

  encoded_guid="$(url_encode "$file_guid")"
  encoded_code="$(url_encode "$code")"

  response_file="$(mktemp /tmp/photo_pass_workflow_response.XXXXXX)"
  http_status="$(
    curl \
      --silent \
      --show-error \
      --output "$response_file" \
      --write-out "%{http_code}" \
      --request POST \
      --header "Authorization-Token: $ROCK_API_KEY" \
      --header "Content-Length: 0" \
      --data-binary "" \
      "$ROCK_URL/api/workflows/workflowentry/${WORKFLOW_TYPE_ID}?${FILE_ATTRIBUTE_KEY}=${encoded_guid}&${CODE_ATTRIBUTE_KEY}=${encoded_code}"
  )"

  if [[ "$http_status" != "200" ]]; then
    print -u2 -- "Workflow fire failed for file GUID $file_guid. Response: [$http_status] $(<"$response_file")"
    rm -f "$response_file"
    exit 1
  fi

  rm -f "$response_file"
}

print -- "Finding uploadable image files in $ITEM_PATH..."
typeset -a files
if [[ -d "$ITEM_PATH" ]]; then
  for file in "$ITEM_PATH"/**/*(.N); do
    if should_upload_file "$file"; then
      files+=("$file")
    fi
  done
else
  if should_upload_file "$ITEM_PATH"; then
    files+=("$ITEM_PATH")
  fi
fi
files=("${(@o)files}")

total="${#files[@]}"
if [[ "$total" -eq 0 ]]; then
  print -- "No uploadable image files found."
  exit 0
fi

print -- "Uploading $total image files."

if [[ "$DRY_RUN" == true ]]; then
  print -- "Dry run only; no files will be uploaded."
  processed=0
  for file in "${files[@]}"; do
    processed=$((processed + 1))
    print_upload_progress "$processed" "$total"
    print -- "$(code_for_file "$file"): $file"
  done
  if [[ -t 1 ]]; then
    printf '\n'
  fi
  exit 0
fi

processed=0
for file in "${files[@]}"; do
  processed=$((processed + 1))
  print_upload_progress "$processed" "$total"

  if [[ "$VERBOSE" == true ]]; then
    print -- "$file"
  fi

  guid="$(upload_file "$file")"
  fire_workflow "$guid" "$(code_for_file "$file")"
done

if [[ -t 1 ]]; then
  printf '\n'
fi
printf 'Uploaded %d files.\n' "$processed"
