# Scenarios: `no-kasten`

This folder holds test scenarios that exercise **storage / CSI performance in
isolation — without Kasten in the loop**.

## Why this exists

When a Kasten backup, snapshot, or restore feels slow, the first question is
always: *is it Kasten, or is it the underlying storage?* These scenarios answer
that by driving the storage layer using nothing but **native Kubernetes
primitives** and **pod-level I/O**:

- `PersistentVolumeClaim` provisioning (filesystem and block mode)
- CSI `VolumeSnapshot` creation
- Cloning a PVC from a snapshot (`dataSource`)
- Raw read/write throughput from inside a pod

By measuring these directly we establish a **baseline of what the storage
backend can actually do**. Any Kasten operation is then bounded by that
baseline — if the storage can only read 200 MB/s, no Kasten tuning will make a
restore that reads the same data go faster.

These scenarios deliberately do **not** install or call Kasten. They reuse the
repo's workload generator (`create-calibrate-workload.sh`) to lay down realistic
data, then operate on the resulting volumes with plain `kubectl`.

## Requirements

- A cluster with a CSI driver that supports **block-mode PVCs**, **volume
  snapshots**, and **clone-from-snapshot** (`snapshot.storage.k8s.io/v1`).
- The external-snapshotter CRDs (`VolumeSnapshot`, `VolumeSnapshotClass`)
  installed, and a `VolumeSnapshotClass` available (default or named).
- `kubectl` pointed at the target cluster.

## Scenarios

| Scenario | What it tests |
|----------|---------------|
| [`block-perf`](block-perf/) | Block-mode PVC provisioning, snapshot, clone-from-snapshot, and raw block read throughput (512KB chunks, hashed) |
