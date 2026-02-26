#!/bin/bash

# Script to create a pod for exploring a PVC, optionally via FileRecoverySession
# Usage: ./explore-pvc.sh [options]
#   -n, --namespace NAMESPACE      Namespace where the PVC exists (default: current context namespace)
#   -p, --pvc NAME                Name of the PVC to mount (required)
#   -r, --restore-point NAME      Name of the remote restore point to access via SFTP
#   -u, --user UID                User ID to run as (sets both runAsUser and fsGroup)
#   -d, --dry-run                 Display the manifest without applying it
#   -h, --help                    Show this help message

set -e

# Default values
NAMESPACE=""
PVC_NAME=""
USER_ID=""
DRY_RUN=false
RESTORE_POINT_NAME=""

# Tracked resources for cleanup hints
FRS_NAME=""
SSH_KEY_SECRET=""
SSH_KEY_DIR=""

# Cleanup temporary SSH key files on exit
cleanup_tmpfiles() {
    if [ -n "$SSH_KEY_DIR" ] && [ -d "$SSH_KEY_DIR" ]; then
        rm -rf "$SSH_KEY_DIR"
    fi
}
trap cleanup_tmpfiles EXIT

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [options]

Options:
    -n, --namespace NAMESPACE      Namespace where the PVC exists (default: current context namespace)
    -p, --pvc NAME                Name of the PVC to mount (required)
    -r, --restore-point NAME      Name of the remote restore point to access via SFTP
    -u, --user UID                User ID to run as (sets both runAsUser and fsGroup)
    -d, --dry-run                 Display the manifest without applying it
    -h, --help                    Show this help message

Examples:
    # Explore a PVC in the current namespace
    $0 -p my-data-pvc

    # Explore a PVC in a specific namespace
    $0 -n test-namespace -p calibrate-data

    # Explore a PVC with a specific user ID
    $0 -n test-namespace -p calibrate-data -u 1000

    # Explore a remote restore point via SFTP
    $0 -n test-namespace -p calibrate-data -r scheduled-5d5clnptxw
EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pvc)
            PVC_NAME="$2"
            shift 2
            ;;
        -r|--restore-point)
            RESTORE_POINT_NAME="$2"
            shift 2
            ;;
        -u|--user)
            USER_ID="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$PVC_NAME" ]; then
    echo "Error: PVC name is required (-p)"
    usage
fi

# Get current context namespace if not specified
if [ -z "$NAMESPACE" ]; then
    NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}')
    if [ -z "$NAMESPACE" ]; then
        NAMESPACE="default"
    fi
    echo "Using namespace from current context: $NAMESPACE"
fi

