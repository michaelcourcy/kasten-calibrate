#!/bin/bash

# block-perf: storage performance scenario, no Kasten involved.
#
# Phases (run all by default, or one at a time):
#   1. workload  - create COUNT block-mode PVCs via create-calibrate-workload.sh,
#                  each filled with FILES thousand files of SIZE KB, then wait
#                  for the initial generation to complete.
#   2. snapshot  - take a CSI VolumeSnapshot of each source PVC.
#   3. clone     - create a block-mode clone PVC from each snapshot.
#   4. read      - launch one reader pod per clone that reads the raw block
#                  device in 512KB chunks and sha256's every chunk (dd loop).
#
# End state: 2*COUNT block-mode PVCs are mounted at once -- COUNT originals held
# by the workload deployments, COUNT clones read by the reader pods.
#
# Target platform: OpenShift, storage class managed-csi (block + snapshot capable).

set -e

# ---- defaults -------------------------------------------------------------
NAMESPACE="block-perf"          # dedicated namespace for the scenario
STORAGE_CLASS="managed-csi"     # OpenShift block-capable storage class
SNAPSHOT_CLASS=""               # empty => auto-detect default / matching class
COUNT=4                         # number of PVCs (and clones, and readers)
FILES_THOUSANDS=10              # 10 -> 10,000 files
FILE_SIZE_KB=5120               # 5120 KB -> 5 MB per file
CHUNK_BYTES=524288              # 512 KB read chunk for the hasher
NODE=""                         # pin all pods to this node (empty = scheduler decides)
READER_IMAGE="docker.io/ubuntu:latest"   # has dd, blockdev, sha256sum
GEN_TIMEOUT=0                   # seconds to wait for file generation (0 = forever)
SNAP_TIMEOUT=900                # seconds to wait for a snapshot to be ready
COMMAND="all"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_SCRIPT="$SCRIPT_DIR/../../../create-calibrate-workload.sh"

# Prefer the OpenShift CLI for SCC management, fall back to kubectl.
if command -v oc &> /dev/null; then OC=oc; else OC=kubectl; fi

usage() {
    cat << EOF
Usage: $0 [options] [command]

Commands:
    all         Run workload -> snapshot -> clone -> read (default)
    workload    Create the source block PVCs and wait for data generation
    snapshot    Snapshot every source PVC
    clone       Create a block-mode clone PVC from every snapshot
    read        Launch the reader pods (raw block read + per-chunk sha256)
    status      Show PVCs, snapshots and pods for this scenario
    cleanup     Delete everything this scenario created (keeps the namespace)

Options:
    -n, --namespace NAME       Dedicated namespace (default: $NAMESPACE)
    -c, --storage-class NAME   Storage class (default: $STORAGE_CLASS)
        --snapshot-class NAME  VolumeSnapshotClass (default: auto-detect)
        --count N              Number of PVCs/clones/readers (default: $COUNT)
    -f, --files N              Files in thousands per PVC (default: $FILES_THOUSANDS)
    -s, --size KB              File size in KB (default: $FILE_SIZE_KB)
        --chunk BYTES          Reader chunk size in bytes (default: $CHUNK_BYTES)
    -N, --node NAME            Pin all workload and reader pods to this node, so
                               the whole scenario (data, clones, reads) runs on a
                               single node (default: scheduler decides)
        --gen-timeout SEC      Wait limit for generation, 0=forever (default: $GEN_TIMEOUT)
    -h, --help                 Show this help

Examples:
    # full run with defaults (4 x 10k files of 5MB, on managed-csi)
    $0

    # just (re)create the readers against existing clones
    $0 read

    # tear everything down
    $0 cleanup
EOF
    exit 1
}

# ---- arg parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)      NAMESPACE="$2"; shift 2;;
        -c|--storage-class)  STORAGE_CLASS="$2"; shift 2;;
        --snapshot-class)    SNAPSHOT_CLASS="$2"; shift 2;;
        --count)             COUNT="$2"; shift 2;;
        -f|--files)          FILES_THOUSANDS="$2"; shift 2;;
        -s|--size)           FILE_SIZE_KB="$2"; shift 2;;
        --chunk)             CHUNK_BYTES="$2"; shift 2;;
        -N|--node)           NODE="$2"; shift 2;;
        --gen-timeout)       GEN_TIMEOUT="$2"; shift 2;;
        -h|--help)           usage;;
        all|workload|snapshot|clone|read|status|cleanup)
                             COMMAND="$1"; shift;;
        *) echo "Unknown argument: $1"; usage;;
    esac
