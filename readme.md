# Kasten Calibrate Workload Generator

A flexible shell script for generating Kubernetes workloads with configurable file systems to test and calibrate backup/restore operations, storage performance, and data protection solutions.

## Purpose

This script creates Kubernetes deployments that generate and maintain file systems with specific characteristics:
- **Configurable file count and size** - Test with thousands to millions of files
- **Predictable churn patterns** - 20% of files are continuously updated (v1 files), while 80% remain static (v2-v5 files)
- **Block or filesystem mode** - Support for both standard PVC mounts and raw block devices
- **Resource-intensive workloads** - Useful for testing backup solutions like Kasten K10, Velero, or other data protection tools

## Prerequisites

- Kubernetes cluster (1.19+) or OpenShift cluster
- `kubectl` or `oc` CLI configured with cluster access
- Sufficient storage capacity in your cluster
- For block mode: Storage class that supports block volumes and privileged containers

## Installation

1. Clone or download the script:
```bash
curl -O https://raw.githubusercontent.com/michaelcourcy/kasten-calibrate/refs/heads/main/create-calibrate-workload.sh
chmod +x create-calibrate-workload.sh
```

2. Verify kubectl/oc access:
```bash
kubectl get nodes
```

## Usage

```bash
./create-calibrate-workload.sh [options]
```

### Options

| Option | Description | Required |
|--------|-------------|----------|
| `-n, --namespace` | Target namespace (default: current context namespace) | No |
| `-f, --files` | Number of files in thousands (e.g., 5000 = 5 million files) | Yes |
| `-s, --size` | Size of each file in KB | Yes |
| `-b, --block-mode` | Use raw block device mode | No |
| `-c, --storage-class` | Storage class name (default: cluster default) | No |
| `-d, --dry-run` | Display manifest without applying | No |
| `-h, --help` | Show help message | No |

## File Organization

The script creates files with the following pattern:
- **Files**: `1.v1.bin` through `N.v5.bin`
- **5 versions** (v1-v5) - Each file exists in 5 versions
- **Churn pattern**: Only v1 files are updated every 10 hours (20% churn rate)
- **Static files**: v2-v5 files remain unchanged after initial creation

Example for `-f 10 -s 10` (10k files of 10KB each):
- Creates: 2,000 files × 5 versions = 10,000 total files
- Churning: 2,000 v1 files (20%)
- Static: 8,000 v2-v5 files (80%)

## Examples

### Basic Examples

**Create a small test workload (10k files, 10KB each):**
```bash
./create-calibrate-workload.sh -n test-calibrate -f 10 -s 10
```

**Create a larger workload (100k files, 500KB each):**
```bash
./create-calibrate-workload.sh -n prod-test -f 100 -s 500
```

**Create a very large workload (5 million files, 10KB each):**
```bash
./create-calibrate-workload.sh -n large-test -f 5000 -s 10
```

### Using Current Namespace

**Deploy to current context namespace:**
```bash
./create-calibrate-workload.sh -f 50 -s 100
```

### Block Mode Examples

**Create workload with raw block device:**
```bash
./create-calibrate-workload.sh -n block-test -f 10 -s 10 -b
```

**Block mode with custom storage class:**
```bash
./create-calibrate-workload.sh -n block-test -f 100 -s 50 -b -c premium-block-storage
```

> **Note**: Block mode requires privileged access. For OpenShift, grant the privileged SCC:
> ```bash
> oc adm policy add-scc-to-user privileged -z default -n <namespace>
> ```

### Storage Class Examples

**Use specific storage class:**
```bash
./create-calibrate-workload.sh -n test -f 10 -s 10 -c ebs-gp3
```

**AWS EBS example:**
```bash
./create-calibrate-workload.sh -n aws-test -f 100 -s 100 -c ebs-sc
```

**Azure managed disk example:**
```bash
./create-calibrate-workload.sh -n azure-test -f 100 -s 100 -c managed-premium
```

### Dry Run Examples

**Preview manifest before applying:**
```bash
./create-calibrate-workload.sh -n test -f 10 -s 10 -d
```

**Save manifest to file:**
```bash
./create-calibrate-workload.sh -n test -f 100 -s 500 -d > workload-manifest.yaml
```

### Multiple Workloads

**Create multiple workloads in same namespace:**
```bash
./create-calibrate-workload.sh -n multi-test -f 10 -s 10
./create-calibrate-workload.sh -n multi-test -f 10 -s 10
./create-calibrate-workload.sh -n multi-test -f 10 -s 10
```
The script automatically appends numeric suffixes (e.g., `workload-calibrate-10k-10kb-2`, `workload-calibrate-10k-10kb-3`)

## Workload Naming Convention

