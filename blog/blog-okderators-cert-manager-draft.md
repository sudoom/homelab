# cert-manager 1.21 for okderators, built and tested on OKD 5.0

Since the 5.0 hop on 2026-11-10 the cluster runs Kubernetes 1.36. cert-manager 1.20 supports Kube 1.32–1.35, so it runs out of its support matrix. 1.21 (Kube 1.33–1.36) is not in the okderators catalog yet. The plan is the same one used for logging, GitOps, NMState, OADP and the descheduler:

1. Update the okd-operator-pipeline branch (`cert-manager-1.21`, pushed to the fork 2026-11-20 at `ad7ae85`).
2. Build in a one-off Job on this cluster and push a test catalog to zot under `okd-test/`.
3. Switch the Subscription to that catalog and upgrade in place, then soak for 24 h.
4. File draft PRs upstream.

The gate for all of it was the first ACME renewal on 1.20 on 5.0. It succeeded on 2026-11-20 (`homelab-wildcard` revision 4, CertificateRequest `homelab-wildcard-4` Issued at 10:29:04Z).

## 2026-11-20 — 1.21: baseline

Read-only reads, plan Task 1, taken on 5.0.0-okd-scos.8 at about 18:45Z, with the readonly kubeconfig (`ocr`). Later checks compare against this.

**Cluster and operator**

- ClusterVersion is 5.0.0-okd-scos.8: `Available=True Failing=False Progressing=False`.
  - `Upgradeable=False` is expected: the zot test builds cap 5.1.
  - MCP master reads `3/3/0`.
- Subscription: `AtLatestKnown cert-manager-operator.v1.20.0-2026-10-22-132146 okderators Manual`.
- CertManager `cluster` overrideArgs: `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53` and `--dns01-recursive-nameservers-only`.
  - Each operand Deployment reads `Available=True Progressing=False Degraded=False`, and each static-resources condition reads `Degraded=False`. That includes `cert-manager-networkpolicy-static-resources`.
- The three operand Deployments (controller, cainjector, webhook) all run `quay.io/okderators/cert-manager/cert-manager@sha256:563276319589fe9dc967a89b47587c0825012b6e340b74fb0a1ae7a1b3ecd97f`.
  - The controller args include both DNS-01 flags, `--acme-http01-solver-image=…/acme-solver@sha256:9c9a7b8d5feb…`, `--feature-gates=ACMEHTTP01IngressPathTypeExact=false` and `--max-concurrent-challenges=60`.
  - All three pods are on node6 with 0 restarts. They were rescheduled at 15:50:45Z during the scos.8 update.

**Certificates**

| Certificate | rev | notBefore | notAfter | renewal |
|---|---|---|---|---|
| cert-manager/homelab-wildcard | 4 | 2026-11-20T09:33:08Z | 2027-02-18T09:33:07Z | 2027-01-19T09:33:07Z |
| cnpg-system/barman-cloud-client | 2 | 2026-09-10T15:10:31Z | 2026-12-09T15:10:31Z | 2026-11-24T15:10:31Z |
| cnpg-system/barman-cloud-server | 2 | 2026-09-10T15:10:32Z | 2026-12-09T15:10:32Z | 2026-11-24T15:10:32Z |
| openshift-config/api-cert | 4 | 2026-10-06T12:29:33Z | 2027-01-04T12:29:32Z | 2026-12-05T12:29:32Z |
| openshift-ingress/okd-wildcard | 4 | 2026-10-06T12:33:15Z | 2027-01-04T12:33:14Z | 2026-12-05T12:33:14Z |

- All five are `Ready=True`. The renewal gate is met: `homelab-wildcard-4`, rev 4, was created 2026-11-20T10:29:04Z and reads `Approved=True Ready=True`. ClusterIssuer `letsencrypt-prod` reads `Ready=True ACMEAccountRegistered`.
- **The two CNPG barman certificates renew on 2026-11-24 around 15:10Z.** They are not ACME, but the plan rules out a switch on a day a Certificate is due to renew, so the switch (Task 8) avoids that day.
- **The first production ACME renewals on 1.21 will be `api-cert` and `okd-wildcard` on 2026-12-05.**

**CRDs and CA injection**

- The 10 CRDs, with their stored versions:
  - on `v1`: `certificaterequests`, `certificates`, `clusterissuers`, `issuers` (`cert-manager.io`), and `challenges`, `orders` (`acme.cert-manager.io`);
  - on `v1alpha1`: `bundles.trust.cert-manager.io`, and `certmanagers`, `istiocsrs`, `trustmanagers` (`operator.openshift.io`).
- cainjector injects into `ValidatingWebhookConfiguration/cert-manager-webhook`, `MutatingWebhookConfiguration/cert-manager-webhook` and the six `cert-manager.io`/`acme.cert-manager.io` CRDs. No APIService.

**What a 1.21 operator could touch**

- 52 MachineConfigs, with the list saved in the ledger directory (`mc-before.txt`).
- APIServer `tlsSecurityProfile` is empty, so the Intermediate default applies.
- The operator Deployment is `cert-manager-operator-controller-manager`, with `UNSUPPORTED_ADDON_FEATURES=` empty and no feature-gate args.
- No NetworkPolicy in `cert-manager` or `cert-manager-operator`.
- The operator's own record of its controllers: `"enabled controllers" istioCSR=true trustManager=false` (15:50:51Z).

**Alerts**

I read Alertmanager at about 18:55Z, through `oc exec` into `alertmanager-main-0`, which the operator ran. Nothing firing is cert-manager-related. What is firing:

