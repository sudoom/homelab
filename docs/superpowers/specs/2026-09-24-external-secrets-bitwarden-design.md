# External Secrets Operator + Bitwarden Secrets Manager — replace sealed-secrets

Status: design, awaiting review (2026-09-24). Nothing here is applied yet.

## Why

Sealed-secrets has cost more upkeep than it saves:

- The sealing cert expired on 2026-05-28 with rotation disabled, blocking all sealing until 06-27.
- The 2.19/2.20 chart bumps are blocked: the chart hardcodes `runAsUser: 1001` / `fsGroup`, which
  OpenShift `restricted-v2` rejects. Renovate PRs #141 and #153 also changed `Chart.lock` without
  re-vendoring `charts/*.tgz`.
- Four sealing keys exist (monthly rotation since 06-27); old blobs were never re-sealed.
- A cluster rebuild needs the sealing private keys, and the repo documents no backup of them.

Goal: credentials live in Bitwarden Secrets Manager (EU cloud), git holds only references, and a
rebuild needs exactly one hand-created Secret.

## Decisions (agreed 2026-09-24)

| Decision | Choice | Note |
|---|---|---|
| Store | Bitwarden Secrets Manager, EU cloud | Free tier: 2 users, 3 projects, 3 machine accounts, unlimited secrets. End-to-end encrypted. |
| Operator source | OLM, `okderators` catalog | Chosen over the upstream Helm chart (2.11.0) to keep the repo's operator pattern. Accepted cost: see Risks. |
| Scope | The 12 SealedSecrets on the cluster | Ansible Vault (`ansible/truenas`, `ansible/technitium`) stays as is. |

## What the catalog ships (verified 2026-09-24)

- Package `external-secrets-operator`, catalog `okderators`, channel `alpha` (default, only),
  CSV `external-secrets-operator.v1.0.0-2025-10-05-155251`, install mode `AllNamespaces`,
  suggested namespace `external-secrets-operator`, `minKubeVersion 1.32.0`.
- Images (all present on quay.io as tags `*-2025-10-05-155251`): operator 1.0.0,
  `external-secrets` operand **0.19.0**, `bitwarden-sdk-server` **0.5.1**. Upstream ESO is 2.11.0.
- Build tags are `strictfipsruntime,openssl` only; the Bitwarden provider is compiled in.
- Operator config CR is the **pre-rename** API: kind `ExternalSecrets`, group
  `operator.openshift.io/v1alpha1`, singleton named `cluster`. Relevant fields:
  - `spec.externalSecretsConfig.bitwardenSecretManagerProvider.enabled: "true"` and
    `.secretRef.name` — a TLS Secret with `tls.crt`, `tls.key`, `ca.crt`.
  - `spec.externalSecretsConfig.certManagerConfig` — **not used** (immutable once set, and it would
    also move the webhook onto cert-manager).
  - `spec.controllerConfig.namespace` — operand namespace, default `external-secrets`, immutable.
  - No `networkPolicies` field (added upstream 2025-10-18), so no deny-all policies to open up.
- Operand API `external-secrets.io/v1`. Bitwarden store fields: `apiURL`, `identityURL`,
  `bitwardenServerSDKURL`, `caBundle` or `caProvider`, `organizationID`, `projectID`,
  `auth.secretRef.credentials`. `remoteRef.key` is a secret UUID or a secret **name**; names must be
  unique within the project. One store = one org/project.

## Architecture

```
Bitwarden SM (EU)  <--https--  bitwarden-sdk-server  <--TLS (own CA)--  ESO controller
  project "okd"                 ns external-secrets                     ns external-secrets
                                                                          |
                                                ClusterSecretStore "bitwarden" (12 namespaces)
                                                                          |
                                     ExternalSecret per consumer -> ordinary Kubernetes Secret
```

### Components

1. **`components/operators/external-secrets/`** — root-app wave 1.
   `Namespace external-secrets-operator`, `OperatorGroup` with `spec: {}`, `Subscription`
   (`okderators`, channel `alpha`, `startingCSV` pinned to the CSV above,
   `installPlanApproval: Manual` like the other five okderators subscriptions). The first
   InstallPlan needs one user-run approval.
