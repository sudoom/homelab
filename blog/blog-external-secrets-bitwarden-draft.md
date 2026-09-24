# Leaving sealed-secrets: External Secrets Operator + Bitwarden Secrets Manager

Working notes on replacing Bitnami sealed-secrets on the OKD 4.21 homelab cluster. The repo is public,
so today every credential sits in git as a SealedSecret blob. The plan moves the values into Bitwarden
Secrets Manager (EU cloud) and leaves only references in git, read by the External Secrets Operator.
Design spec: `docs/superpowers/specs/2026-09-24-external-secrets-bitwarden-design.md`.

## 2026-09-24 — why move, what to move to, and what the catalog actually ships

### What sealed-secrets cost

- The sealing cert expired on 2026-05-28 with `--key-renew-period=0`, and all new sealing failed until
  rotation was re-enabled on 06-27 (`blog/blog-security-hardening-draft.md`).
- Every chart bump since 2.18.6 is blocked. The 0.38.x controller chart hardcodes `runAsUser: 1001`,
  `fsGroup: 65534` and an alpha seccomp annotation, which `restricted-v2` rejects
  (`must be in the ranges: [1000810000, 1000819999]`). Renovate #141 and #153 also bumped `Chart.lock`
  without re-vendoring `charts/*.tgz`.
- Four sealing keys after three monthly rotations; the old blobs were never re-sealed.
- A cluster rebuild needs the sealing private keys. Nothing in the repo documents a backup of them.

Live inventory (key names only, from `oc get sealedsecrets -A -o json | jq '.spec.encryptedData|keys'`):
12 SealedSecrets, 19 keys, across `cert-manager`, `grafana`, `immich`, `keepers`, `media` (x2),
`mikrotik-exporter`, `openshift-adp`, `openshift-config`, `openshift-logging`, `openshift-monitoring`,
`synology-cert-sync`.

### Options looked at

- SOPS + age: same model (ciphertext in git), no controller, needs an ArgoCD repo-server decryption
  plugin.
- External Secrets Operator with a store outside git: self-hosted OpenBao on TrueNAS, or SaaS.
- Keep sealed-secrets and fix the upgrade with a securityContext override.

SaaS stores compared for 12 secrets and one machine identity (2026-09 pricing):

| Store | Free tier | Who can read values | ESO provider stability |
|---|---|---|---|
| Bitwarden Secrets Manager | 2 users, 3 projects, 3 machine accounts, unlimited secrets | only us (E2E) | alpha |
| Infisical Cloud | 5 identities, 3 projects | Infisical | alpha |
| Doppler | 3 users, 10 projects, 50 service tokens | Doppler | alpha |
| 1Password | paid plans only; 1000 ops/day on Individual/Families | only us (E2E) | alpha |
| GCP Secret Manager | 6 versions free, then $0.06/version/month (~$0.36/month here) | Google | stable |
| AWS Secrets Manager | $0.40/secret/month (~$4.80/month here) | AWS | stable |

Chosen: Bitwarden Secrets Manager, EU region. End-to-end encrypted, and the free tier covers this with
room to spare.

### What `okderators` ships — and why "it's in the catalog" was not the whole answer

`oc get packagemanifest -n openshift-marketplace` lists `external-secrets-operator` in three catalogs:
`okderators` (v1.0.0-2025-10-05-155251), `community-operators` and `operatorhubio-catalog` (both
v0.11.0, old). The okderators pipeline's `release-4.21` branch builds three submodules:
`openshift/external-secrets-operator` (`release-1.0`), `openshift/external-secrets` (`release-0.19`)
and `openshift/external-secrets-bitwarden-sdk-server` (`release-0.5.1`). The Containerfile builds with
`-tags strictfipsruntime,openssl` only, and the operand's provider registry at the gitlink includes
Bitwarden, Infisical, Doppler and 1Password, so no provider is compiled out.

The catalog image is older than the pipeline's gitlinks. The CSV's relatedImages resolve on quay.io to
tags `1.0.0-2025-10-05-155251`, `0.19.0-2025-10-05-155251` and `0.5.1-2025-10-05-155251`: ESO
**0.19.0**, against upstream **2.11.0** (released 2026-09-18). Reading the operator API at the
current `release-1.0` branch gave the wrong answer: that branch has `ExternalSecretsConfig` and a
`networkPolicies` field that defaults to deny-all. Both arrived after the build (the rename on
2025-10-06, network policies on 2025-10-18). The CSV's owned CRD list still says `ExternalSecrets`,
so the API to write against is the parent of the rename commit: kind `ExternalSecrets`, group
`operator.openshift.io/v1alpha1`, singleton `cluster`, Bitwarden enabled with
`externalSecretsConfig.bitwardenSecretManagerProvider.enabled: "true"` plus a TLS `secretRef`.

Same lesson as the nmstate gitlinks on 2026-09-09: read what was built, not what the branch says now.

### Decision

- Operator from `okderators` (the user's call, over the upstream Helm chart 2.11.0 I recommended), with
  `installPlanApproval: Manual`. The next catalog rebuild renames the config CR; Manual holds it until
  that change can be supervised.
- The SDK server's TLS comes from a self-signed CA through cert-manager, handed over as a Secret, not
  through the operator's `certManagerConfig` (immutable once set, and it moves the webhook too).
- One project `okd`, read-only machine account `okd-eso`, one Bitwarden secret per key named
  `<namespace>/<secret>/<key>`.
- One cutover per commit, `mktxp-config` first to measure the ownership-handover gap, Cloudflare token
  last.

Next: spec review, then the implementation plan.
