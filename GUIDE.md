# argocd-task: how the charts were built and how to deploy them with Argo CD

This repository holds the Helm charts for the local kind cluster: the Argo CD installation
(`argocd/`) and the application charts (`charts/`). The application chart
`charts/web-application` (Helm chart name `argocd-task`) serves a small static page with nginx
over HTTPS. Traffic enters the kind cluster through the existing Traefik ingress controller with TLS
passthrough, the same way `argocd.localhost` is exposed, and nginx terminates TLS with a
certificate signed by the local **ArgoCD Local CA**.

- [Part 1: what was built](#part-1-what-was-built)
  - [Architecture](#architecture)
  - [Repository layout](#repository-layout)
  - [values.yaml](#valuesyaml)
  - [Templates](#templates)
  - [Certificates](#certificates)
  - [The ingress route](#the-ingress-route)
  - [Security hardening](#security-hardening)
  - [Problems found along the way](#problems-found-along-the-way)
  - [Testing](#testing)
  - [The Argo CD chart](#the-argo-cd-chart)
  - [Deploying the charts with Helm](#deploying-the-charts-with-helm)
- [Part 2: deploy a new namespace with Argo CD](#part-2-deploy-a-new-namespace-with-argo-cd)

---

## Part 1: what was built

### Architecture

```
Browser ──HTTPS :443──▶ Traefik (namespace traefik, entrypoint "websecure")
                          │  IngressRouteTCP: match HostSNI(<host>), tls.passthrough
                          │  (Traefik reads only the SNI name; traffic stays encrypted)
                          ▼
                        Service <fullname> :443  (namespace of the release)
                          ▼
                        nginx pod :443  ── terminates TLS with Secret <fullname>-tls
                                           (certificate signed by ArgoCD Local CA)
```

- Only Traefik may connect to the pod (NetworkPolicy), and nginx cannot open outbound
  connections.
- The page (`index.html` + `styles.css`) and the nginx config come from ConfigMaps
  rendered by the chart. The certificate comes from a Secret that is created outside Git.

### Repository layout

```
argocd-task/                      repo root
├── charts/                       application Helm charts, one directory each
│   └── web-application/          the nginx page (Helm chart name "argocd-task")
├── argocd/                       Helm chart that installs Argo CD
│   ├── charts/                   downloaded dependency (argo-cd-*.tgz), not in Git
│   └── applications/             Argo CD Application manifests, one per instance
├── scripts/                      issue-tls-cert.sh, verify-app.sh
├── .gitignore
└── GUIDE.md
```

The root `charts/` folder only holds the application charts. It is unrelated to `argocd/charts/`,
which is Helm's standard folder for a chart's downloaded dependencies.

| Path | Purpose |
|---|---|
| `charts/` | One directory per application Helm chart |
| `charts/web-application/Chart.yaml` | Chart metadata (created by `helm create`) |
| `charts/web-application/values.yaml` | All settings; the only place hostnames are written |
| `charts/web-application/files/index.html.tpl` | Page template (title, one card per subject) |
| `charts/web-application/files/styles.css.tpl` | Stylesheet template (accent colours generated from `colors`) |
| `charts/web-application/files/ca.crt` | **Public** certificate of ArgoCD Local CA (no private key) |
| `charts/web-application/templates/` | Kubernetes manifests, see [Templates](#templates) |
| `scripts/issue-tls-cert.sh` | Issues or rotates the server certificate and creates the namespace and the TLS Secret |
| `scripts/verify-app.sh` | 55 end-to-end checks for a deployed instance |
| `argocd/` | Helm chart that installs Argo CD itself, see [The Argo CD chart](#the-argo-cd-chart) |
| `argocd/applications/` | Argo CD `Application` manifests, one per deployed instance (excluded from the chart by `.helmignore`) |
| `.gitignore` | Keeps the downloaded `argocd/charts/*.tgz` dependency out of Git |

### values.yaml

The important settings, grouped by purpose:

| Setting | Value | Why |
|---|---|---|
| `image` | `nginx:1.31.7-alpine` | Official image, pinned to an exact version (the `helm create` default would have been nginx 1.16.0 from 2019) |
| `fullnameOverride` | `lia-temp-page` | Fixed resource names. The Service name is part of the certificate, so it must not depend on the release name |
| `hosts` | `[lia-temp-page.localhost]` | Public hostnames. **The only place a hostname is written**; everything else is derived from this list |
| `containerPort` / `service.port` | `443` / `443` | Standard HTTPS port inside the pod and on the Service |
| `podSecurityContext` | UID/GID 101, `runAsNonRoot`, seccomp `RuntimeDefault`, sysctl `net.ipv4.ip_unprivileged_port_start=0` | Runs as the image's `nginx` user; the sysctl lets that non-root user bind port 443 |
| `securityContext` | `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | Container hardening |
| `serviceAccount.automount` | `false` | The pod never calls the Kubernetes API, so it gets no token |
| `tls.secretName` | `""` (= `<fullname>-tls`) | Secret holding `tls.crt` / `tls.key`; created by the script, not by the chart |
| `tls.rotation` | not set (= `"1"`) | Change it to restart the pod after rotating the certificate |
| `tls.caConfigMap.enabled` | `true` | Publishes `files/ca.crt` as ConfigMap `<fullname>-ca` |
| `ingressRouteTCP` | enabled, entrypoint `websecure` | Traefik route with TLS passthrough |
| `networkPolicy` | enabled, peer = pods labelled `app.kubernetes.io/name: traefik` in namespace `traefik` | Only Traefik can reach nginx |
| `resources` | requests 10m / 16Mi, limits 100m / 64Mi | Bounded resource use |
| `livenessProbe` / `readinessProbe` | `GET https://:443/healthz` | Answered by nginx's catch-all server |
| `subjects`, `colors`, `page.title` | page content | One card per subject; colours rotate through `colors` |

### Templates

| Template | Creates | Notes |
|---|---|---|
| `_helpers.tpl` | name and label helpers | From `helm create` |
| `_tls.tpl` | `argocd-task.tlsSecretName`, `argocd-task.hosts`, `argocd-task.dnsNames` | `dnsNames` = every host + `<svc>`, `<svc>.<ns>`, `<svc>.<ns>.svc`, `<svc>.<ns>.svc.cluster.local`. Fails rendering if `hosts` is empty |
| `deployment.yaml` | Deployment | Mounts the page, nginx config and TLS Secret read-only (key file mode `0440`). The only writable paths are two `emptyDir` volumes, `/var/cache/nginx` and `/run`. Checksum annotations restart the pod when the page or config changes |
| `service.yaml` | Service (ClusterIP) | Port 443 → container port `https` |
| `ingressroutetcp.yaml` | Traefik `IngressRouteTCP` | ``HostSNI(`a`) \|\| HostSNI(`b`)…`` built from `hosts`, `tls.passthrough: true`. See [The ingress route](#the-ingress-route) |
| `nginx-config.yaml` | ConfigMap `<fullname>-nginx` | `default.conf`: a catch-all server (answers `/healthz` for probes, `421` for anything else) and the main server for `dnsNames` |
| `configmap.yaml` | ConfigMap `<fullname>-html` | `index.html` and `styles.css`, rendered with `tpl` from `files/` |
| `ca-configmap.yaml` | ConfigMap `<fullname>-ca` | The public CA certificate, for clients in the namespace |
| `networkpolicy.yaml` | NetworkPolicy | Ingress from Traefik (and the test client) on port `https`; egress only back to those same peers |
| `serviceaccount.yaml` | ServiceAccount | From `helm create`, with `automountServiceAccountToken: false` |
| `hpa.yaml` | HorizontalPodAutoscaler | From `helm create`; disabled (`autoscaling.enabled: false`) |
| `tests/test-connection.yaml` | `helm test` pod | curl with full certificate verification against the CA, by Service DNS name and by every host. Has its own labels so the app's NetworkPolicy doesn't select it |
| `NOTES.txt` | text printed after install | URLs and the required Secret name |

The `ingress.yaml` template from `helm create` was removed because a standard Ingress cannot do
TLS passthrough.

#### The nginx configuration

The main server block (`nginx-config.yaml`):

- **TLS:** TLS 1.2 and 1.3 only, AEAD ciphers only, session tickets off.
- **Security headers:** `Strict-Transport-Security`, `Content-Security-Policy`
  (`default-src 'none'; style-src 'self'; …`), `X-Content-Type-Options`, `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`, `Permissions-Policy`, `Cross-Origin-Opener-Policy`,
  `Cross-Origin-Resource-Policy`.
- **Requests:** only `GET` and `HEAD` (others get `405`). Request bodies are capped at 1 KB,
  directory listing is off, and `server_tokens off` hides the nginx version.
- **Host names:** requests for a name that isn't in `dnsNames` hit the catch-all server and
  get `421`.

### Certificates

#### The CA (already existed)

| | |
|---|---|
| Name | `CN=ArgoCD Local CA`, self-signed root |
| Valid | 26 Nov 2026 to 23 Nov 2036 |
| SHA-256 fingerprint | `F4:DE:1F:F4:AC:A1:98:45:1C:9C:0D:2B:E9:99:E8:2D:9F:11:40:F7:86:FF:37:E4:36:7E:64:AC:E1:D9:EC:9E` |
| Certificate | `~/argocd-tls/ca.crt`; in the cluster as Secret `argocd/argocd-local-ca` (certificate only) |
| Private key | `~/argocd-tls/ca.key`, **only on the workstation**, never in the cluster or in Git |

The same CA signs the Argo CD certificates (`argocd-server`, `argocd-repo-server`,
`argocd-dex-server`), so one trusted root covers everything.

#### The server certificate (issued by `scripts/issue-tls-cert.sh`)

The script does the following, in order:

1. **Renders the chart** (`helm template`, with the same `-f` values files as the deployment)
   and reads the Service name, the Secret name and nginx's `server_name` list from it. The
   certificate's names are taken from the chart itself, so they always match what nginx answers to.
2. **Creates a key and a signing request:** an ECDSA P-256 key and a CSR with `CN=<fullname>`.
3. **Signs it with the CA** (`~/argocd-tls/ca.key`) with these extensions:
   - `basicConstraints = CA:FALSE`: the certificate cannot sign other certificates
   - `keyUsage = digitalSignature`, `extendedKeyUsage = serverAuth`: TLS server use only
   - `subjectAltName` = every host plus all four in-cluster Service names
   - validity 825 days, the same as the Argo CD certificates
4. **Verifies the chain** with `openssl verify -x509_strict`.
5. **Keeps a local copy** at `~/argocd-tls/<namespace>/<fullname>.{crt,key}`, with the key at mode `600`.
6. **Creates the namespace** and labels it with Pod Security `restricted` (enforce, warn and audit).
7. **Creates or updates the Secret** `<fullname>-tls` (type `kubernetes.io/tls`) with `tls.crt`,
   `tls.key` and `ca.crt`.

```bash
scripts/issue-tls-cert.sh <namespace> [-f values-file]...
```

Local copies made before the script was changed to per-namespace folders are at
`~/argocd-tls/lia-temp-page.{crt,key}`.

#### What is in Git and what is not

| Item | Where | In Git? |
|---|---|---|
| CA public certificate | `charts/web-application/files/ca.crt` → ConfigMap `<fullname>-ca` | **Yes**: it's public, and changes to it go through review |
| CA private key | `~/argocd-tls/ca.key` | **No** |
| Server certificate + private key | Secret `<fullname>-tls` in the namespace, plus the local copy | **No** |

Publishing a custom CA's certificate in a ConfigMap is the documented Kubernetes practice
([Manage TLS Certificates in a Cluster](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/):
"distribute its CA certificate using a ConfigMap that your pods have access to read").
cert-manager's [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) uses a
ConfigMap as its default target, and Argo CD keeps trusted certificates in
`argocd-tls-certs-cm`.

#### Rotating the server certificate

```bash
scripts/issue-tls-cert.sh <namespace> -f <the same values files>
```

Then change `tls.rotation` (e.g. to `"2"`) in the namespace's values file and push, so the pod
restarts and loads the new certificate.

### The ingress route

The cluster runs **Traefik** (namespace `traefik`, IngressClass `traefik`). Argo CD is exposed
through an `IngressRouteTCP` with `tls.passthrough: true` on the `websecure` (HTTPS)
entrypoint, and this chart uses the same pattern:

```yaml
kind: IngressRouteTCP
spec:
  entryPoints: [websecure]
  routes:
    - match: HostSNI(`lia-temp-page.localhost`)   # generated from values `hosts`
      services:
        - name: lia-temp-page
          port: 443
  tls:
    passthrough: true
```

- **Passthrough:** Traefik reads only the SNI hostname from the TLS handshake and forwards the
  encrypted stream untouched. The browser therefore sees nginx's own certificate, and the private
  key never leaves the app's namespace.
- **Why not a standard Ingress:** a standard Ingress cannot do passthrough. A route in the
  `argocd` namespace can't be reused either, because Traefik routes only to Services in the
  route's own namespace (cross-namespace routing is off).
- **nginx on port 443:** port 443 is normally reserved for root. The pod-level sysctl
  `net.ipv4.ip_unprivileged_port_start=0` allows the non-root `nginx` user to bind it inside the
  pod's own network namespace, with no capabilities added. The `restricted` Pod Security level
  allows this sysctl.

### Security hardening

| Layer | Measure |
|---|---|
| Namespace | Pod Security `restricted` enforced |
| Pod | Non-root UID 101, seccomp `RuntimeDefault`, no ServiceAccount token, no service-link env vars |
| Container | Read-only root filesystem, all capabilities dropped, no privilege escalation, CPU and memory limits |
| Files | Page, config and TLS mounted read-only; key file mode `0440` |
| Network | Only Traefik can connect in; nginx can only reply (no DNS, API or internet) |
| TLS | Passthrough, CA-signed certificate, TLS 1.2/1.3, AEAD ciphers, HSTS |
| HTTP | Strict CSP (no inline styles or scripts), anti-framing, `nosniff`, no referrer, `GET`/`HEAD` only, unknown hosts get `421`, version hidden |
| Page | Title and names HTML-escaped |

### Problems found along the way

| Symptom | Cause | Fix |
|---|---|---|
| Traefik → pod connections timed out | kindnet also filters **reply** packets, so `egress: []` blocked nginx's replies (the `argocd` namespace has `allow-…-replies` policies for the same reason) | Egress allowed back to the same peers that are allowed in |
| `helm test` pod couldn't resolve DNS | It carried the app's selector labels, so the app's NetworkPolicy locked it down | The test pod has its own labels |
| nginx crashed in a namespace with a longer name: `could not build server_names_hash` | `lia-temp-page.<namespace>.svc.cluster.local` exceeded nginx's 64-byte hash bucket | `server_names_hash_bucket_size 128;` |
| Regular nginx image failed on a read-only filesystem | It writes its PID file to `/run` and temp files to `/var/cache/nginx` | `emptyDir` volumes for exactly those two paths |
| Probes failed after the unknown-host `421` rule | The kubelet connects by pod IP, so the Host header doesn't match | Probes hit `/healthz` on the catch-all server |
| `argocd` CLI: `x509: certificate signed by unknown authority` | The CLI uses the system trust store, which didn't include the CA (browsers use their own stores) | Trust the CA system-wide, or pass `--server-crt` (see Part 2, step 1) |
| VS Code's built-in browser warned about the certificate | It is Chromium (Electron), which reads `~/.pki/nssdb`; that database didn't exist | CA added with `certutil … -t "C,,"` |
| `verify-app.sh` in-cluster client checks failed now and then, although every request succeeded | `kubectl run --rm -i` attaches after the container starts, so the output of a short-lived pod could be lost | The script runs the test pod to completion and then reads its log |

### Testing

```bash
scripts/verify-app.sh [namespace]
```

It runs 55 checks in six groups: resources, certificates, HTTPS through Traefik (per host), HTTP
security behaviour, pod hardening, and the NetworkPolicy with in-cluster TLS verification. It reads
the hostnames and expected page content from the cluster, so it works the same for instances
deployed by Helm or by Argo CD. It exits non-zero if any check fails.

### The Argo CD chart

`argocd/` installs Argo CD into the `argocd` namespace (Helm release `argocd`). It wraps the
official `argo-cd` chart (version 10.20.0, Argo CD v3.6.3) and adds local templates:

| File | Purpose |
|---|---|
| `Chart.yaml` / `Chart.lock` | Depends on `argo-cd` 10.20.0 from `https://argoproj.github.io/argo-helm` |
| `values.yaml` → `argo-cd:` | Values for the official chart: domain `argocd.localhost`, NetworkPolicies on, strict TLS between components, metrics, the dex and redis images. Built-in certificate Secrets are disabled because the TLS Secrets come from `~/argocd-tls` |
| `values.yaml` → `local:` | Values for the local templates below |
| `templates/ingressroutetcp.yaml` | `IngressRouteTCP` for `argocd.localhost` on `websecure` with TLS passthrough to `argocd-server` (the pattern this repo's app chart copies) |
| `templates/allow-dns-replies.yaml` | Lets CoreDNS replies into the Argo CD pods (kindnet filters reply packets) |
| `templates/reply-traffic-policies.yaml` | Lets replies back into pods whose ingress is restricted, between Argo CD components and from outside the pod network |

The Argo CD TLS certificates (`argocd-server`, `argocd-repo-server`, `argocd-dex-server`) are
signed by the same ArgoCD Local CA and created as Secrets outside the chart, so the chart holds no
keys.

Deploy or upgrade it with:

```bash
helm dependency build argocd     # downloads argo-cd-10.20.0.tgz from Chart.lock (not kept in Git)
helm upgrade --install argocd argocd -n argocd
```

### Deploying the charts with Helm

Without Argo CD (for example, for a quick test), both charts deploy with plain Helm from the repo
root:

```bash
# Argo CD
helm dependency build argocd
helm upgrade --install argocd argocd -n argocd

# the application (the TLS Secret must exist, see "Certificates")
scripts/issue-tls-cert.sh lia-temp-page
helm upgrade --install lia-temp-page charts/web-application -n lia-temp-page
scripts/verify-app.sh lia-temp-page
```

A namespace should be managed either by Helm or by Argo CD, never by both. See
[Moving an existing Helm-installed namespace to Argo CD](#moving-an-existing-helm-installed-namespace-to-argo-cd).

---

## Part 2: deploy a new namespace with Argo CD

The example deploys a second instance into **`lia-temp-page-2`** at
**`https://lia-temp-page-2.localhost`**. Replace those two names with your own.

What stays the same and what changes:

| | |
|---|---|
| Same | Everything in the chart: image, security, page, nginx config, NetworkPolicy, CA, resource names (`lia-temp-page`) |
| **Must differ** | **The hostname.** Two routes for the same host would clash in Traefik |
| **Must be new** | **The certificate.** Its names include the namespace, and a Secret is only usable in its own namespace |

### Step 1: one-time workstation setup (skip if already done)

1. **Make the `argocd` CLI trust the CA** (it uses the system trust store):
   ```bash
   sudo trust anchor --store ~/argocd-tls/ca.crt
   ```
   Without sudo, you can instead add `--server-crt ~/argocd-tls/ca.crt` to every `argocd`
   command, or set it once in `~/.bashrc`:
   ```bash
   export ARGOCD_OPTS="--server-crt $HOME/argocd-tls/ca.crt"
   ```
   Never use `--insecure`: it disables certificate checks, so your login and the deploy key could
   be sent to a fake server.

2. **Log in:**
   ```bash
   argocd login argocd.localhost --grpc-web
   ```

3. **Give Argo CD read-only access to the private repo** with a deploy key:
   ```bash
   ssh-keygen -t ed25519 -N "" -C argocd-argocd-task -f ~/argocd-tls/argocd-task-deploy
   ```
   Add `~/argocd-tls/argocd-task-deploy.pub` in GitHub (repo → Settings → Deploy keys), with
   **"Allow write access" unticked**. Then register it and check the connection:
   ```bash
   argocd repo add git@github.com:liaalfandary-idf/argocd-task.git \
     --ssh-private-key-path ~/argocd-tls/argocd-task-deploy
   argocd repo list        # STATUS must be "Successful"
   ```
   The private key file stays in `~/argocd-tls` and never goes into Git.

### Step 2: create the namespace's values file

`charts/web-application/values-lia-temp-page-2.yaml`: only what differs from `values.yaml`:

```yaml
hosts:
  - lia-temp-page-2.localhost
```

You can also override page content here (`page.title`, `subjects`, `colors`).

### Step 3: create the Argo CD Application manifest

`argocd/applications/lia-temp-page-2.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: lia-temp-page-2
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # deleting the app deletes its resources
spec:
  project: default
  source:
    repoURL: git@github.com:liaalfandary-idf/argocd-task.git
    targetRevision: main
    path: charts/web-application
    helm:
      releaseName: lia-temp-page
      valueFiles:              # relative to `path`; later files override earlier ones
        - values.yaml
        - values-lia-temp-page-2.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: lia-temp-page-2
  syncPolicy:
    automated:
      prune: true              # delete resources removed from Git
      selfHeal: true           # undo manual changes in the cluster
    syncOptions:
      - CreateNamespace=true
    managedNamespaceMetadata:  # keeps the Pod Security labels managed from Git
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/warn: restricted
        pod-security.kubernetes.io/audit: restricted
```

### Step 4: commit and push to the branch Argo CD tracks

```bash
git add charts/web-application/values-lia-temp-page-2.yaml argocd/applications/lia-temp-page-2.yaml
git commit -m "Add lia-temp-page-2 instance"
git push origin main
```

Argo CD reads the chart and values files from `targetRevision` (`main`), so they must be pushed
there before you sync.

### Step 5: issue the certificate and create the namespace and TLS Secret

Pass the **same values file** the Application uses, so the certificate covers the new hostname:

```bash
scripts/issue-tls-cert.sh lia-temp-page-2 -f charts/web-application/values-lia-temp-page-2.yaml
```

Expected output ends with:

```
X509v3 Subject Alternative Name:
    DNS:lia-temp-page-2.localhost, DNS:lia-temp-page, DNS:lia-temp-page.lia-temp-page-2, DNS:lia-temp-page.lia-temp-page-2.svc, DNS:lia-temp-page.lia-temp-page-2.svc.cluster.local
Secret lia-temp-page-2/lia-temp-page-tls is ready.
```

This step comes before the sync, so the pod finds its Secret straight away. If you sync first, the
pod waits in `ContainerCreating` and starts on its own once the Secret exists.

### Step 6: create the Application

```bash
kubectl apply -f argocd/applications/lia-temp-page-2.yaml
```

This is the only manual `kubectl` step. From now on, Argo CD deploys whatever is in Git.

### Step 7: watch it sync

```bash
argocd app get lia-temp-page-2
argocd app wait lia-temp-page-2 --health --sync --timeout 300
```

You can also watch at https://argocd.localhost. Expect **Synced** and **Healthy**.

### Step 8: verify

```bash
scripts/verify-app.sh lia-temp-page-2
```

Expect `Result: 55 passed, 0 failed`. Then open https://lia-temp-page-2.localhost. Every
`*.localhost` name already resolves to your machine, and your browsers already trust the CA, so no
DNS or certificate setup is needed.

### Moving an existing Helm-installed namespace to Argo CD

For a namespace that was deployed with `helm install` (like `lia-temp-page`), do steps 3–4 and
6–8 with that namespace's values, and **first** remove the Helm release so that only Argo CD
manages the resources:

```bash
helm uninstall lia-temp-page -n lia-temp-page
```

This keeps the namespace and the TLS Secret, because Helm didn't create them. The page is down for
a few seconds until Argo CD syncs. Skip step 5 if the certificate already covers the namespace's
hostnames.

### Day-to-day operation

| Task | How |
|---|---|
| Change the page or settings | Edit the values file, commit, push. Argo CD syncs within about 2 minutes. Don't use `helm upgrade` any more: `selfHeal` reverts it |
| Add a hostname | Add it to the namespace's values file, re-run step 5, set a new `tls.rotation`, push |
| Rotate the certificate | Re-run step 5, set a new `tls.rotation`, push |
| Check health | `scripts/verify-app.sh <namespace>` |
| Remove an instance | `kubectl delete application <name> -n argocd` deletes its resources (finalizer). Then delete the namespace if you no longer need the Secret |

Notes:

- Argo CD doesn't run Helm test hooks; `scripts/verify-app.sh` covers the same checks and more.
- If a sync fails with a repository or connection error, check `argocd repo list` and that the
  `argocd` namespace's NetworkPolicies allow `argocd-repo-server` to reach GitHub.