Workloads are automatically named based on parameters:
- Format: `workload-calibrate-<files>-<size>[-block][-N]`
- Examples:
  - `workload-calibrate-10k-10kb` (10k files, 10KB each)
  - `workload-calibrate-100k-500kb` (100k files, 500KB each)
  - `workload-calibrate-10k-10kb-block` (block mode)
  - `workload-calibrate-10k-10kb-2` (second instance)

## Storage Calculation

Storage is automatically calculated with 1.5× overhead:
- Formula: `(files × size × 1.5) / 1024 MB`
- Minimum: 10Gi
- Examples:
  - 10k files × 10KB = ~10Gi
  - 100k files × 500KB = ~74Gi
  - 5M files × 10KB = ~74Gi

## Monitoring Workloads

**Check pod status:**
```bash
kubectl get pods -n <namespace>
```

**Watch logs:**
```bash
kubectl logs -n <namespace> deployment/<workload-name> -f
```

**Check file creation progress:**
```bash
kubectl exec -n <namespace> deployment/<workload-name> -- ls -lh /data | head -20
```

**Count created files:**
```bash
kubectl exec -n <namespace> deployment/<workload-name> -- sh -c "ls -1 /data/*.bin | wc -l"
```

## Cleanup

**Delete a specific workload:**
```bash
kubectl delete deployment <workload-name> -n <namespace>
kubectl delete pvc <pvc-name> -n <namespace>
```

**Delete entire namespace:**
```bash
kubectl delete namespace <namespace>
```

**Script-generated cleanup commands:**
The script outputs cleanup commands after successful deployment. Example:
```bash
kubectl delete deployment workload-calibrate-10k-10kb -n test-calibrate
kubectl delete pvc calibrate-10k-10kb -n test-calibrate
```

## Use Cases

### Backup Testing
Test backup solutions with realistic file system scenarios:
```bash
# Create workload
./create-calibrate-workload.sh -n backup-test -f 100 -s 100

# Run backup
kasten-backup.sh backup-test

# Monitor churn - v1 files will update every 10 hours
kubectl logs -n backup-test deployment/workload-calibrate-100k-100kb -f
```

### Storage Performance Testing
Calibrate storage performance with different file configurations:
```bash
# Many small files
./create-calibrate-workload.sh -n perf-small -f 1000 -s 10

# Fewer large files
./create-calibrate-workload.sh -n perf-large -f 10 -s 10000
```

### Data Protection Validation
Validate restore operations and incremental backups:
```bash
# Initial workload
./create-calibrate-workload.sh -n validation -f 50 -s 100

# After first backup, v1 files will churn
# Second backup should be incremental with only 20% of data
```

### Block Device Testing
Test block mode storage capabilities:
```bash
./create-calibrate-workload.sh -n block-perf -f 100 -s 100 -b -c fast-block-storage
```

## Troubleshooting

### Pod in ImagePullBackOff
Create a pull secret if using private registries:
```bash
kubectl create secret docker-registry my-secret \
  --docker-server=docker.io \
  --docker-username=<username> \
  --docker-password=<password> \
  -n <namespace>

kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "my-secret"}]}' \
  -n <namespace>
```

### Block Mode Mount Fails (OpenShift)
Grant privileged SCC to the service account:
```bash
oc adm policy add-scc-to-user privileged -z default -n <namespace>
```

### PVC Pending
Check storage class exists and has available capacity:
```bash
kubectl get storageclass
kubectl describe pvc <pvc-name> -n <namespace>
```

### Out of Memory
Reduce file count or increase memory limits:
```bash
# Edit deployment after creation
kubectl edit deployment <workload-name> -n <namespace>
```

## Technical Details

### Container Images
- **Filesystem mode**: `docker.io/alpine:latest`
- **Block mode**: `docker.io/ubuntu:latest` (requires privileged access)

### Resource Requests
Each workload requests:
- CPU: 1 core
- Memory: 1Gi

### Churn Implementation
- Initial creation: All v1-v5 files created once
- Continuous churn: v1 files recreated every 10 hours (36000 seconds)
- Background execution: Churn runs in background (`&`) during sleep

### File Naming Pattern
- Format: `<number>.v<version>.bin`
- Example: `1.v1.bin`, `1.v2.bin`, ..., `2000.v5.bin`
- Version v1: Churning files
- Versions v2-v5: Static files

### Data Generation
- Files are generated using `/dev/urandom` (random data)
- This approach **prevents deduplication and compression** to create worst-case scenarios
- Real-world workloads with compressible/dedupable data will achieve:
  - **Better compression ratios** (smaller backups)
  - **Faster backup/restore times**
  - **Lower storage costs**
- Use this script to establish baseline performance; actual production workloads typically perform 2-5× better





