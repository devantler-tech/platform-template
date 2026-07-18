# Audit-log forwarder

This default-off OpenTelemetry Collector DaemonSet tails the kube-apiserver
audit log written by [`talos/cluster/audit-logging.yaml`](../../../../talos/cluster/audit-logging.yaml)
and forwards a searchable copy to Coroot. The on-node, rotated file remains the
resilient primary record.

The forwarder belongs in the Hetzner `infrastructure` layer beside the `Coroot`
custom resource. That resource asks the operator to create `coroot-api-key`,
which the forwarder consumes without committing a credential. It is not part of
the Docker option because the local Talos configuration does not write this host
audit file.

Keep these Talos-specific safety details when activating the option:

- leave `hostPath.type` unset because the kubelet mount namespace cannot stat
  the host path;
- mount the audit directory read-only and retain only `DAC_READ_SEARCH`;
- keep checkpoints in an `emptyDir` under kubelet-managed storage; and
- keep Flux substitution disabled so the collector receives its `${env:...}`
  expressions unchanged.