2. **`components/cluster-config/external-secrets-config/`** — root-app wave 2, destination
   namespace `external-secrets`. Intra-chart waves:
   - wave 1: self-signed `Issuer` -> CA `Certificate` (10y) -> CA `Issuer`, then a `Certificate`
     for the SDK server (`bitwarden-sdk-server.external-secrets.svc` and `.svc.cluster.local`;
     the Service name is confirmed after install) into Secret `bitwarden-sdk-server-tls`.
     cert-manager's CA issuer writes `ca.crt` alongside the pair.
   - wave 2: `ExternalSecrets/cluster` with the Bitwarden provider enabled and `secretRef` pointing
     at `bitwarden-sdk-server-tls`.
   - wave 3: `ClusterSecretStore bitwarden` — EU URLs `https://api.bitwarden.eu` and
     `https://identity.bitwarden.eu`, `caProvider` reading `ca.crt` from the TLS Secret, the org
     and project UUIDs, `auth.secretRef.credentials` -> Secret `bitwarden-access-token` key `token`
     in `external-secrets`, and `conditions[].namespaces` listing exactly the 12 consumer
     namespaces.
3. **Consumer charts** — each SealedSecret template is replaced by an `ExternalSecret` producing a
   Secret with the **same name, type and keys**, `refreshInterval: 1h`,
   `target.creationPolicy: Owner`. No consumer changes.

### Bitwarden layout

- One free organisation, Secrets Manager enabled, one project `okd`.
- Machine account `okd-eso`: **read** on project `okd`. Its access token is the only secret-zero.
- One Bitwarden secret per key, named `<namespace>/<secret>/<key>`. 19 in total:

| Kubernetes Secret | Keys |
|---|---|
| `mikrotik-exporter/mktxp-config` | `mktxp.conf` (whole file) |
| `grafana/grafana-credentials` | `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` |
| `synology-cert-sync/dsm-credentials` | `username`, `password` |
| `media/vpn-creds` | `OPENVPN_USERNAME`, `OPENVPN_PASSWORD` |
| `keepers/vpn-creds` | `OPENVPN_USERNAME`, `OPENVPN_PASSWORD` |
| `openshift-logging/loki-garage-credentials` | `access_key_id`, `access_key_secret` |
| `openshift-adp/garage-credentials` | `cloud` (whole AWS credentials file) |
| `media/media-postgres-r2-creds` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
| `immich/immich-postgres-r2-creds` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
| `openshift-monitoring/alertmanager-mailjet` | `password` |
| `openshift-config/github-oauth-client-secret` | `clientSecret` |
| `cert-manager/cloudflare-api-token` | `api-token` |

Whole-file values are ported 1:1. Templating them from smaller pieces is a later improvement.

### Secret-zero and bootstrap

- The user creates `external-secrets/bitwarden-access-token` once:
  `oc -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token>`
  in a normal terminal. Never in git, never in chat. A copy lives in the user's Bitwarden vault.
- Fresh rebuild: phase0 -> root-app syncs -> approve the ESO InstallPlan -> create the token Secret
  -> every ExternalSecret resolves. This replaces restoring sealing keys. `bootstrap/phase0/readme.md`
  gains this step.
- No circular dependency: the SDK server's TLS comes from the self-signed CA, not ACME, so ESO
  starts without the Cloudflare token that cert-manager's ClusterIssuer needs.

## Migration

### Seeding

User-run, one of:
- Web UI (19 entries).
- A script using `bws` (`--server-url https://vault.bitwarden.eu`) with a **temporary read-write**
  machine account `okd-seed`: for each row, read the live key with
  `oc get secret -n <ns> <name> -o jsonpath='{.data.<key>}' | base64 -d` and create
  `<ns>/<name>/<key>` from it without echoing the value. Delete `okd-seed` afterwards.

### Cutover, one Secret per commit

