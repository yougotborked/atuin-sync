#!/usr/bin/env bash
# Integration tests: several "machines" (dirs A, B, C) syncing through a fake atuin.
# Usage: tests/run.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
SCRIPT=$HERE/../atuin_sync.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export PATH=$HERE/fakebin:$PATH FAKE_ATUIN_STORE=$W/store ATUIN_KV_NAMESPACE=t CHUNK_BYTES=1000 ONCE=1
A=$W/A B=$W/B C=$W/C
mkdir -p "$A" "$B" "$C"
fail=0

check() { local name=$1; shift; if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fail=1; fi; }
run()   { bash "$SCRIPT" "$1" 2>&1; }
same()  { cmp -s -- "$1" "$2"; }
sync_both() { run "$A" >/dev/null; run "$B" >/dev/null; run "$A" >/dev/null; }
nochatter() { ! grep -qE 'Published|Received|Conflict' <<<"$1"; }

# Write a hand-crafted manifest (+ one chunk) straight into the fake store.
# usage: inject <manifest-suffix> <path-in-manifest> <real-content> <claimed-content>
inject() {
  python3 - "$W/store/t" "$@" <<'PY'
import base64, hashlib, json, sys
store, suffix, path, real, claimed = sys.argv[1:6]
h = hashlib.sha256(claimed.encode()).hexdigest()
open(f"{store}/chunk.{h}.0", "w").write(base64.b64encode(real.encode()).decode())
m = {"path_b64": base64.urlsafe_b64encode(path.encode()).decode(), "sha256": h,
     "size": len(claimed), "chunks": 1, "ts": 9999999999}
open(f"{store}/manifest.{int(suffix):064d}", "w").write(json.dumps(m, separators=(",", ":")))
PY
}

# 1. new files (nested, multi-chunk, spaces in names) propagate both ways
mkdir -p "$A/sub dir"
head -c 5000 /dev/urandom > "$A/sub dir/big file.bin"
echo hello > "$A/a.txt"
echo fromB > "$B/b.txt"
sync_both
check "nested multi-chunk file A->B" same "$A/sub dir/big file.bin" "$B/sub dir/big file.bin"
check "file A->B"                    same "$A/a.txt" "$B/a.txt"
check "file B->A"                    same "$B/b.txt" "$A/b.txt"
chunks=("$W"/store/t/chunk.*)
check "big file was split in chunks" test "${#chunks[@]}" -ge 6

# 2. idempotent: another pass does nothing
out=$(run "$A"; run "$B")
check "second pass is a no-op" nochatter "$out"

# 3. edits propagate without conflict files
echo edited > "$A/a.txt"
sync_both
check "edit propagates"          same "$A/a.txt" "$B/a.txt"
check "no conflict file on edit" test -z "$(find "$B" -name '*.conflict-*')"

# 4. a fresh machine gets the latest version, not an old one
run "$C" >/dev/null
check "fresh machine gets latest" same "$A/a.txt" "$C/a.txt"

# 5. edits on both sides => conflict copy, local data preserved, no spreading
echo "edit on A" > "$A/a.txt"
echo "edit on B" > "$B/a.txt"
run "$A" >/dev/null; run "$B" >/dev/null; run "$A" >/dev/null; run "$B" >/dev/null
check "local edit kept"              grep -q "edit on B" "$B/a.txt"
check "conflict copy created"        test -n "$(find "$B" -name 'a.txt.conflict-*')"
check "conflict not republished"     test -z "$(find "$A" -name '*.conflict-*')"

# 6. malicious manifest paths are rejected
inject 1 "../evil.txt" evil evil
inject 3 "/tmp/abs-evil.txt" evil evil
run "$B" >/dev/null
check "path traversal rejected" test ! -e "$W/evil.txt"
check "absolute path rejected"  test ! -e /tmp/abs-evil.txt

# 7. content that doesn't match its manifest hash is not written
inject 2 "corrupt.txt" bad good
run "$B" >/dev/null
check "corrupt content rejected" test ! -e "$B/corrupt.txt"

# 8. no temp files left behind
check "tmp dir clean" test -z "$(ls -A "$B/.atuin-sync/tmp")"

if ((fail)); then echo "SOME TESTS FAILED"; exit 1; fi
echo "all tests passed"
