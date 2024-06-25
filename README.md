# nvme-ssd-provisioner

Based on eks-nvme-ssd-provisioner with minor changes.

The eks-nvme-ssd-provisioner will format and mount NVMe SSD disks on EKS
nodes. This is needed to make the sig-storage-local-static-provisioner work
well with EKS clusters. The eks-nvme-ssd-provisioner will create a raid0 device
if multiple NVMe SSD disks are found.

The resources in `manifests` expect the following node selector

```
aws.amazon.com/eks-local-ssd: "true"
```

Therefore you must make sure to set that label on all nodes that you want to
use with the eks-nvme-ssd-provisioner and sig-storage-local-static-provisioner.

## Helm

```
helm upgrade --install --namespace=kube-system eks-nvme-ssd-provisioner ./helm/eks-nvme-ssd-provisioner
```
