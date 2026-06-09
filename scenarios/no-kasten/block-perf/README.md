# Scenario: `block-perf`

Storage performance test on **block-mode** PVCs, with **no Kasten involvement**.
It provisions data, snapshots it, clones the snapshots, and then reads the raw
clone devices back while hashing — measuring the storage backend end to end:
**provision → snapshot → clone → read**.

## What it does

1. **Workload** — runs `create-calibrate-workload.sh` `--count` times (default 4)
   to create block-mode PVCs, each filled with `--files` thousand files of
   `--size` KB (default **10,000 files × 5 MB ≈ 50 GB of data**, on a ~76 Gi
   block PVC). In block mode the workload pod formats the device `ext4` and
   writes the files onto it. The scenario waits until generation is complete
   (marker file `/data/initial`).
2. **Snapshot** — takes a CSI `VolumeSnapshot` of each source PVC and waits for
   `readyToUse: true`.
3. **Clone** — creates a block-mode clone PVC from each snapshot
   (`dataSource: VolumeSnapshot`), same size and storage class as the original.
4. **Read** — launches one reader pod per clone that mounts the clone as a
   **raw block device** (`volumeDevices`, *no filesystem mount*) and reads it in
   512 KB chunks, computing a `sha256` of every chunk.

**End state:** `2 × count` PVCs are mounted in block mode simultaneously — the
originals held by the workload deployments, the clones read by the reader pods.

## How the raw block read works (the `dd` loop)

Reading a block device and hashing fixed-size chunks is straightforward in pure
shell — no filesystem needed. Each reader pod runs:

```sh
DEV=/dev/blockdata
CHUNK=524288                          # 512 KB
SIZE=$(blockdev --getsize64 "$DEV")   # device size in bytes
N=$(( (SIZE + CHUNK - 1) / CHUNK ))   # number of chunks
i=0
while [ "$i" -lt "$N" ]; do
  dd if="$DEV" bs="$CHUNK" skip="$i" count=1 2>/dev/null | sha256sum > /dev/null
  i=$((i + 1))
done
```

`dd ... skip=$i` reads the i-th 512 KB chunk; piping to `sha256sum` hashes it.
Progress and an average MB/s figure are printed to the pod log.

> **Why the `dd` loop (and the trade-off):** it's the most transparent option —
> every chunk is an explicit, offset-addressable read, so it's easy to add
> progress/offset reporting. The cost is one `dd` + one `sha256sum` fork **per
> chunk** (~155k forks for a 76 Gi device), so it is the slowest of the
> approaches. Faster alternatives (streaming `split --filter='sha256sum'`, or a
> single-process Python reader) trade transparency for throughput; swap the
> reader command in `block-perf.sh` if you need them.

The reader uses `ubuntu:latest` (for `dd`, `blockdev`, `sha256sum`) and runs
privileged so it can open the raw block device under OpenShift SCC.

## Target platform: OpenShift + `managed-csi`

- Defaults to the **`managed-csi`** storage class (block- and snapshot-capable).
- Runs in a **dedicated namespace** (default `block-perf`), created if missing.
- Block-mode pods need the **privileged SCC**; the script runs
  `oc adm policy add-scc-to-user privileged -z default -n <ns>` automatically
  when `oc` is available.
- The `VolumeSnapshotClass` is auto-detected (default class, else the first
  available); override with `--snapshot-class`.

## Usage

```sh
# Full run with defaults (4 × 10k files of 5MB, managed-csi, ns block-perf)
./block-perf.sh

# Customize
./block-perf.sh --count 4 -f 10 -s 5120 -c managed-csi -n block-perf

# Run a single phase
./block-perf.sh workload
./block-perf.sh snapshot
./block-perf.sh clone
./block-perf.sh read

# Inspect / tear down
./block-perf.sh status
./block-perf.sh cleanup
```

Options: `-n/--namespace`, `-c/--storage-class`, `--snapshot-class`, `--count`,
`-f/--files`, `-s/--size`, `--chunk`, `--gen-timeout`. See `./block-perf.sh -h`.

## Watching it run

```sh
kubectl get pods,pvc,volumesnapshot -n block-perf
kubectl logs -n block-perf reader-calibrate-10k-5120kb-block -f
```

Each reader logs periodic `progress:` lines and a final
`DONE: hashed N chunks (~XGB) in Ys, avg Z MB/s` summary — that `MB/s` is your
raw block read baseline for cloned-from-snapshot volumes.

## Notes & caveats

- **Capacity:** with defaults this needs ~8 × 76 Gi ≈ **600 Gi** of provisioned
  block storage (4 originals + 4 clones). Adjust `--count` / `-f` / `-s` to fit.
- **Generation time dominates:** writing ~200 GB from `/dev/urandom` across 4
  PVCs can take a long time; the `workload` phase polls until done.
- Snapshots are taken while the workload is live (the originals stay mounted),
  so they are crash-consistent — fine here since the reader only reads raw bytes
  and never mounts the filesystem.
- **The reader reads the whole *device*, not just the data.** `blockdev
  --getsize64` returns the full provisioned size, so each `--count 4` reader
  reads the entire **76 GiB** clone (~155k × 512 KB chunks), regardless of how
  much real data was written. On `managed-csi` the `dd` loop sustains roughly
  **60 MB/s** (per-chunk fork overhead is the limit, not the disk), so a full
  read takes **~20 min per reader** — readers run in parallel, so wall-clock is
  about the same for all four. If that's too slow at full scale, switch the
  reader command in `block-perf.sh` to the streaming `split --filter` or Python
  variant (see above); both read the same device several times faster.