done

PVC_PREFIX="calibrate-${FILES_THOUSANDS}k-${FILE_SIZE_KB}kb-block"
DEPLOY_PREFIX="workload-${PVC_PREFIX}"

# ---- helpers --------------------------------------------------------------

# Fail early if a node was requested but does not exist.
validate_node() {
    [ -z "$NODE" ] && return
    if ! kubectl get node "$NODE" &> /dev/null; then
        echo "Error: node '$NODE' not found. Available nodes:"
        kubectl get nodes -o name | sed 's#node/#  #'
        exit 1
    fi
    echo "Pinning all pods to node: $NODE"
}

ensure_namespace() {
    validate_node
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo "Creating dedicated namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    fi
    # Block-mode pods need the privileged SCC on OpenShift.
    if [ "$OC" = "oc" ]; then
        echo "Granting privileged SCC to 'default' service account in $NAMESPACE"
        oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" || true
    else
        echo "Note: not on OpenShift CLI; labelling namespace pod-security=privileged"
        kubectl label --overwrite namespace "$NAMESPACE" \
            pod-security.kubernetes.io/enforce=privileged || true
    fi
}

# List the source PVCs created by the workload script, in stable order.
src_pvcs() {
    kubectl get pvc -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -E "^${PVC_PREFIX}(-[0-9]+)?$" | sort
}

src_deploys() {
    kubectl get deploy -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -E "^${DEPLOY_PREFIX}(-[0-9]+)?$" | sort
}

pvc_size() { kubectl get pvc "$1" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}'; }
pvc_sc()   { kubectl get pvc "$1" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}'; }

