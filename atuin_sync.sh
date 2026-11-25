#!/usr/bin/env bash
# Two-way directory sync over Atuin's KV store (end-to-end encrypted by Atuin).
# Usage: atuin_sync.sh /syncdir     Env: ATUIN_KV_NAMESPACE, INTERVAL, CHUNK_BYTES
#
# Keys:  chunk.<sha256>.<n>      base64 slice of a file's content
#        manifest.<id>           JSON {path_b64,sha256,size,chunks,ts}; id = sha256(path NUL hash)
# Local state lives in $ROOT/.atuin-sync (never synced):
#        seen/<id>               manifest already processed
#        paths/<sha256(path)>    "<ts> <sha256>" of the version last synced for that path
# Limits: deletions are not propagated; edits on both sides become *.conflict-* copies.
set -euo pipefail

ROOT=${1:?Usage: atuin_sync.sh /syncdir}
NS=${ATUIN_KV_NAMESPACE:-file-xfer}
INTERVAL=${INTERVAL:-20}
CHUNK_BYTES=${CHUNK_BYTES:-70000}   # base64 grows 4/3 -> ~93 KB per value

command -v atuin >/dev/null   || { echo "atuin not found in PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found in PATH" >&2; exit 1; }

mkdir -p -- "$ROOT"
ROOT=$(cd -- "$ROOT" && pwd -P)
STATE=$ROOT/.atuin-sync
mkdir -p -- "$STATE/seen" "$STATE/paths" "$STATE/tmp"   # tmp inside ROOT: same fs, never /tmp
trap 'rm -rf -- "$STATE/tmp"; mkdir -p -- "$STATE/tmp"' EXIT
trap 'exit 130' INT TERM

log() { echo "[$(date +%T)] $*" >&2; }

kv_set() { atuin kv set -n "$NS" --key "$1" "$2" >/dev/null; }
kv_get() { atuin kv get -n "$NS" "$1" 2>/dev/null || true; }

sync_now() {
  atuin sync >/dev/null || log "warning: atuin sync failed (offline? not logged in?)"
  # Records arrive in the record store; make sure they're built into the KV view.
  atuin kv rebuild >/dev/null 2>&1 || true
}

