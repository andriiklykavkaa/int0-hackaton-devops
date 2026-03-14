# Argo CD Installation

Install Argo CD into the cluster (run once by Participant 1 or 3 after GKE is up):

```bash
kubectl apply -f gitops/argocd/install/namespace.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready
kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s

# Bootstrap the App-of-Apps (registers all Application manifests)
kubectl apply -f gitops/argocd/app-of-apps.yaml
```

## Access the UI

```bash
# Port-forward (local access)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```