# Resolve the VolumeSnapshotClass to use: explicit flag, else the default one.
resolve_snapshot_class() {
    if [ -n "$SNAPSHOT_CLASS" ]; then return; fi
    SNAPSHOT_CLASS=$(kubectl get volumesnapshotclass \
        -o jsonpath='{range .items[?(@.metadata.annotations.snapshot\.storage\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | head -n1)
    if [ -z "$SNAPSHOT_CLASS" ]; then
        # no default class: pick one whose driver matches the storage class provisioner
        local prov
        prov=$(kubectl get storageclass "$STORAGE_CLASS" -o jsonpath='{.provisioner}' 2>/dev/null)
        if [ -n "$prov" ]; then
            SNAPSHOT_CLASS=$(kubectl get volumesnapshotclass \
                -o jsonpath="{range .items[?(@.driver==\"$prov\")]}{.metadata.name}{\"\n\"}{end}" \
                2>/dev/null | head -n1)
        fi
    fi
    if [ -n "$SNAPSHOT_CLASS" ]; then
        echo "Using VolumeSnapshotClass: $SNAPSHOT_CLASS"
    else
        echo "Warning: no VolumeSnapshotClass found; relying on cluster default."
    fi
}

# ---- phase: workload ------------------------------------------------------
phase_workload() {
    ensure_namespace
    echo ""
    echo "=== Phase 1: creating $COUNT block-mode workload PVCs ==="
    # Pin at creation so the WaitForFirstConsumer PVC provisions in the node's
    # zone -- patching after the fact races the scheduler and can bind the disk
    # in the wrong zone.
    local node_arg=()
    [ -n "$NODE" ] && node_arg=(-N "$NODE")
    for n in $(seq 1 "$COUNT"); do
        echo "--- workload $n/$COUNT ---"
        "$WORKLOAD_SCRIPT" \
            -n "$NAMESPACE" \
            -f "$FILES_THOUSANDS" \
            -s "$FILE_SIZE_KB" \
            -c "$STORAGE_CLASS" \
            -b "${node_arg[@]}"
    done

    echo ""
    echo "=== Waiting for file generation to complete on all PVCs ==="
    local start now
    start=$(date +%s)
    for dep in $(src_deploys); do
        echo "Waiting for deployment $dep to be ready..."
        kubectl rollout status "deploy/$dep" -n "$NAMESPACE" --timeout=600s
        echo "Waiting for $dep to finish writing its files (marker /data/initial)..."
        while ! kubectl exec -n "$NAMESPACE" "deploy/$dep" -- test -f /data/initial 2>/dev/null; do
            now=$(date +%s)
            if [ "$GEN_TIMEOUT" -gt 0 ] && [ $((now - start)) -ge "$GEN_TIMEOUT" ]; then
                echo "Timed out waiting for $dep after ${GEN_TIMEOUT}s"; exit 1
            fi
            echo "  $dep: still generating... ($(( (now - start) ))s elapsed)"
            sleep 30
        done
        echo "  $dep: generation complete."
    done
    echo "All source PVCs are populated."
}

# ---- phase: snapshot ------------------------------------------------------
phase_snapshot() {
    resolve_snapshot_class
    echo ""
    echo "=== Phase 2: snapshotting source PVCs ==="
    local pvcs; pvcs=$(src_pvcs)
    [ -z "$pvcs" ] && { echo "No source PVCs found (prefix $PVC_PREFIX). Run 'workload' first."; exit 1; }

    for pvc in $pvcs; do
        local snap="snap-${pvc}"
        echo "Creating VolumeSnapshot $snap from $pvc"
        {
            echo "apiVersion: snapshot.storage.k8s.io/v1"
            echo "kind: VolumeSnapshot"
            echo "metadata:"
            echo "  name: $snap"
            echo "  namespace: $NAMESPACE"
            echo "  labels:"
            echo "    scenario: block-perf"
            echo "spec:"
            [ -n "$SNAPSHOT_CLASS" ] && echo "  volumeSnapshotClassName: $SNAPSHOT_CLASS"
            echo "  source:"
            echo "    persistentVolumeClaimName: $pvc"
        } | kubectl apply -f -
    done

    echo ""
    echo "Waiting for snapshots to become readyToUse..."
    for pvc in $pvcs; do
        local snap="snap-${pvc}" start now ready
        start=$(date +%s)
        while :; do
            ready=$(kubectl get volumesnapshot "$snap" -n "$NAMESPACE" \
                -o jsonpath='{.status.readyToUse}' 2>/dev/null)
            [ "$ready" = "true" ] && { echo "  $snap: ready"; break; }
            now=$(date +%s)
            if [ $((now - start)) -ge "$SNAP_TIMEOUT" ]; then
                echo "  $snap: not ready after ${SNAP_TIMEOUT}s"; exit 1
            fi
            sleep 5
        done
    done
}

# ---- phase: clone ---------------------------------------------------------
phase_clone() {
    echo ""
    echo "=== Phase 3: cloning block PVCs from snapshots ==="
    local pvcs; pvcs=$(src_pvcs)
    [ -z "$pvcs" ] && { echo "No source PVCs found. Run 'workload' first."; exit 1; }

    for pvc in $pvcs; do
        local snap="snap-${pvc}" clone="clone-${pvc}" size sc
        size=$(pvc_size "$pvc")
        sc=$(pvc_sc "$pvc")
        echo "Creating clone PVC $clone (size $size, sc $sc) from $snap"
        {
            echo "apiVersion: v1"
            echo "kind: PersistentVolumeClaim"
            echo "metadata:"
            echo "  name: $clone"
            echo "  namespace: $NAMESPACE"
            echo "  labels:"
            echo "    scenario: block-perf"
            echo "spec:"
            echo "  accessModes:"
            echo "  - ReadWriteOnce"
            echo "  volumeMode: Block"
            [ -n "$sc" ] && echo "  storageClassName: $sc"
            echo "  resources:"
            echo "    requests:"
            echo "      storage: $size"
            echo "  dataSource:"
            echo "    name: $snap"
            echo "    kind: VolumeSnapshot"
            echo "    apiGroup: snapshot.storage.k8s.io"
        } | kubectl apply -f -
    done
    echo "Clones created (they bind when the reader pods are scheduled)."
}

# ---- phase: read ----------------------------------------------------------
phase_read() {
    validate_node
    echo ""
    echo "=== Phase 4: launching reader pods (raw 512KB chunk hashing) ==="
    local pvcs; pvcs=$(src_pvcs)
    [ -z "$pvcs" ] && { echo "No source PVCs found. Run 'workload' first."; exit 1; }

    # optional node pinning, injected into the pod spec
    local node_selector_yaml=""
    if [ -n "$NODE" ]; then
        node_selector_yaml="  nodeSelector:
    kubernetes.io/hostname: $NODE"
    fi

    for pvc in $pvcs; do
        local clone="clone-${pvc}" pod="reader-${pvc}"
        echo "Creating reader pod $pod for clone $clone"
        {
            cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $NAMESPACE
  labels:
    scenario: block-perf
    role: reader
spec:
  restartPolicy: Never
$node_selector_yaml
  containers:
  - name: reader
    image: $READER_IMAGE
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
    command:
    - sh
    - -c
    - |
      set -e
      DEV=/dev/blockdata
      CHUNK=$CHUNK_BYTES
      SIZE=\$(blockdev --getsize64 "\$DEV")
      N=\$(( (SIZE + CHUNK - 1) / CHUNK ))
      echo "Reading \$DEV: size=\$SIZE bytes, chunk=\$CHUNK bytes, chunks=\$N"
      START=\$(date +%s)
      i=0
      while [ "\$i" -lt "\$N" ]; do
        # read one 512KB chunk at offset i*CHUNK and hash it
        dd if="\$DEV" bs="\$CHUNK" skip="\$i" count=1 2>/dev/null | sha256sum > /dev/null
        i=\$((i + 1))
        if [ \$((i % 2000)) -eq 0 ]; then
          NOW=\$(date +%s); EL=\$((NOW - START)); [ "\$EL" -eq 0 ] && EL=1
          MB=\$((i * CHUNK / 1048576))
          echo "progress: \$i/\$N chunks, \${MB}MB, \${EL}s, \$((MB / EL)) MB/s"
        fi
      done
      NOW=\$(date +%s); EL=\$((NOW - START)); [ "\$EL" -eq 0 ] && EL=1
      GB=\$((N * CHUNK / 1073741824))
      echo "DONE: hashed \$N chunks (~\${GB}GB) in \${EL}s, avg \$((N * CHUNK / 1048576 / EL)) MB/s"
    resources:
      requests:
        cpu: 1
        memory: 512Mi
    volumeDevices:
    - devicePath: /dev/blockdata
      name: data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $clone
EOF
        } | kubectl apply -f -
    done

    echo ""
    echo "Reader pods launched. Follow progress with:"
    for pvc in $pvcs; do
        echo "  kubectl logs -n $NAMESPACE reader-${pvc} -f"
    done
}

# ---- status / cleanup -----------------------------------------------------
phase_status() {
    echo "=== PVCs ==="
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== VolumeSnapshots ==="
    kubectl get volumesnapshot -n "$NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
}

phase_cleanup() {
    echo "=== Cleaning up scenario resources in $NAMESPACE ==="
    local pvcs; pvcs=$(src_pvcs)
    for pvc in $pvcs; do
        kubectl delete pod "reader-${pvc}" -n "$NAMESPACE" --ignore-not-found
        kubectl delete pvc "clone-${pvc}" -n "$NAMESPACE" --ignore-not-found
        kubectl delete volumesnapshot "snap-${pvc}" -n "$NAMESPACE" --ignore-not-found
    done
    for dep in $(src_deploys); do
        kubectl delete deploy "$dep" -n "$NAMESPACE" --ignore-not-found
    done
    for pvc in $pvcs; do
        kubectl delete pvc "$pvc" -n "$NAMESPACE" --ignore-not-found
    done
    echo "Done. (Namespace $NAMESPACE was left in place.)"
}

# ---- dispatch -------------------------------------------------------------
case "$COMMAND" in
    all)
        phase_workload
        phase_snapshot
        phase_clone
        phase_read
        echo ""
        echo "✓ block-perf scenario running: $COUNT originals + $COUNT clones, all block-mode."
        ;;
    workload) phase_workload;;
    snapshot) phase_snapshot;;
    clone)    phase_clone;;
    read)     phase_read;;
    status)   phase_status;;
    cleanup)  phase_cleanup;;
    *) usage;;
esac
