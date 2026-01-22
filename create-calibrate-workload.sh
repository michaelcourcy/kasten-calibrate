#!/bin/bash

# Script to create a calibration workload deployment
# Usage: ./create-calibrate-workload.sh [options]
#   -n, --namespace NAMESPACE    Namespace to create the workload (default: current context namespace)
#   -f, --files NUMBER          Number of files in thousands (e.g., 5000 for 5 million files)
#   -s, --size SIZE             Size of each file in KB
#   -b, --block-mode            Use block mode for PVC (default: false)
#   -h, --help                  Show this help message

set -e

# Default values
NAMESPACE=""
FILES_THOUSANDS=""
FILE_SIZE_KB=""
BLOCK_MODE=false
STORAGE_CLASS=""
DRY_RUN=false

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [options]

Options:
    -n, --namespace NAMESPACE    Namespace to create the workload (default: current context namespace)
    -f, --files NUMBER          Number of files in thousands (e.g., 5000 for 5 million files)
    -s, --size SIZE             Size of each file in KB
    -b, --block-mode            Use block mode for PVC (default: false)
    -c, --storage-class CLASS   Storage class for PVC (default: cluster default)
    -d, --dry-run               Display the manifest without applying it
    -h, --help                  Show this help message

Examples:
    # Create 5 million files of 10KB in namespace test-calibrate
    $0 -n test-calibrate -f 5000 -s 10

    # Create 10 thousand files of 10KB in block mode
    $0 -n test-calibrate -f 10 -s 10 -b

    # Use current context namespace with specific storage class
    $0 -f 100 -s 500 -c ebs-sc
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
        -f|--files)
            FILES_THOUSANDS="$2"
            shift 2
            ;;
        -s|--size)
            FILE_SIZE_KB="$2"
            shift 2
            ;;
        -b|--block-mode)
            BLOCK_MODE=true
            shift
            ;;
        -c|--storage-class)
            STORAGE_CLASS="$2"
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
if [ -z "$FILES_THOUSANDS" ]; then
    echo "Error: Number of files is required (-f)"
    usage
fi

if [ -z "$FILE_SIZE_KB" ]; then
    echo "Error: File size is required (-s)"
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

# Calculate how to distribute files across loops
# Strategy: Always use 5 outer loops for initial creation, 1 for churn (20%)
TOTAL_FILES=$((FILES_THOUSANDS * 1000))
OUTER_LOOPS=5
INNER_LOOP_COUNT=$((TOTAL_FILES / OUTER_LOOPS))

# For churn rate: always use 1 outer loop (20% of 5 loops)
CHURN_OUTER_LOOPS=1
CHURN_INNER_LOOP_COUNT=$INNER_LOOP_COUNT

# Calculate storage size needed (files * size * 1.5 for overhead)
STORAGE_GB=$(( (FILES_THOUSANDS * FILE_SIZE_KB * 15) / (10 * 1024) + 1 ))
if [ $STORAGE_GB -lt 10 ]; then
    STORAGE_GB=10
fi

# Create workload name based on parameters
WORKLOAD_SUFFIX="${FILES_THOUSANDS}k-${FILE_SIZE_KB}kb"
if [ "$BLOCK_MODE" = true ]; then
    WORKLOAD_SUFFIX="${WORKLOAD_SUFFIX}-block"
fi
BASE_WORKLOAD_NAME="workload-calibrate-${WORKLOAD_SUFFIX}"
BASE_PVC_NAME="calibrate-${WORKLOAD_SUFFIX}"

# Check if deployment already exists and find available name
WORKLOAD_NAME="$BASE_WORKLOAD_NAME"
PVC_NAME="$BASE_PVC_NAME"
SUFFIX_NUM=2

while kubectl get deployment "$WORKLOAD_NAME" -n "$NAMESPACE" &> /dev/null; do
    WORKLOAD_NAME="${BASE_WORKLOAD_NAME}-${SUFFIX_NUM}"
    PVC_NAME="${BASE_PVC_NAME}-${SUFFIX_NUM}"
    SUFFIX_NUM=$((SUFFIX_NUM + 1))
done

if [ "$WORKLOAD_NAME" != "$BASE_WORKLOAD_NAME" ]; then
    echo "Note: Deployment $BASE_WORKLOAD_NAME already exists, using $WORKLOAD_NAME instead"
    echo ""
fi

echo "Creating calibration workload with:"
echo "  Namespace: $NAMESPACE"
echo "  Total files: $TOTAL_FILES (${FILES_THOUSANDS}k)"
echo "  File size: ${FILE_SIZE_KB}KB"
echo "  Block mode: $BLOCK_MODE"
if [ -n "$STORAGE_CLASS" ]; then
    echo "  Storage class: $STORAGE_CLASS"
else
    echo "  Storage class: (cluster default)"
