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

## 2026-11-20 — facts moved from CLAUDE.md and the README TODO

The repo-level `CLAUDE.md` and the README TODO list were trimmed on 2026-11-20. These are the facts about this topic that left them, quoted as whole sentences as they stood at commit 94f34f1 so the history stays with the topic.

### From CLAUDE.md

**Stack and tool versions**

- [cert-manager] **v1.20.4** (operator CSV `cert-manager-operator.v1.20.0-2026-10-22-132146`, since 2026-10-27)
- [cert-manager] The bundle came from okd-operator-pipeline #28/#29 and reached the catalog through okderators-catalog-index #60 (`release-4.21`) and #61 (`release-4.22`), both merged 2026-10-27; the operator approved the InstallPlan the same day. Before that the cluster ran 1.18 (EOL 2026-03-10, Kube 1.29–1.33) out of matrix from the 4.21 hop on, and every renewal on it succeeded.
- [cert-manager] The controller logs `version="canary"` because the build stamps no version; the operand label `app.kubernetes.io/version` reads v1.20.4

**Upstream PRs and comments**

- **Container image builds run on the cluster, not on the Mac (operator, 2026-10-20).** Any build of operator or other container images (okd-operator-pipeline `build.sh`, bundles, test catalogs) runs as a one-off Job on this cluster: the nodes are amd64 like upstream's CI runners, so the images can also be installed here, while the Mac is arm64 and emulating amd64 is far too slow (the cert-manager 1.20 build on 2026-09-08 was arm64-only and could not be installed).

## 2026-11-21 — the 1.21 build on the cluster: `RESULT PASS` in 25 minutes

Plan Task 6. The pre-run gates read at 16:35Z (readonly):

- zot had 23.36 GiB free, read just after the 16:18Z GC pass, against an estimate of 0.5 GiB;
- `okd-build` held no PVC, Job or pod, and the `builder` ServiceAccount and its privileged RoleBinding were present;
- no OKD update was running or offered, and `master` read 3/3/0.

The operator created the PVC (150Gi, `ceph-nvme-block`) and the script ConfigMap, then started the Job:

```bash
oc apply -f tests/okderators-cert-manager-build/pvc.yaml
oc apply -k tests/okderators-cert-manager-build/
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-cert-manager-build/job-template.yaml -p MODE=full \
  -p PIPELINE_REPO=https://github.com/sudoom/okd-operator-pipeline -p PIPELINE_BRANCH=cert-manager-1.21 \
  -p OPERATOR_COMMIT=157e4aa1fd03e5e34ec0e6533555c94b98d729be \
  -p CERT_MANAGER_COMMIT=925c22283de556172d48d96a165dc2fa27f7a6ff \
  -p DATE=$DATE | oc -n okd-build create -f -
```

The Job was `cert-manager-build-full-2026-11-21-163714`. Its pod ran on node5 from about 16:37Z and the Job succeeded at 17:01:48Z. `build_containers` took 1,200 s; every other step took under 2 minutes. This was the first time the Job-only bash 4 paths of `build.sh` ran: the laptop has bash 3.2 and no `opm` or `operator-sdk`. All of them worked on the first run.

### Source checks, before the build

```
CHECK gitmodules-branch PASS cert-manager/operator=cert-manager-1.21 cert-manager/cert-manager=release-1.21, the release of OCP_SHORT 1.21; cert-manager/istio-csr=main (recorded)
CHECK operator-commit PASS cert-manager/operator HEAD~1 157e4aa1fd03e5e34ec0e6533555c94b98d729be = gitlink = OPERATOR_COMMIT; HEAD 30071adf2bf2f44a1b107fff61f49c3bc7953f64 is the patch commit 'OKDify'; clean tree
CHECK cert-manager-commit PASS cert-manager/cert-manager HEAD 925c22283de556172d48d96a165dc2fa27f7a6ff = gitlink = CERT_MANAGER_COMMIT, clean tree, no patch
CHECK patch-applied PASS git am -3 patches/operator.patch exited 0; ...
CHECK feature-defaults PASS IstioCSR=true TrustManager=false HTTP01Proxy=false
```