# Verify the PVC exists
if ! kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "Error: PVC '$PVC_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# --- Restore point validation and SSH key generation ---
PUBLIC_KEY=""
if [ -n "$RESTORE_POINT_NAME" ]; then

    # Verify the restore point exists in the namespace
    if ! kubectl get restorepoint "$RESTORE_POINT_NAME" -n "$NAMESPACE" &> /dev/null; then
        echo "Error: RestorePoint '$RESTORE_POINT_NAME' not found in namespace '$NAMESPACE'"
        exit 1
    fi

    # Verify it is a remote (exported) restore point
    EXPORT_TYPE=$(kubectl get restorepoint "$RESTORE_POINT_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.labels.k10\.kasten\.io/exportType}' 2>/dev/null || true)
    if [ "$EXPORT_TYPE" != "portableAppData" ]; then
        echo "Error: RestorePoint '$RESTORE_POINT_NAME' is not a remote restore point."
        echo "  Expected label: k10.kasten.io/exportType=portableAppData"
        echo "  Found value:    '${EXPORT_TYPE:-<not set>}'"
        exit 1
    fi

    FRS_NAME="$PVC_NAME"
    SSH_KEY_SECRET="explore-${PVC_NAME}-ssh-key"

    if [ "$DRY_RUN" = false ]; then
        # Generate ephemeral SSH key pair
        SSH_KEY_DIR=$(mktemp -d /tmp/explore-pvc-XXXXXX)
        echo "Generating ephemeral SSH key pair..."
        ssh-keygen -t ed25519 -f "${SSH_KEY_DIR}/id_ed25519" -N "" -C "explore-pvc-frs" -q
        PUBLIC_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519.pub")

        # Check if the SSH key secret already exists and remove it
        if kubectl get secret "$SSH_KEY_SECRET" -n "$NAMESPACE" &> /dev/null; then
            echo "Note: SSH key secret '$SSH_KEY_SECRET' already exists, replacing it..."
            kubectl delete secret "$SSH_KEY_SECRET" -n "$NAMESPACE" --ignore-not-found=true
        fi

        # Create Kubernetes Secret holding the private key
        kubectl create secret generic "$SSH_KEY_SECRET" \
            --from-file=id_ed25519="${SSH_KEY_DIR}/id_ed25519" \
            -n "$NAMESPACE"
        echo "✓ SSH key secret '$SSH_KEY_SECRET' created"
    else
        PUBLIC_KEY="<generated-ed25519-public-key>"
    fi

    # Check if a FileRecoverySession with the same name already exists
    if [ "$DRY_RUN" = false ] && kubectl get frs "$FRS_NAME" -n "$NAMESPACE" &> /dev/null; then
        echo "Note: FileRecoverySession '$FRS_NAME' already exists, deleting it first..."
        kubectl delete frs "$FRS_NAME" -n "$NAMESPACE" --ignore-not-found=true
    fi
fi

# --- Generate pod name ---
POD_NAME="explore-${PVC_NAME}"

# Find an available pod name (avoid collision with existing pods)
BASE_POD_NAME="$POD_NAME"
SUFFIX_NUM=2
while kubectl get pod "$POD_NAME" -n "$NAMESPACE" &> /dev/null; do
    POD_NAME="${BASE_POD_NAME}-${SUFFIX_NUM}"
    SUFFIX_NUM=$((SUFFIX_NUM + 1))
done

if [ "$POD_NAME" != "$BASE_POD_NAME" ]; then
    echo "Note: Pod $BASE_POD_NAME already exists, using $POD_NAME instead"
    echo ""
fi

echo "Creating explorer pod with:"
echo "  Namespace:     $NAMESPACE"
echo "  PVC:           $PVC_NAME"
if [ -n "$USER_ID" ]; then
    echo "  User ID:       $USER_ID"
fi
echo "  Pod name:      $POD_NAME"
if [ -n "$RESTORE_POINT_NAME" ]; then
    echo "  Restore Point: $RESTORE_POINT_NAME (SFTP mode)"
fi
echo ""

# --- Build the pod YAML manifest ---

# Pod-level security context
if [ -n "$USER_ID" ]; then
    POD_SECURITY_CONTEXT=$(cat <<EOF
  securityContext:
    fsGroup: $USER_ID
    fsGroupChangePolicy: "OnRootMismatch"
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
EOF
)
    CONTAINER_SECURITY_CONTEXT=$(cat <<EOF
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: $USER_ID
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
EOF
)
elif [ -n "$RESTORE_POINT_NAME" ]; then
    # fsGroup: 1000 makes the kubelet set the SSH key file's owner to UID 1000,
    # so the non-root container can read it and OpenSSH accepts the 0600 permissions.
    POD_SECURITY_CONTEXT=$(cat <<EOF
  securityContext:
    fsGroup: 1000
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
EOF
)
    CONTAINER_SECURITY_CONTEXT=$(cat <<EOF
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: 1000
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
EOF
)
else
    POD_SECURITY_CONTEXT=$(cat <<EOF
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
EOF
)
    CONTAINER_SECURITY_CONTEXT=$(cat <<EOF
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: 1000
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
EOF
)
fi

# Container command, init containers, and extra volumes differ in restore-point mode
if [ -n "$RESTORE_POINT_NAME" ]; then
    CONTAINER_COMMAND=$(cat <<EOF
    command:
    - sh
    - -c
    - |
      echo "PVC Explorer Pod with FileRecovery support - Ready"
      echo "PVC data is mounted at: /data"
      echo "SSH private key is at:  /ssh-key/id_ed25519"
      while true; do sleep 3600; done
EOF
)
    EXTRA_VOLUME_MOUNT=$(cat <<EOF

    - name: ssh-key
      mountPath: /ssh-key
      readOnly: true
EOF
)
    EXTRA_VOLUME=$(cat <<EOF

  - name: ssh-key
    secret:
      secretName: $SSH_KEY_SECRET
      defaultMode: 0600
EOF
)
else
    CONTAINER_COMMAND=$(cat <<EOF
    command:
    - sh
    - -c
    - |
      echo "PVC Explorer Pod - Ready to explore $PVC_NAME"
      echo "Use: kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
      echo "Data is mounted at: /data"
      while true; do sleep 3600; done
EOF
)
    EXTRA_VOLUME_MOUNT=""
    EXTRA_VOLUME=""
fi

MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
  labels:
    app: pvc-explorer
    pvc: $PVC_NAME
spec:
$POD_SECURITY_CONTEXT
  containers:
  - name: explorer
    image: $([ -n "$RESTORE_POINT_NAME" ] && echo "docker.io/michaelcourcy/pvc-explorer:latest" || echo "docker.io/alpine:latest")
    imagePullPolicy: IfNotPresent
$CONTAINER_COMMAND
    volumeMounts:
    - name: data
      mountPath: /data$EXTRA_VOLUME_MOUNT
$CONTAINER_SECURITY_CONTEXT
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVC_NAME$EXTRA_VOLUME
  restartPolicy: Always
EOF
)

