#!/bin/bash

# Script to create a pod for exploring a PVC
# Usage: ./explore-pvc.sh [options]
#   -n, --namespace NAMESPACE    Namespace where the PVC exists (default: current context namespace)
#   -p, --pvc NAME              Name of the PVC to mount (required)
#   -u, --user UID              User ID to run as (sets both runAsUser and fsGroup)
#   -h, --help                  Show this help message

set -e

# Default values
NAMESPACE=""
PVC_NAME=""
USER_ID=""
DRY_RUN=false

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [options]

Options:
    -n, --namespace NAMESPACE    Namespace where the PVC exists (default: current context namespace)
    -p, --pvc NAME              Name of the PVC to mount (required)
    -u, --user UID              User ID to run as (sets both runAsUser and fsGroup)
    -d, --dry-run               Display the manifest without applying it
    -h, --help                  Show this help message

Examples:
    # Explore a PVC in the current namespace
    $0 -p my-data-pvc

    # Explore a PVC in a specific namespace
    $0 -n test-namespace -p calibrate-data

    # Explore a PVC with a specific user ID
    $0 -n test-namespace -p calibrate-data -u 1000
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

# Generate pod name based on PVC name
POD_NAME="explore-${PVC_NAME}"

# Check if pod already exists and find available name
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
echo "  Namespace: $NAMESPACE"
echo "  PVC: $PVC_NAME"
if [ -n "$USER_ID" ]; then
    echo "  User ID: $USER_ID"
fi
echo "  Pod name: $POD_NAME"
echo ""

# Generate the YAML manifest
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
EOF
)

# Add pod-level security context with fsGroup
MANIFEST+="
"
if [ -n "$USER_ID" ]; then
    MANIFEST+=$(cat <<EOF
  securityContext:
    fsGroup: $USER_ID
    fsGroupChangePolicy: "OnRootMismatch"
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
EOF
)
else
    MANIFEST+=$(cat <<EOF
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
EOF
)
fi

# Add containers section
MANIFEST+="
"
MANIFEST+=$(cat <<EOF
  containers:
  - name: explorer
    image: docker.io/alpine:latest
    imagePullPolicy: IfNotPresent
    command:
    - sh
    - -c
    - |
      echo "PVC Explorer Pod - Ready to explore $PVC_NAME"
      echo "Use: kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
      echo "Data is mounted at: /data"
      # Keep the pod running
      while true; do sleep 3600; done
    volumeMounts:
    - name: data
      mountPath: /data
EOF
)

# Add container-level security context
MANIFEST+="
"
if [ -n "$USER_ID" ]; then
    MANIFEST+=$(cat <<EOF
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: $USER_ID
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
EOF
)
else
    MANIFEST+=$(cat <<EOF
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

# Add resources and volumes
MANIFEST+="
"
MANIFEST+=$(cat <<EOF
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
      claimName: $PVC_NAME
  restartPolicy: Always
EOF
)

# Apply the manifest
echo ""
if [ "$DRY_RUN" = true ]; then
    echo "Dry-run mode: Displaying manifest without applying..."
    echo ""
    echo "$MANIFEST"
    exit 0
fi

echo "Applying manifest..."
echo "$MANIFEST" | kubectl apply -f -

echo ""
echo "✓ Explorer pod created successfully"
echo ""
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/$POD_NAME -n $NAMESPACE --timeout=60s

echo ""
echo "To explore the PVC, run:"
echo "  kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
echo ""
echo "To view pod logs:"
echo "  kubectl logs -n $NAMESPACE $POD_NAME"
echo ""
echo "To delete the explorer pod:"
echo "  kubectl delete pod $POD_NAME -n $NAMESPACE"
