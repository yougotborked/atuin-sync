# atuin-sync

Two-way directory sync between machines using [Atuin](https://atuin.sh)'s
key-value store as the transport. Atuin end-to-end encrypts the KV records, so
you get a tiny, self-hosted-or-not "Syncthing for small files" with nothing but
`bash`, `python3` and an Atuin account you already have.

```
machine A ──atuin sync──►  Atuin server (encrypted)  ◄──atuin sync── machine B
 ~/shared                                                              ~/shared
```

## Requirements

- `atuin` ≥ 18 with `atuin kv` (logged in, `atuin sync` working on every machine)
- `bash` ≥ 4.4, `python3`, GNU coreutils (`sha256sum`, `stat`, `find`)

## Usage

```bash
./atuin_sync.sh /path/to/dir            # run on every machine
INTERVAL=60 ./atuin_sync.sh ~/shared    # poll every 60 s (default 20)
ONCE=1 ./atuin_sync.sh ~/shared         # a single pass, then exit (cron/testing)
```

| Variable | Default | Meaning |
|---|---|---|
| `ATUIN_KV_NAMESPACE` | `file-xfer` | KV namespace; machines must use the same one |
| `INTERVAL` | `20` | Seconds between passes |
| `CHUNK_BYTES` | `70000` | Raw bytes per chunk (base64 adds ~33 %) |
| `ONCE` | unset | Set to run one pass and exit |

Run it under systemd, `tmux`, or a container to keep it going.

## How it works

Every file is split into chunks and stored as KV records:

- `chunk.<sha256>.<n>` — base64 slice of the file's content
- `manifest.<id>` — JSON `{path_b64, sha256, size, chunks, ts}`, where `id = sha256(path NUL sha256)`

Chunks are synced **before** the manifest is published, so a receiver never sees
a manifest whose data hasn't arrived. Each pass: `atuin sync` → fetch new
manifests → publish local changes. Received files are verified (size + SHA-256)
before being moved into place.

Local bookkeeping lives in `<dir>/.atuin-sync/` and is never synced:
which manifests were applied, and the last synced version of each path.

### Conflicts

- File changed on one side only → the other side is updated in place.
- File changed on **both** sides → the local copy is kept and the remote version
  is saved next to it as `name.conflict-<hash>`. Conflict files are never re-published.
- Newest manifest (`ts`) wins; stale/old versions are ignored.

### Safety

Manifest paths that are absolute, contain `..`, or point into `.atuin-sync` are
rejected. Temp files are created inside the sync dir (same filesystem, atomic `mv`).

## Limitations

- **Deletions are not propagated** (and old records stay in the KV store).
- Not for large data: everything goes through your Atuin account's storage.
- Polling, not push; latency is about `INTERVAL`.
- Clock skew between machines can affect "newest wins" ordering.
- Symlinks and empty directories are not synced; file modes are not preserved.

## Development

```bash
tests/run.sh          # integration tests against a fake atuin (no account needed)
shellcheck atuin_sync.sh tests/run.sh tests/fakebin/atuin
```

`tests/fakebin/atuin` is a tiny file-backed stand-in for `atuin kv`/`sync`, so the
tests simulate several machines sharing one store. CI runs both on every push.

## License

MIT — see [LICENSE](LICENSE).
