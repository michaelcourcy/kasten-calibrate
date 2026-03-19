# Goal 

Test a 10 million files 10Tb CBT backup on AWS 

# EKS Install 

```
eksctl create cluster \
  --name mcourcy-cluster \
  --region us-east-1 \
  --nodegroup-name mcourcy-cluster-workers \
  --node-type m5.2xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 3
```

Associate OIDC provider (one-time setup) so that kube sa can assume role
```
eksctl utils associate-iam-oidc-provider --cluster  mcourcy-cluster --approve  --region us-east-1
```

Create IAM role for EBS CSI driver (with OIDC) and create also the ebs 
```
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster mcourcy-cluster \
  --region us-east-1 \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve
```

Install the EBS CSI driver addon
```
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster mcourcy-cluster \
  --region us-east-1 \
  --service-account-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKS_EBS_CSI_DriverRole \
  --force
```

Update kube config 
```
aws eks update-kubeconfig --name mcourcy-cluster --region us-east-1
```

Verify installation 
```
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

Create a CSI-based storage class:
```
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

Install the snapshot CRDs:
```
SNAPSHOTTER_VERSION=v8.2.0
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
```

Install the snapshot controller:
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

Verify the snapshot controller is running:
```
kubectl get pods -n kube-system -l app.kubernetes.io/name=snapshot-controller
```

Create VolumeSnapshotClass:
```
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-snapshot-class
  annotations:
      k10.kasten.io/is-snapshot-class: "true"    
driver: ebs.csi.aws.com
deletionPolicy: Delete
EOF
```

If later you need to delete the cluster 

```
eksctl delete cluster --name mcourcy-cluster --region us-east-1
```

# Create a node group with high performance node and deploy the big workload

The AWS EC2 m5.4xlarge instance has:

- vCPUs: 16
- Memory: 64 GiB
- EBS bandwidth: Up to 8,500 Mbps (≈ 1,062 MB/s)
- Network bandwidth: Up to 10 Gbps

Let's add 3 instance nodegroup on the cluster 

```
eksctl create nodegroup \
  --cluster mcourcy-cluster \
  --region us-east-1 \
  --name big-baby \
  --node-type m5.4xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 3
```

Create the test-cbt namespace with the big-baby node selector: 
```
kubectl create ns test-cbt 
kubectl annotate namespace test-cbt \
  "scheduler.kubernetes.io/node-selector=alpha.eksctl.io/nodegroup-name=big-baby"
```

Create the workload: 10 millions files of 1Mb.
```
curl -O https://raw.githubusercontent.com/michaelcourcy/kasten-calibrate/refs/heads/main/create-calibrate-workload.sh
chmod +x create-calibrate-workload.sh
./create-calibrate-workload.sh -n test-cbt -f 10000 -s 1024 -c ebs-sc
```

The full creation of the filesystem take around 5 hours. At each backup 20% of the filesystem 
will be replaced.

# Activate CBT on kasten with Direct EBS 

Create an AWS infra profile and make sure your identity in your infra profile has the required permissions 
https://docs.kasten.io/latest/install/aws/aws_permissions
```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ebs:ListSnapshotBlocks",
                "ebs:ListChangedBlocks",
                "ebs:GetSnapshotBlock"
            ],
            "Resource": "arn:aws:ec2:*::snapshot/*"
        }
    ]
}
```

Then annotate both the storage class and the infra profile for CBT

```
kubectl annotate storageclass ebs-sc k10.kasten.io/sc-supports-block-mode-exports=true
kubectl annotate pvc calibrate-10000k-1024kb -n test-cbt  k10.kasten.io/pvc-export-volume-in-block-mode=force
```

To ensure enough memory and cpu create this ActionPodSpec and ActionPodSpecBinding
```
cat <<EOF | kubectl create -f - 
apiVersion: config.kio.kasten.io/v1alpha1
kind: ActionPodSpec
metadata:
  name: big-block-upload
  namespace: test-cbt
spec:
  options:
    - podType: "export-block-volume-to-repository"
      resources:
        requests:
          cpu: 4
          memory: 12Gi
    - podType: "restore-block-volume-from-repository"
      resources:
        requests:
          cpu: 4
          memory: 12Gi
---
apiVersion: config.kio.kasten.io/v1alpha1
kind: ActionPodSpecBinding
metadata:
  name: big-block-upload
  namespace: test-cbt
spec:
  actionPodSpecRef:
    name: big-block-upload
    namespace: test-cbt
EOF
```

# Adapt the kasten configuration 

Also change the helm configuration to have enough backup and restore time 
```
helm repo update 
cat <<EOF | helm upgrade k10 -n kasten-io kasten/k10 -f -
workerPodCRDs:
  enabled: true
datastore:
  parallelBlockDownloads: 32
  parallelBlockUploads: 32
  cacheSizeLimitMB: 10240
timeout:
  blueprintBackup: 8000
  blueprintRestore: 8000
  jobWait: "8000"
auth:
  tokenAuth:
    enabled: true    
global:
  persistence:
    storageClass: gp2
prometheus:
  server:
    persistentVolume:
      storageClass: gp2
EOF
```

# Verify CBT with Direct EBS is working

> Direct EBS CBT support is documented in the Kasten Storage Integration page under the [Amazon Elastic Block Storage (EBS) Integration](https://docs.kasten.io/latest/install/storage/#ebs_int) section.

Kasten supports two modes of changed-block tracking:

- **Generic CBT**: Kasten creates a temporary clone PVC from the previous snapshot, mounts it, and scans the entire volume block by block — comparing each block against what was last uploaded to the target location. The full scan is handled by Kasten itself, so it takes time proportional to the volume size.

- **Direct EBS CBT**: Kasten calls the AWS EBS API (`ListChangedBlocks`) which returns the list of changed blocks directly from AWS, by comparing two EBS snapshots server-side. No clone PVC is needed. This is significantly faster because AWS handles the diff computation natively and Kasten only transfers the blocks that actually changed.

The key indicator that **Direct EBS CBT** is truly in use is the **absence of any clone PVC** in the `kasten-io` namespace during a backup run. With generic CBT you would see a temporary PVC appear briefly in `kasten-io`; with Direct EBS CBT that clone never appears.

## How to verify

Trigger a policy run (at least the second one, so a previous snapshot exists), then watch the `kasten-io` namespace for PVCs:

```
kubectl get pvc -n kasten-io -w
```

If Direct EBS CBT is active, **no clone PVC will appear** during the export phase. If you do see a PVC created (typically named after the source PVC with a random suffix), Kasten has fallen back to generic CBT — check the annotations on the storage class and PVC, and verify that the infra profile has the required EBS permissions (`ebs:ListSnapshotBlocks`, `ebs:ListChangedBlocks`, `ebs:GetSnapshotBlock`).

The backup size of the second run should also be significantly smaller than the first (only the changed blocks), which is another strong signal that CBT is working correctly.