- three `PodDisruptionBudgetAtLimit`, on the structural CNPG primary PDBs;
- `KubeCPUOvercommit`;
- `etcdDatabaseHighFragmentationRatio`, left firing on purpose while defrag is off;
- `ClusterNotUpgradeable`;
- `CephHealthWarning`, the standing one;
- `InsightsRecommendationActive`;
- `Watchdog`;
- four `CephNodeDiskspaceWarning` since 15:50:44Z.

`CephNodeDiskspaceWarning` is Rook's `predict_linear` rule, and here it follows the scos.8 image pulls. The disks themselves have plenty of room (kubelet stats summary): node4 318 GiB free of 371, node5 213, node6 204.

**Logs**

The controller logged 6 error lines in 24 h, all explained:

- **3 at start-up** (15:51:20Z): `ACME client for issuer not initialised/available`, right after the pod was rescheduled during the update.
- **3 from the staging run:**
  - two `propagation check failed … not yet propagated` (18:26:17Z), the normal DNS-01 wait;
  - one Order `failed to update status` (18:27:33Z), at the moment the Order went valid.

**Build prerequisites**

- zot is on node6 with **12.8 GiB free**. That is still low after the scos.8 payload; the GC on 2026-11-21 should return about 11 GB.
- `okd-build` has no PVC and no Job. SA `builder` and RoleBinding `builder-scc-privileged` are present.
- 1.20 image sizes (compressed layers, `quay.io/okderators/cert-manager/*:1.20.0-2026-10-22-132146`):
  - operator: 93.3 MB
  - cert-manager: 135.3 MB
  - acme-solver: 135.3 MB
  - istio-csr: 104.4 MB
  - operator-bundle: 0.14 MB
- **Estimate: 469 MB + 50 MB for the catalog = 0.5 GiB.** The zot gate (free ≥ 8, free − estimate ≥ 5) passes now, at 12.8 − 0.5 = 12.3.

## 2026-11-20 — staging DNS-01 issuance on 1.20 (the before)

The kit is in `tests/cert-manager-1.21/` (commit `94f34f1`). It is not managed by ArgoCD: I apply it and delete it by hand.

- **ClusterIssuer `letsencrypt-staging-test`:** points at the Let's Encrypt staging directory. Its DNS-01 solver is production's, with the chart values filled in: Cloudflare, `apiTokenSecretRef` `cloudflare-api-token` / `api-token`.
- **Certificate `cm-dns01-test`:** covers `cm-dns01-test.homelab.sudops.pl`, in namespace `cert-manager`, with `rotationPolicy: Always`.

The point is to have a 1.20 issuance through the production solver path to compare against, without touching a production Certificate. The same kit runs again after the switch to 1.21 (plan Task 9 Step 4).

It ran on 5.0.0-okd-scos.8, about 2.5 h after the scos.6 → scos.8 update finished (16:01Z). cert-manager was v1.20.4, with the operator CSV `cert-manager-operator.v1.20.0-2026-10-22-132146`.

```
oc apply -f tests/cert-manager-1.21/staging-issuer.yaml     # clusterissuer.cert-manager.io/letsencrypt-staging-test created
oc apply -f tests/cert-manager-1.21/test-certificate.yaml   # certificate.cert-manager.io/cm-dns01-test created
```

The ClusterIssuer read `Ready=True ACMEAccountRegistered` straight away. Its live `spec.acme.solvers` was byte-identical to `letsencrypt-prod`'s:

```
{"n":"letsencrypt-staging-test","c":["Ready=True ACMEAccountRegistered"],"s":[{"dns01":{"cloudflare":{"apiTokenSecretRef":{"key":"api-token","name":"cloudflare-api-token"}}}}]}
{"n":"letsencrypt-prod","c":["Ready=True ACMEAccountRegistered"],"s":[{"dns01":{"cloudflare":{"apiTokenSecretRef":{"key":"api-token","name":"cloudflare-api-token"}}}}]}
```

Timeline (read every 15 s with the readonly kubeconfig):

| Time (Z) | State |
|---|---|
| 18:26:10 | Certificate created |
| 18:26:12 | CertificateRequest `cm-dns01-test-1` created, `Approved=True` |
| 18:26:17 – 18:27:19 | Order `cm-dns01-test-1-866038528` `pending`; Challenge `dns-01` for `cm-dns01-test.homelab.sudops.pl` `pending` / `Waiting` |
| 18:27:33 | CertificateRequest `Ready=True`; Order `valid`; Challenge cleaned up |
| 18:27:34 | Certificate `Ready=True`, revision 1 |

**Apply to Ready: 83 s.**

The staging certificate reads `notBefore=2026-11-20T17:28:59Z` and `notAfter=2027-01-23T17:28:58Z`.

- `notBefore` is backdated an hour, as in production.
- The lifetime is about 64 days, not production's 90. I have not checked why staging issues shorter certificates. The plan does not assume a lifetime; this records it.

Nothing failed, so the 1.20 side of the comparison is clean. Clean-up (plan Task 2 Step 3) removes the Certificate first, then the ClusterIssuer, then both Secrets. The order matters: deleting the ClusterIssuer before its account Secret keeps the controller from recreating that Secret. The 1.21 run will then register its own ACME account. I never read the Secret values.

Clean-up ran at about 18:35Z, in the order above. Afterwards all four objects read `NotFound`:

- Secrets `cm-dns01-test-tls` and `letsencrypt-staging-test-account`, read as metadata only;
- ClusterIssuer `letsencrypt-staging-test`;
- the Certificate.

No `cm-dns01-test` CertificateRequest, Order or Challenge was left. The five production Certificates all stayed `Ready=True`.