### Pushed

| Image (`zot.apps.okd.sudops.pl/okd-test/cert-manager/…:1.21.0-2026-11-21-163714`) | Digest | Bytes |
|---|---|---|
| `operator` | `sha256:8929d637c8c6f7a72ccccda69ec0fd95b9a47f8a283e03c1c23659bd5fcaea86` | 93,587,350 |
| `cert-manager` | `sha256:cde9f9ba6df6ae82a9968eadddeee5094ad2c49a56715394ee23b0b994e78a9b` | 130,372,839 |
| `acme-solver` | `sha256:5c192cbc2c4e020b7129643ad901b3e4c616ca7c41ad4f11ac3ef6ca09b0c419` | 130,372,840 |
| `istio-csr` | `sha256:e37564b36f3b1aabfecd591a85a25fc5e67a66b0d2a55885c0142c115b0e6235` | 104,467,471 |
| `operator-bundle` | `sha256:99ccae85cab7dc6b68a88de475cb3098f0c9080ef8cdda144248cd6ea5868c68` | 167,282 |

The CSV is `cert-manager-operator.v1.21.0-2026-11-21-163714`.

### Bundle checks

```
CHECK bundle-objects PASS 17 objects as expected (13 CRDs, ClusterServiceVersion/cert-manager-operator.v1.21.0-2026-11-21-163714, ClusterRole/cert-manager-operator-metrics-reader ConfigMap/cert-manager-operator-trusted-ca-bundle Service/cert-manager-operator-controller-manager-metrics-service); manifests/ 17 files; opm render: same
CHECK csv-name PASS cert-manager-operator.v1.21.0-2026-11-21-163714 1.21.0-2026-11-21-163714; ...
CHECK skiprange PASS olm.skipRange '>=1.0.0 <1.21.0-2026-11-21-163714', no replaces, no skips
CHECK min-kube PASS minKubeVersion 1.31.0
CHECK no-max-openshift PASS no olm.maxOpenShiftVersion in the CSV, the bundle files or the opm render
CHECK version-env PASS ISTIOCSR_OPERAND_IMAGE_VERSION=1.21.0-2026-11-21-163714 OPERAND_IMAGE_VERSION=1.21.0-2026-11-21-163714 OPERATOR_IMAGE_VERSION=1.21.0-2026-11-21-163714
CHECK images-by-digest PASS 21 refs, all @sha256; zot.apps.okd.sudops.pl/okd-test/cert-manager/ refs are this run's digests (...); EXTERNAL: cert-manager-approver-policy@b516dba9e41d trust-manager@783afe31d39f
CHECK no-redhat-registry PASS ...
CHECK install-modes PASS OwnNamespace=true SingleNamespace=true MultiNamespace=false AllNamespaces=true
CHECK machineconfig-permission INFO cert-manager-operator-controller-manager: machineconfiguration.openshift.io machineconfigs verbs=create,delete,get,list,update,watch
CHECK operator-sdk-validate PASS operator-sdk v1.36.1 bundle validate: passed, 1 warnings, 0 errors
RESULT PASS full 2026-11-21-163714
```

- `operator-sdk validate` gave one warning: the HTTP01Proxy API has no entry in the CSV's example annotation. It does not affect the install.
- The operator's ClusterRole can create, update and delete MachineConfigs. That permission belongs to the alpha HTTP01Proxy feature, and the gate stays off (`feature-defaults` above).
- `no-max-openshift` passing means this bundle adds no `Upgradeable` blocker for 5.1.
- trust-manager and approver-policy stay on `quay.io/jetstack`, pinned by digest, as planned.

The build PVC peaked at about 11.6 GB used (`DISK` lines). zot read 23.52 GiB free at 17:02Z, which is not below the pre-run 23.36 although about 0.56 GB had just been pushed. The kubelet's volume stats are refreshed periodically, so this read may predate the push. The second read comes after Task 7.

## 2026-11-21 — the test catalog: `RESULT PASS` in about 3 minutes

Plan Task 7, run straight after Task 6 on the same PVC once the full-build Job was deleted:

