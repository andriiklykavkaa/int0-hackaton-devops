# Kyverno Policies

This directory contains the baseline Kyverno policies for the hackathon cluster.

The policies target only the main Retail Store service pods by matching:

- `app.kubernetes.io/owner=retail-store-sample`
- `app.kubernetes.io/component=service`

That keeps enforcement focused on the application workloads and avoids blocking
the in-cluster databases and brokers unless they are explicitly brought under
policy later.

Included policies:

- `require-pod-hardening.yaml`: enforce non-root, read-only filesystem, no privilege escalation, and `RuntimeDefault` seccomp.
- `disallow-latest-tag.yaml`: block `:latest` images.
- `require-resource-requests.yaml`: require CPU and memory requests plus a memory limit.

Test manifests:

- `tests/invalid-latest-pod.yaml`
- `tests/invalid-security-pod.yaml`
- `tests/valid-pod.yaml`

Typical stage rollout:

1. Ensure Kyverno is installed in the cluster.
2. Apply the policies in `platform/kyverno/policies/`.
3. Run the test manifests in a temporary namespace.
4. Promote the same policies to production after stage validation.