fi
echo "  Files per version: $INNER_LOOP_COUNT"
echo "  Total versions: $OUTER_LOOPS (v1-v${OUTER_LOOPS})"
echo "  Churning files: $CHURN_INNER_LOOP_COUNT (version v1 - 20% churn rate)"
echo "  Storage size: ${STORAGE_GB}Gi"

# Create namespace if it doesn't exist
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
else
    echo "Namespace $NAMESPACE already exists"
fi

# Generate the YAML manifest
MANIFEST=$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $WORKLOAD_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $WORKLOAD_NAME
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: $WORKLOAD_NAME
    spec:
      containers:
      - command:
        - sh
        - -c
        - -e
        - |
EOF
)

# Add block mode specific commands if needed
if [ "$BLOCK_MODE" = true ]; then
    MANIFEST+=$(cat <<'EOF'

          mkfs.ext4 /dev/blockdata
          mkdir -p /data
          mount -t ext4 /dev/blockdata /data
EOF
)
else
    # Add newline after | for non-block mode
    MANIFEST+="
"
fi

# Add the main script
MANIFEST+=$(cat <<EOF

          cd /data
          # create initial data 
          if [ ! -f initial ]
          then
            echo "Starting initial filesystem generation at \$(date)"
            date > generation_start_time
            for j in \$(seq 1 $OUTER_LOOPS)
            do 
              for i in \$(seq 1 $INNER_LOOP_COUNT); do dd if=/dev/urandom of=\$i.v\$j.bin bs=${FILE_SIZE_KB}K count=1; echo "created \$i.v\$j.bin"; done
            done
            # all the initial filesystem is created we mark it
            # by creating an initial file if the pod restart it won't try to 
            echo "Completed initial filesystem generation at \$(date)"
            date > generation_end_time
            touch initial
          fi 
          # implement churn rate (20% - recreates v1 files every 10 hours)
          # notice the & to run in background during the sleep
          while true 
          do 
            for i in \$(seq 1 $CHURN_INNER_LOOP_COUNT); do dd if=/dev/urandom of=\$i.v1.bin bs=${FILE_SIZE_KB}K count=1; echo "created \$i.v1.bin"; done &
            sleep 36000
          done
EOF
)

# Add container image and resources
if [ "$BLOCK_MODE" = true ]; then
    MANIFEST+=$(cat <<'EOF'

        image: docker.io/ubuntu:latest
        imagePullPolicy: IfNotPresent
        # needed to create filesystem and mount
        # you need to add this anyuid scc to the service account
        securityContext: 
          privileged: true
EOF
)
else
    MANIFEST+=$(cat <<'EOF'

        image: docker.io/alpine:latest
        imagePullPolicy: IfNotPresent
EOF
)
fi

# Add resource requests
MANIFEST+=$(cat <<EOF

        name: ${WORKLOAD_NAME}-container
        resources:
          requests:
            cpu: 1
            memory: 1Gi
EOF
)

# Add volume mounts/devices based on mode
if [ "$BLOCK_MODE" = true ]; then
    MANIFEST+=$(cat <<'EOF'

        volumeDevices:
        - devicePath: /dev/blockdata
          name: data
EOF
)
else
    MANIFEST+=$(cat <<'EOF'

        volumeMounts:
        - mountPath: /data
          name: data
EOF
)
fi

# Add volumes
MANIFEST+=$(cat <<EOF

      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $PVC_NAME
EOF
)

# Add document separator
MANIFEST+="
---
"

# Add PVC
if [ "$BLOCK_MODE" = true ]; then
    MANIFEST+=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteOnce
  volumeMode: Block
  resources:
    requests:
      storage: ${STORAGE_GB}Gi
EOF
)
    if [ -n "$STORAGE_CLASS" ]; then
        MANIFEST+=$(cat <<EOF
  storageClassName: $STORAGE_CLASS
EOF
)
    fi
else
    MANIFEST+=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_GB}Gi
EOF
)
    if [ -n "$STORAGE_CLASS" ]; then
        MANIFEST+=$(cat <<EOF
  storageClassName: $STORAGE_CLASS
EOF
)
    fi
fi

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
echo "✓ Calibration workload created successfully in namespace: $NAMESPACE"
echo ""

if [ "$BLOCK_MODE" = true ]; then
    echo "Note: Block mode requires privileged access."
    echo "For OpenShift, grant the privileged SCC to the default service account:"
    echo "  oc adm policy add-scc-to-user privileged -z default -n $NAMESPACE"
    echo ""
fi

echo "To check the status:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl logs -n $NAMESPACE deployment/$WORKLOAD_NAME -f"
echo ""
echo "To delete the workload:"
echo "  kubectl delete deployment $WORKLOAD_NAME -n $NAMESPACE"
echo "  kubectl delete pvc $PVC_NAME -n $NAMESPACE"
