# Laravel → GitHub Actions → ArgoCD → Rancher

GitOps pipeline: pushing to `main` builds two images (PHP-FPM + Nginx),
pushes them to GHCR, commits the new tag into `k8s/app/deployment.yaml`,
and ArgoCD (watching this repo) auto-syncs the change onto your Rancher
cluster.

```
push to main
   │
   ▼
GitHub Actions: build php-fpm & nginx images ──► ghcr.io
   │
   ▼
GitHub Actions: bump image tag in k8s/app/deployment.yaml, git commit
   │
   ▼
ArgoCD detects the git diff ──► syncs k8s/ manifests to the cluster
   │
   ▼
PreSync hook Job runs `php artisan migrate --force`
   │
   ▼
Deployment rolls out new pods (php-fpm + nginx per pod)
```

## Repo layout

```
Dockerfile                    # php-fpm image (multi-stage: composer -> php:8.3-fpm-alpine)
docker/php/local.ini          # production php.ini tweaks
docker/nginx/Dockerfile       # nginx image, bakes in public/ at build time
docker/nginx/default.conf     # vhost, proxies *.php to 127.0.0.1:9000
.github/workflows/deploy.yml  # build, push, commit-back
k8s/namespace.yaml
k8s/mysql/                    # MySQL Deployment + PVC + Service + Secret
k8s/app/                      # Laravel Deployment (2 containers/pod) + Service + Ingress + migrate Job
argocd/application.yaml       # ArgoCD Application resource
```

Each pod runs **two containers**: `php-fpm` and `nginx`. Both images are
built from the same git commit, so the nginx image always ships the
matching `public/` assets — no shared volume needed.

## 1. Replace the placeholders

Before anything works, do a find-and-replace in this repo for:

- `OWNER/REPO` → your GitHub org/user and repo name (used in image names,
  `.github/workflows/deploy.yml`, `argocd/application.yaml`,
  `k8s/app/deployment.yaml`, `k8s/app/migrate-job.yaml`)
- `your-app.example.com` → your real domain (`k8s/app/ingress.yaml`,
  `k8s/app/configmap.yaml`)
- The `CHANGE_ME` values in `k8s/mysql/secret.yaml` and
  `k8s/app/secret.yaml`

**Do not commit real secrets in plaintext.** For a real deployment, manage
`k8s/mysql/secret.yaml` and `k8s/app/secret.yaml` one of these ways instead:
- Create/edit them directly in Rancher's UI (Storage/Secrets in the
  target namespace) and keep them out of git entirely, or
- Encrypt them with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
  or [SOPS](https://github.com/getsops/sops) and let ArgoCD sync the
  encrypted version, or
- Use the [External Secrets Operator](https://external-secrets.io/) to
  pull from Vault/AWS Secrets Manager/etc.

## 2. GitHub repo setup

1. **Packages permission**: GHCR is used automatically via the built-in
   `GITHUB_TOKEN` — no extra PAT needed for pushing images.
2. Repo → Settings → Actions → General → Workflow permissions → set to
   **"Read and write permissions"** (needed for the commit-back step and
   for `packages: write`).
3. If your manifests live in a **separate GitOps repo** instead of this
   one, generate a fine-grained PAT with `contents: write` on that repo,
   store it as `GITOPS_PAT` in this repo's secrets, and uncomment the
   `repository:` / `token:` lines in the `update-manifests` job.
4. First time only: make the GHCR packages (`REPO-app`, `REPO-nginx`)
   **public**, or give your cluster's imagePullSecret read access —
   otherwise Kubernetes can't pull them. (Package → Settings → Change
   visibility, or link the package to the repo so repo collaborators get
   pull access automatically.)

## 3. Rancher: cluster + namespace + registry access

1. In Rancher, either **import an existing cluster** (Cluster Management
   → Import Existing) or provision a new one (RKE2/K3s) — either works,
   ArgoCD just needs a kubeconfig/API endpoint for it.
2. Create the namespace, or let ArgoCD create it for you (already set via
   `CreateNamespace=true` in `argocd/application.yaml`).
3. If your GHCR packages are **private**, create an imagePullSecret in the
   `laravel-app` namespace (Rancher UI: Namespace → Secrets → Registry, or):
   ```bash
   kubectl create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io \
     --docker-username=<github-username> \
     --docker-password=<PAT with read:packages> \
     -n laravel-app
   ```
   Then add `imagePullSecrets: [{name: ghcr-pull}]` to the pod spec in
   `k8s/app/deployment.yaml`.
4. Confirm an ingress controller is installed (Rancher ships nginx-ingress
   by default on RKE2/K3s clusters). If you want automatic TLS, install
   **cert-manager** from Rancher's Apps & Marketplace catalog and
   uncomment the `cluster-issuer` annotation in `k8s/app/ingress.yaml`.
5. Check your cluster's available `storageClassName` (Storage → Storage
   Classes in Rancher) and set it in `k8s/mysql/pvc.yaml` if the default
   isn't suitable.

## 4. Install ArgoCD and point it at the cluster

If ArgoCD isn't already running:
- Install it in Rancher via **Apps & Marketplace → Charts → Argo CD**, or
  `kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`

If ArgoCD runs on a **different** cluster than the app:
- In the ArgoCD UI/CLI, go to **Settings → Clusters → Add Cluster** and
  register the Rancher cluster (Rancher exposes a standard kubeconfig for
  this — Cluster → "Kubeconfig File" button). Then set `spec.destination.server`
  in `argocd/application.yaml` to that cluster's URL instead of
  `https://kubernetes.default.svc`.

Apply the Application resource:
```bash
kubectl apply -f argocd/application.yaml
```

ArgoCD will now watch this repo's `k8s/` path, auto-sync on every commit,
prune resources removed from git, and self-heal any manual cluster drift.

## 5. First deploy

```bash
git add .
git commit -m "initial GitOps setup"
git push origin main
```

This triggers the Action, which builds/pushes images and commits the tag
bump. Watch the rollout either in the ArgoCD UI or:
```bash
kubectl -n laravel-app get pods -w
```

## Notes / things to tune later

- `k8s/app/deployment.yaml` sets `replicas: 2` — bump this or add an HPA
  once you know real load.
- The MySQL Deployment is a **single instance with a PVC** (fine for
  small/medium apps). For production-grade HA, swap it for a managed DB
  (RDS/Cloud SQL) or an operator (e.g. Percona/MySQL Operator) — set
  `DB_HOST` in `k8s/app/configmap.yaml` accordingly and drop `k8s/mysql/`.
- Laravel's cache/session/queue are set to the `database` driver in
  `configmap.yaml` so nothing extra is required; swap to Redis later by
  adding a Redis Deployment + Service and changing those three env vars.
- `docker/php/local.ini` sets `opcache.validate_timestamps=0`, which
  means code changes only take effect on a fresh container — expected
  for immutable image deploys, just don't `kubectl cp` files in manually.