```bash
DATE2=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-cert-manager-build/job-template.yaml -p MODE=catalog -p DATE=$DATE2 \
  -p CATALOG_BRANCHES=release-5.0 -p IMAGE_BRANCH=release-5.0 \
  -p BUNDLES='release-5.0=zot.apps.okd.sudops.pl/okd-test/cert-manager/operator-bundle:1.21.0-2026-11-21-163714@sha256:99ccae85cab7dc6b68a88de475cb3098f0c9080ef8cdda144248cd6ea5868c68' \
  | oc -n okd-build create -f -
```

The Job was `cert-manager-build-catalog-2026-11-21-170350`; it started at 17:03:50Z and succeeded by 17:06:45Z.

```
CHECK branch-data-release-5.0 PASS replaces cert-manager-operator.v1.20.0-2026-10-22-132146; installed [cert-manager-operator.v1.20.0-2026-10-22-132146]
CHECK bundle-release-5.0 PASS cert-manager-operator.v1.21.0-2026-11-21-163714: package cert-manager-operator, ... 17 objects (13 CRDs); image zot.apps.okd.sudops.pl/okd-test/cert-manager/operator-bundle@sha256:99ccae85...
CHECK edit-release-5.0 PASS appended cert-manager-operator.v1.21.0-2026-11-21-163714 replaces cert-manager-operator.v1.20.0-2026-10-22-132146 (no skipRange, no skips) after 5 entries; package file +2 -0 lines
CHECK opm-validate-release-5.0 PASS opm validate catalog
CHECK walk-release-5.0 PASS 6 entries reach cert-manager-operator.v1.21.0-2026-11-21-163714; installed: cert-manager-operator.v1.20.0-2026-10-22-132146
CHECK negative-control-replaces-opm-release-5.0 PASS opm validate rejects the copy without the replaces: ... multiple channel heads found in graph: cert-manager-operator.v1.20.0-2026-10-22-132146, cert-manager-operator.v1.21.0-2026-11-21-163714
CHECK negative-control-replaces-release-5.0 PASS without the replaces the walker fails and reports stranded: cert-manager-operator.v1.14.0-2024-08-09-204321 ... cert-manager-operator.v1.20.0-2026-10-22-132146
CHECK opm-validate-image PASS opm validate catalog
CHECK catalog-image PASS zot.apps.okd.sudops.pl/okd-test/cert-manager-catalog:2026-11-21-170350: package cert-manager-operator; head cert-manager-operator.v1.21.0-2026-11-21-163714; every entry and cert-manager-operator.v1.20.0-2026-10-22-132146 reach the head
PUSHED zot.apps.okd.sudops.pl/okd-test/cert-manager-catalog:2026-11-21-170350@sha256:d328e18ae82f66e601f23ddceaf3c84025a9f8e1818e2a90cd6ce7ec5c56d45e 32606770
RESULT PASS catalog 2026-11-21-170350
```

The two negative controls show the `replaces` line is what carries the upgrade. Without it, opm sees two heads in the `alpha` channel, and every older entry, including the installed 1.20 build, is left with no path to 1.21. The bundle's own `skipRange` does not replace that line in this file-based catalog.

The catalog diff (`/work/run/release-5.0.diff`, 173 lines) was copied off the PVC with the log-reader pod. It is a new 157-line bundle file plus two lines in the package file. It is not the upstream PR: its bundle file points at the zot digest, and the official okderators build will carry its own date. The PR will be generated from the official quay bundle with `hack/add-bundle.sh`.

End of the Job phase: the operator deleted the log-reader pod, the catalog Job and PVC `cert-manager-build-storage`; `okd-build` then held no PVC or Job, and the released PV was gone by 17:09Z. ConfigMap `cert-manager-build-scripts` stays. zot read 23.52 GiB free at 17:09Z, the same as at 17:02Z and 0.16 GiB above the 16:35Z pre-run read, although Tasks 6 and 7 pushed about 0.59 GB. Most likely the 16:35Z read was taken while the 16:18Z GC pass was still freeing space, and the pushed images share base layers already in zot. Either way the Job phase cost no measurable zot space.