sha_of()   { sha256sum -- "$1" | cut -d' ' -f1; }
sha_str()  { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
ledger()   { cat -- "$STATE/paths/$(sha_str "$1")" 2>/dev/null || echo "0 -"; }
set_ledger() { printf '%s %s\n' "$2" "$3" > "$STATE/paths/$(sha_str "$1")"; }

manifest_keys() {
  atuin kv list -n "$NS" | grep -oE 'manifest\.[[:xdigit:]]{64}' | sort -u || true
}

publish_file() {
  local file=$1 rel=${1#"$ROOT"/} hash size id key count ts tmp i path_b64 manifest
  hash=$(sha_of "$file")
  read -r _ led_hash < <(ledger "$rel")
  [[ "$hash" != "$led_hash" ]] || return 0          # unchanged since last sync

  id=$(printf '%s\0%s' "$rel" "$hash" | sha256sum | cut -d' ' -f1)
  key=manifest.$id
  if [[ -n "$(kv_get "$key")" ]]; then               # already published (e.g. by us earlier)
    set_ledger "$rel" "$(date +%s)" "$hash"; touch -- "$STATE/seen/$id"; return 0
  fi

  size=$(stat -c %s -- "$file")
  tmp=$(mktemp -d -p "$STATE/tmp")
  python3 - "$file" "$tmp" "$CHUNK_BYTES" <<'PY'
import base64, pathlib, sys
src, dest, size = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
with src.open("rb") as f:
    i = 0
    while data := f.read(size):
        (dest / str(i)).write_text(base64.b64encode(data).decode("ascii"))
        i += 1
PY
  count=$(find "$tmp" -type f | wc -l)
  for ((i=0; i<count; i++)); do
    kv_set "chunk.$hash.$i" "$(<"$tmp/$i")"
  done
  rm -rf -- "$tmp"

  # The file may have changed while we were chunking it; bail and retry next round.
  [[ "$(sha_of "$file")" == "$hash" ]] || { log "changed during upload, retrying: $rel"; return 0; }

  sync_now                                            # chunks first, manifest second
  ts=$(date +%s)
  path_b64=$(python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode())' "$rel")
  manifest=$(python3 -c 'import json,sys; print(json.dumps({"path_b64":sys.argv[1],"sha256":sys.argv[2],"size":int(sys.argv[3]),"chunks":int(sys.argv[4]),"ts":int(sys.argv[5])},separators=(",",":")))' \
             "$path_b64" "$hash" "$size" "$count" "$ts")
  kv_set "$key" "$manifest"
  sync_now
  touch -- "$STATE/seen/$id"
  set_ledger "$rel" "$ts" "$hash"
  log "Published: $rel ($count chunk(s))"
}

fetch_manifest() {
  local mkey=$1 id=${1#manifest.} manifest meta rel hash exp_size count ts i chunk tmp dest
  [[ ! -e "$STATE/seen/$id" ]] || return 0
  manifest=$(kv_get "$mkey"); [[ -n "$manifest" ]] || return 0

  mapfile -t meta < <(python3 - "$manifest" <<'PY' 2>/dev/null
import base64, json, sys
m = json.loads(sys.argv[1])
print(base64.urlsafe_b64decode(m["path_b64"] + "===").decode())
print(m["sha256"]); print(int(m["size"])); print(int(m["chunks"])); print(int(m.get("ts", 0)))
PY
  ) || true
  if (( ${#meta[@]} != 5 )); then log "bad manifest $mkey, ignoring"; touch -- "$STATE/seen/$id"; return 0; fi
  rel=${meta[0]} hash=${meta[1]} exp_size=${meta[2]} count=${meta[3]} ts=${meta[4]}

  case "$rel" in   # reject absolute paths, traversal, our own state dir
    ""|/*|..|../*|*/../*|*/..|.atuin-sync|.atuin-sync/*|*$'\n'*)
      log "unsafe manifest path, ignoring: $mkey"; touch -- "$STATE/seen/$id"; return 0 ;;
  esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { touch -- "$STATE/seen/$id"; return 0; }

  dest=$ROOT/$rel
  local led_ts led_hash local_hash=-
  read -r led_ts led_hash < <(ledger "$rel")
  [[ -f "$dest" ]] && local_hash=$(sha_of "$dest")

  # Already have this content, or a newer version was already applied.
  if [[ "$local_hash" == "$hash" ]]; then set_ledger "$rel" "$ts" "$hash"; touch -- "$STATE/seen/$id"; return 0; fi
  if (( ts <= led_ts )); then touch -- "$STATE/seen/$id"; return 0; fi

  tmp=$(mktemp -p "$STATE/tmp")
  for ((i=0; i<count; i++)); do
    chunk=$(kv_get "chunk.$hash.$i")
    [[ -n "$chunk" ]] || { rm -f -- "$tmp"; return 0; }        # not synced yet; retry later
    printf '%s' "$chunk" | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))' >> "$tmp" \
      || { rm -f -- "$tmp"; return 0; }
  done
  if [[ "$(stat -c %s -- "$tmp")" != "$exp_size" || "$(sha_of "$tmp")" != "$hash" ]]; then
    rm -f -- "$tmp"; return 0                                  # corrupt/incomplete; retry later
  fi

  mkdir -p -- "$(dirname -- "$dest")"
  if [[ -e "$dest" && "$local_hash" != "$led_hash" ]]; then
    dest="$dest.conflict-${hash:0:12}"                         # local edits: keep both
    log "Conflict, saved as: ${dest#"$ROOT"/}"
    mv -- "$tmp" "$dest"
  else
    mv -- "$tmp" "$dest"                                       # unmodified locally or new: update
    set_ledger "$rel" "$ts" "$hash"
    log "Received: $rel"
  fi
  touch -- "$STATE/seen/$id"
}

while :; do
  sync_now

  while IFS= read -r -d '' file; do
    publish_file "$file" || log "publish failed: ${file#"$ROOT"/}"
  done < <(find "$ROOT" -path "$STATE" -prune -o -type f ! -name '*.conflict-*' ! -name '.*.swp' ! -name '*~' -print0)

  while IFS= read -r mkey; do
    [[ -n "$mkey" ]] || continue
    fetch_manifest "$mkey" || log "fetch failed: $mkey"
  done < <(manifest_keys)

  sleep "$INTERVAL"
done