# --- Build the FileRecoverySession YAML ---
FRS_MANIFEST=""
if [ -n "$RESTORE_POINT_NAME" ]; then
    FRS_MANIFEST=$(cat <<EOF
apiVersion: datamover.kio.kasten.io/v1alpha1
kind: FileRecoverySession
metadata:
  name: $FRS_NAME
  namespace: $NAMESPACE
spec:
  volumes:
    - restorePointName: "$RESTORE_POINT_NAME"
      pvcName: "$PVC_NAME"
  transports:
    sftp:
      userPublicKey: "$PUBLIC_KEY"
EOF
)
fi

# --- Dry-run: print manifests and exit ---
if [ "$DRY_RUN" = true ]; then
    echo "Dry-run mode: displaying manifests without applying..."
    echo ""
    echo "=== Explorer Pod ==="
    echo "$MANIFEST"
    if [ -n "$FRS_MANIFEST" ]; then
        echo ""
        echo "=== FileRecoverySession ==="
        echo "$FRS_MANIFEST"
        echo ""
        echo "Note: an SSH key secret '$SSH_KEY_SECRET' would also be created."
    fi
    exit 0
fi

# --- Apply the pod manifest ---
echo "Applying pod manifest..."
echo "$MANIFEST" | kubectl apply -f -

echo ""
echo "✓ Explorer pod created successfully"
echo ""
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=60s

# --- Create and wait for the FileRecoverySession ---
if [ -n "$RESTORE_POINT_NAME" ]; then
    echo ""
    echo "Creating FileRecoverySession '$FRS_NAME'..."
    echo "$FRS_MANIFEST" | kubectl apply -f -
    echo "✓ FileRecoverySession created"

    echo ""
    echo "Waiting for FileRecoverySession to be ready (timeout: 3 minutes)..."
    TIMEOUT=180
    ELAPSED=0
    INTERVAL=5
    FRS_READY=false

    while [ $ELAPSED -lt $TIMEOUT ]; do
        STATE=$(kubectl get frs "$FRS_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.state}' 2>/dev/null || true)
        printf "  State: %-12s (%ds elapsed)\r" "${STATE:-Pending}" "$ELAPSED"
        if [ "$STATE" = "Ready" ]; then
            FRS_READY=true
            break
        elif [ "$STATE" = "Failed" ]; then
            echo ""
            echo "Error: FileRecoverySession '$FRS_NAME' reached Failed state."
            kubectl describe frs "$FRS_NAME" -n "$NAMESPACE"
            exit 1
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo ""

    if [ "$FRS_READY" = false ]; then
        echo "Error: Timeout waiting for FileRecoverySession '$FRS_NAME' to be ready after ${TIMEOUT}s."
        echo "Check status with: kubectl get frs $FRS_NAME -n $NAMESPACE -o yaml"
        exit 1
    fi

    echo "✓ FileRecoverySession is Ready"

    # Extract SFTP connection details
    SFTP_ENDPOINT=$(kubectl get frs "$FRS_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.transports.sftp.endpoints[0]}' 2>/dev/null || true)
    SFTP_PORT=$(kubectl get frs "$FRS_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.transports.sftp.portNumber}' 2>/dev/null || true)
    SFTP_FINGERPRINT=$(kubectl get frs "$FRS_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.transports.sftp.hostKeyFingerprint}' 2>/dev/null || true)

    echo ""
    echo "============================================================"
    echo "  SFTP Restore Point Access"
    echo "============================================================"
    echo ""
    echo "  Restore Point : $RESTORE_POINT_NAME"
    echo "  SFTP Endpoint : $SFTP_ENDPOINT"
    echo "  SFTP Port     : $SFTP_PORT"
    if [ -n "$SFTP_FINGERPRINT" ]; then
        echo "  Host Key      : $SFTP_FINGERPRINT"
    fi
    echo ""
    echo "  1. Open a shell in the explorer pod:"
    echo "     kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
    echo ""
    echo "  2. Inside the container, connect via SFTP:"
    echo "     sftp -i /ssh-key/id_ed25519 -P $SFTP_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$SFTP_ENDPOINT"
    echo ""
    echo "  The PVC '$PVC_NAME' is mounted at /data — you can copy"
    echo "  files from the SFTP session directly into /data."
    echo ""
    echo "============================================================"
    echo ""
    echo "To clean up all resources when done:"
    echo "  kubectl delete pod    $POD_NAME      -n $NAMESPACE"
    echo "  kubectl delete frs    $FRS_NAME      -n $NAMESPACE"
    echo "  kubectl delete secret $SSH_KEY_SECRET -n $NAMESPACE"
else
    echo ""
    echo "To explore the PVC, run:"
    echo "  kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
    echo ""
    echo "To view pod logs:"
    echo "  kubectl logs -n $NAMESPACE $POD_NAME"
    echo ""
    echo "To delete the explorer pod:"
    echo "  kubectl delete pod $POD_NAME -n $NAMESPACE"
fi