Each commit removes the SealedSecret template and adds the ExternalSecret in the same chart.
ESO cannot take over a Secret whose controller owner is the SealedSecret, so the ExternalSecret
errors until ArgoCD prunes the SealedSecret and the garbage collector deletes the old Secret; ESO's
next retry creates the new one. Expected gap: seconds to a minute. Running pods keep their values;
only a pod starting inside the gap misses the Secret. If ESO's backoff stretches the gap, the
`force-sync` annotation on the ExternalSecret triggers an immediate reconcile (user-run).

Order (lowest stakes first; the first one proves the mechanics and measures the gap):

1. `mikrotik-exporter/mktxp-config`
2. `grafana/grafana-credentials`, `synology-cert-sync/dsm-credentials`
3. `media/vpn-creds`, `keepers/vpn-creds`
4. `openshift-logging/loki-garage-credentials`, `openshift-adp/garage-credentials`
5. `media/media-postgres-r2-creds`, `immich/immich-postgres-r2-creds` (check `ContinuousArchiving`
   stays True on both clusters)
6. `openshift-monitoring/alertmanager-mailjet`, `openshift-config/github-oauth-client-secret`
7. `cert-manager/cloudflare-api-token` (last; `homelab-wildcard` renewed 2026-09-21, next 11-20)

### Optional rotation

The old SealedSecret blobs stay in public git history and decrypt with keys that still exist.
Cutover is the cheap moment to rotate: the new value goes straight into Bitwarden. Candidates:
Cloudflare token, both R2 key pairs, both garage keys (via `ansible/truenas`), Mailjet. Decided per
secret during the cutover.

## Verification

Per cutover:
- `oc -n <ns> get externalsecret <name>` -> `Ready=True`, `SecretSynced`.
- The Secret has the same keys (`oc get secret -o jsonpath='{.data}' | jq 'keys'`; never values).
- The consumer is healthy: its pod Ready, plus the specific signal (archiving for R2, a Loki push
  for garage, a Velero BSL `Available` for OADP, an OAuth login for GitHub, a test alert or the
  next critical for Mailjet, a `CertificateRequest` dry run or the 11-20 renewal for Cloudflare).

Platform, once:
- CSV `Succeeded`, `ExternalSecrets/cluster` Ready, `bitwarden-sdk-server` pod Running with the
  mounted certificate, `ClusterSecretStore bitwarden` `Ready=True` (proves token, EU URLs and TLS).
- Chart changes pass the repo's Validation workflow (`helm lint` -> `helm template` ->
  `kubeconform` -> `oc diff`).

## Rollback

- Per secret: revert that commit. ArgoCD recreates the SealedSecret and prunes the ExternalSecret;
  the controller re-creates the Secret once ESO's copy is gone.
- Platform: disable the two root-app entries. Sealed-secrets keeps running until decommission, so
  any not-yet-migrated Secret is unaffected throughout.

## Decommission (after the last cutover and a quiet week)

- Remove `sealed-secrets` from `bootstrap/root-app/values.yaml` and delete
  `components/operators/sealed-secrets/` including `sealed-secrets-pub.pem`.
- Keep an offline copy of the sealing private keys until every rotation above is done, then
  delete them.
- README TODO: drop the sealed-secrets bump and re-seal items. CLAUDE.md: rewrite the sealed-secrets
  paragraph and the Cloudflare-token line under TLS; add the ESO subscription to the Manual list.

## Risks

- **Stale, alpha build.** ESO 0.19.0 (2025) against upstream 2.11.0; the Bitwarden provider is
  labelled alpha upstream. It runs where it can reach two things: the kube API and Bitwarden.
- **Breaking rename on the next catalog rebuild.** Upstream renamed `ExternalSecrets` to
  `ExternalSecretsConfig` on 2025-10-06. `installPlanApproval: Manual` holds the upgrade; accepting
  it later is a supervised change that rewrites the config CR.
- **Bitwarden or egress down** (including `br-ex.forwarding` incidents): existing Secrets keep
  working; only changes stop propagating until it recovers.
- **Cutover gap** as described above; mitigated by ordering and by measuring it on `mktxp-config`.

## Documentation

- New blog draft `blog/blog-external-secrets-bitwarden-draft.md`, updated per phase.
- README TODO: one In-flight item for the migration, updated per cutover.
- `bootstrap/phase0/readme.md`: the secret-zero step.
