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
- `disallow-privileged.yaml`: block privileged containers across standard, init, and ephemeral containers.
- `disallow-latest-tag.yaml`: block `:latest` images.
- `require-resource-requests.yaml`: require CPU and memory requests plus a memory limit.

Test manifests:

- `tests/invalid-latest-pod.yaml`
- `tests/invalid-privileged-pod.yaml`
- `tests/invalid-security-pod.yaml`
- `tests/valid-pod.yaml`

Typical stage rollout:

1. Reconcile the Kyverno platform installation in the stage cluster.
2. Apply the policies in `platform/kyverno/policies/`.
3. Run the test manifests in a temporary namespace.
4. Promote the same policies to production after stage validation.

Workflow ownership model:

- `.github/workflows/kyverno-stage.yaml` is the owner of the Kyverno bootstrap in the stage cluster.
- The workflow intentionally uses server-side apply to reconcile the upstream Kyverno install manifest.
- The workflow then validates the Retail Store-specific admission policies with known-good and known-bad test pods.
