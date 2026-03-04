# PVC Explorer (explore-pvc.sh)

The `explore-pvc.sh` script creates a lightweight explorer pod to mount and inspect any PVC in your cluster. This is useful for verifying workload data, checking file contents, troubleshooting issues, or exploring restored PVCs.

It also supports browsing the contents of a **remote Kasten restore point** via SFTP — without performing a full restore — through Kasten's [FileRecoverySession](https://docs.kasten.io/latest/usage/restorefiles/) API.

## pvc-explorer Image

The restore-point SFTP mode requires a custom image (`docker.io/michaelcourcy/pvc-explorer`) that ships `openssh-client` (and therefore `sftp`) with a proper UID 1000 entry in `/etc/passwd`. This lets the pod run as a non-root user while satisfying OpenSSH's requirement for a valid passwd entry.

### Build and push

```bash
docker build --platform linux/amd64 -t michaelcourcy/pvc-explorer:latest .
docker push michaelcourcy/pvc-explorer:latest
```

To tag a specific version alongside `latest`:

```bash
VERSION=1.0.0
docker build --platform linux/amd64 \
  -t michaelcourcy/pvc-explorer:${VERSION} \
  -t michaelcourcy/pvc-explorer:latest .
docker push michaelcourcy/pvc-explorer:${VERSION}
docker push michaelcourcy/pvc-explorer:latest
```

> The image is based on `alpine:latest` and adds only `openssh-client` and the `explorer` user (UID 1000). It is intentionally minimal.

## Usage

```bash
./explore-pvc.sh [options]
```

## Options

| Option | Description | Required |
|--------|-------------|----------|
| `-n, --namespace` | Namespace where PVC exists (default: current context namespace) | No |
| `-p, --pvc` | Name of the PVC to mount | Yes |
| `-r, --restore-point` | Name of a remote restore point to browse via SFTP | No |
| `-u, --user` | User ID to run as (sets runAsUser and fsGroup) | No |
| `-d, --dry-run` | Display manifest without applying | No |
| `-h, --help` | Show help message | No |

## Security Features

The explorer pod runs with restrictive security settings:
- Non-root user (UID 1000 by default)
- No privilege escalation
- All capabilities dropped
- RuntimeDefault seccomp profile
- Optional fsGroup (only when `-u` is specified to avoid ownership changes on large filesystems)

## Examples

**Explore a calibrate workload PVC:**
```bash
./explore-pvc.sh -p calibrate-100k-500kb
```

**Explore PVC in specific namespace:**
```bash
./explore-pvc.sh -n test-calibrate -p calibrate-10k-10kb
```

**Explore with specific user ID:**
```bash
./explore-pvc.sh -n prod-test -p data-pvc -u 1000
```

**Preview manifest:**
```bash
./explore-pvc.sh -p my-data-pvc -d
```

**Browse a remote restore point via SFTP:**
```bash
./explore-pvc.sh -n test-cbt3 -p calibrate-1000k-30kb -r scheduled-5d5clnptxw
```

## Accessing the Explorer Pod

After the pod is created, access it with:
```bash
kubectl exec -it -n <namespace> <pod-name> -- sh
```

The script automatically provides this command in the output.

## Common Tasks

**List files in the PVC:**
```bash
kubectl exec -n <namespace> <pod-name> -- ls -lh /data
```

**Count files:**
```bash
kubectl exec -n <namespace> <pod-name> -- sh -c "ls -1 /data/*.bin 2>/dev/null | wc -l"
```

**Check disk usage:**
```bash
kubectl exec -n <namespace> <pod-name> -- df -h /data
```

**Verify file contents:**
```bash
kubectl exec -n <namespace> <pod-name> -- head -c 100 /data/1.v1.bin | od -A x -t x1z
```

**Check churn pattern (compare v1 vs v2 timestamps):**
```bash
kubectl exec -n <namespace> <pod-name> -- sh -c "ls -l /data/1.v*.bin"
```

## Restore Point SFTP Mode

When `-r` is provided, the script:

1. Validates the restore point exists in the namespace.
2. Checks that the restore point is remote (label `k10.kasten.io/exportType=portableAppData` must be present — local-only snapshots are rejected).
3. Generates an ephemeral ed25519 SSH key pair on the local machine.
4. Creates a Kubernetes Secret with the private key.
5. Creates an explorer pod (using `docker.io/michaelcourcy/pvc-explorer`) that mounts the PVC at `/data` and the private key at `/ssh-key/id_ed25519`.
6. Creates a Kasten `FileRecoverySession` referencing the restore point and the public key.
7. Waits up to 3 minutes for the session to reach `Ready` state.
8. Prints the SFTP endpoint and the exact command to run inside the container.

Once the session is ready, open a shell in the pod and connect:

```bash
# 1. Open a shell in the explorer pod
kubectl exec -it -n <namespace> <pod-name> -- sh

# 2. Inside the container, start the SFTP session
sftp -i /ssh-key/id_ed25519 -P <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<endpoint>
```

The script prints the exact values for `<port>` and `<endpoint>` when the session is ready.

The PVC is mounted at `/data` so you can copy individual files from the restore point directly into the live volume:

```bash
# Inside the sftp prompt — download a specific file into the PVC
sftp> get /some/path/file.bin /data/recovered-file.bin
```

## Cleanup (restore-point mode)

Three resources are created and must be deleted when you are done:

```bash
kubectl delete pod    <pod-name>            -n <namespace>
kubectl delete frs    <pvc-name>            -n <namespace>
kubectl delete secret explore-<pvc-name>-ssh-key -n <namespace>
```

The script prints the exact commands at the end of its output.

## Cleanup (standard mode)

**Delete the explorer pod:**
```bash
kubectl delete pod <pod-name> -n <namespace>
```

The script outputs the exact cleanup command after pod creation.

## Pod Naming Convention

Explorer pods are automatically named based on the PVC:
- Format: `explore-<pvc-name>[-N]`
- Examples:
  - `explore-calibrate-10k-10kb`
  - `explore-calibrate-100k-500kb`
  - `explore-my-data-pvc-2` (second instance)

## Notes

- The explorer pod remains running until manually deleted
- Multiple explorer pods can be created for the same PVC (with automatic name suffixing)
- The pod uses minimal resources (100m CPU, 128Mi memory)
- Data is mounted at `/data` inside the pod
- By default, `fsGroup` is not set to avoid ownership changes on large filesystems (can cause mount delays)
- The SSH key pair generated for SFTP mode is ephemeral — it is deleted from the local filesystem when the script exits
- The explorer and restore-point pods are tied to UID 1000 because OpenSSH requires the running user to exist in `/etc/passwd`; the `pvc-explorer` image creates the `explorer` user at exactly UID 1000

## OpenShift Compatibility

OpenShift enforces Security Context Constraints (SCCs) that block pods from running as a specific UID outside the namespace-allocated range. The default `restricted-v2` SCC assigns UIDs in a high range (e.g. `1000650000+`), which prevents the explorer pod from running as UID 1000.

Create a minimal custom SCC that grants exactly what the explorer pod needs — UID 1000, fsGroup 1000, no capabilities, no privilege escalation:

```yaml
# pvc-explorer-scc.yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: pvc-explorer
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: []
defaultAddCapabilities: []
fsGroup:
  type: MustRunAs
  ranges:
  - min: 1000
    max: 1000
readOnlyRootFilesystem: false
requiredDropCapabilities:
- ALL
runAsUser:
  type: MustRunAs
  uid: 1000
seccompProfiles:
- runtime/default
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
volumes:
- configMap
- emptyDir
- persistentVolumeClaim
- projected
- secret
```

Apply it:

```bash
oc apply -f pvc-explorer-scc.yaml
```

Grant it to the `default` service account in your namespace (the account pods use by default):

```bash
oc adm policy add-scc-to-user pvc-explorer -z default -n <namespace>
```

Equivalently, using a RoleBinding (useful when scripting or managing via GitOps):

```bash
oc create rolebinding pvc-explorer-scc \
  --clusterrole=system:openshift:scc:pvc-explorer \
  --serviceaccount=<namespace>:default \
  -n <namespace>
```

> **Note**: Both commands require cluster-admin or a role that can bind SCCs. The `oc adm policy` approach is simpler for one-off usage; the RoleBinding is preferred for declarative/GitOps workflows.
