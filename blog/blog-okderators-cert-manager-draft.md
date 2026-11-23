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

## 2026-11-22 — the test catalog live, the pre-flight, and the switch commit

The test catalog chart went in on 2026-11-21 (`8d46183`): CatalogSource `okd-test-cert-manager` read `READY`, its packagemanifest offered `alpha cert-manager-operator.v1.21.0-2026-11-21-163714`, and the Subscription stayed `AtLatestKnown` on `okderators` 1.20, because it did not read that catalog yet.

Pre-flight on 2026-11-22 at 16:00Z, all reads with the readonly kubeconfig:

- Cluster: 3/3 nodes Ready, `5.0.0-okd-scos.8` with nothing offered, every ClusterOperator `True False False`, 55/55 apps Synced and Healthy, MCP master `3/3/0` and not updating. The only restarts since the build were the three transmission pods at 03:00Z (their daily liveness design).
- cert-manager: Subscription `AtLatestKnown cert-manager-operator.v1.20.0-2026-10-22-132146 okderators Manual`; CertManager CR conditions all `Available=True`/`Degraded=False`, both `overrideArgs` present; operand and operator pods at 0 restarts; 10 CRDs, as in the baseline; APIServer TLS profile empty; no NetworkPolicies; 0 controller errors in 24 h.
- Renewal gate: `homelab-wildcard` rev 4, `notBefore=2026-11-20T09:33:08Z`, Ready. The next renewals are the two barman certificates on 2026-11-24 ~15:10Z (so not that day) and `api-cert` + `okd-wildcard` on 2026-12-05 ~12:30Z.
- The MachineConfig list was the one check that differed: five new rendered master/worker pairs between 2026-11-21 17:24:50Z and 17:33:43Z. The only file that changed between them is `/var/lib/kubelet/config.json`, the global pull secret. The operator had replaced the OpenShift (OCP) pull credentials with a dummy pull secret, because using OCP credentials on an OKD cluster is against the OCP policy. MCO applied it without a reboot. Since then 49 pods had started with no pull errors (24 in `openshift-adp`, both catalog pods). Nothing on the cluster pulls from `registry.redhat.io` except the nightly `synology-cert-sync` Job (`openshift4/ose-cli:latest`), which succeeded at 03:14Z after the change; that image is worth replacing with an OKD or public one.

The switch commit changes `components/operators/cert-manager/values.yaml` to `source: okd-test-cert-manager`, adds an optional `startingCSV` to the Subscription (rollback only, renders nothing when unset) and adds the chart README with the rollback. Checks:

```bash
helm lint <copy of the chart without charts/>        # 0 failed; the real chart fails on the gitignored fallback tarball, unchanged chart too
helm template cert-manager-operator components/operators/cert-manager/ --show-only templates/operator.yaml | kubeconform -strict -ignore-missing-schemas -summary ...
                                                      # Valid: 3, Skipped: 1 (CertManager)
```

`oc diff` cannot run under the readonly SA (it server-side dry-runs a patch: `cannot patch resource "subscriptions"`), so I compared the rendered `spec` of each object with live using `jq -S`. The Namespace, OperatorGroup and CertManager are unchanged; the Subscription differs in `source` only (`okderators` → `okd-test-cert-manager`).

## 2026-11-22 — on 1.21: the InstallPlan, a 33-second roll, staging DNS-01 in 88 s

The switch (`7cc8e39`) was pushed at 16:09:52Z; ArgoCD synced it by 16:11:02Z. The Subscription went `UpgradePending` with `currentCSV` `cert-manager-operator.v1.21.0-2026-11-21-163714`, and OLM wrote InstallPlan `install-fnbwm` (`RequiresApproval`).

Read before approval:

```bash
ocr -n cert-manager-operator get installplan install-fnbwm -o json | jq -r '[.status.plan[]|.resource.kind+"/"+.resource.name+" "+.status]|.[]' | sort
```

22 steps: the CSV, ClusterRole `cert-manager-operator-metrics-reader`, the CSV's ClusterRole/ClusterRoleBinding and Role/RoleBinding, ServiceAccount `cert-manager-operator-controller-manager`, ConfigMap `cert-manager-operator-trusted-ca-bundle`, Service `cert-manager-operator-controller-manager-metrics-service`, and 13 CRDs: the 10 already installed plus `approverpolicymanagers.operator.openshift.io`, `certificaterequestpolicies.policy.cert-manager.io` and `http01proxies.operator.openshift.io`. The bundle lookup names `okd-test/cert-manager/operator-bundle@sha256:99ccae85…`, the Task 6 build.

The InstallPlan's CSV step does not carry the manifest inline; it points at the bundle unpack ConfigMap in `openshift-marketplace`, whose `binaryData` entries are base64 of gzip. Decoded, the CSV has the operator at `operator@sha256:8929d637…`, the operands at the build's digests (`cert-manager@cde9f9ba…`, `acme-solver@5c192cbc…`, `istio-csr@e37564b3…`), trust-manager and approver-policy as quay digests (not enabled), `UNSUPPORTED_ADDON_FEATURES` empty, the expected `machineconfigs` rule (`create,delete,get,list,update,watch`), no Red Hat registry reference, `minKubeVersion: 1.31.0`, `olm.skipRange: '>=1.0.0 <1.21.0-2026-11-21-163714'`.

The operator approved it; the Subscription read `approved` at 16:26:25Z, which is the soak start. Polled every 10 s:

| Time (Z) | State |
|---|---|
| 16:26:25 | InstallPlan `Installing`; new CSV created |
| 16:26:36 | v1.20 `Replacing`, v1.21 `InstallReady` |
| 16:26:47 | InstallPlan `Complete`, v1.21 `Installing` |
| 16:26:58 | v1.21 `Succeeded`, v1.20 gone; cert-manager, -cainjector, -webhook 1/1 on `cert-manager@sha256:cde9f9ba…` |

About 33 s. The master pool stayed `3/3/0`, not updating, with 62 MachineConfigs throughout.

Post-roll checks (16:55Z): CertManager CR conditions all fine; the controller keeps both `--dns01-recursive-nameservers*` flags; the operator logs `"enabled controllers" istioCSR=true trustManager=false http01Proxy=false`; no `HTTP01Proxy` objects; storedVersions unchanged (`v1` / `v1alpha1`); both cert-manager webhook configurations carry an 896-byte `caBundle`. The six cert-manager CRDs with an `inject-ca-from` annotation read an empty `caBundle`, because their conversion strategy is `None`, so there is nothing to inject. Five Certificates Ready with unchanged revisions; `letsencrypt-prod` Ready; 55/55 apps Synced and Healthy; the `Upgradeable` message still names only the descheduler, cluster-logging and loki-operator, so 1.21 adds no version cap.

Logs: the controller logged the three expected start-up lines (`ACME client for issuer not initialised/available`). cainjector logged four errors at 16:27:09Z, all `unable to fetch certificate that owns the secret ... Certificate.cert-manager.io "api-cert" not found` for `openshift-kube-apiserver/user-serving-cert-000`. That Secret is the kube-apiserver operator's copy of the `api-cert` Secret, which keeps cert-manager's annotations in a namespace where no such Certificate exists. Start-up only; to re-check during the soak.

Staging DNS-01 on 1.21, the Task 2 kit unchanged (operator applied, then deleted, both files):

- ClusterIssuer `letsencrypt-staging-test` `Ready=True ACMEAccountRegistered` (a new account, the 1.20 run's was deleted), solvers identical to `letsencrypt-prod`.
- Certificate created 16:57:19Z; CertificateRequest `cm-dns01-test-1` Approved 16:57:20Z; Challenge `dns-01` pending at 16:57:33Z, valid by 16:58:46Z; Order `valid`; CertificateRequest Ready 16:58:47Z. **88 s** apply to Ready (1.20: 83 s). `notBefore 2026-11-22T16:00:14Z`, `notAfter 2027-01-25T16:00:13Z`.
- Controller errors during the run: one `ACME client for issuer not initialised` while the account registered, one `failed to update status` on the Order with no error text (the Order ended `valid`). The 1.20 run logged three lines of the same kind.
- Cleanup in order (Certificate, ClusterIssuer, then both Secrets); afterwards both Secrets and the ClusterIssuer read `NotFound` and no CertificateRequest, Order or Challenge for it remained.

Next: the 24 h soak to about 16:30Z on 2026-11-23, then the draft pipeline PR. The first production renewal on 1.21 is `api-cert` and `okd-wildcard`, about 2026-12-05 12:30Z.

## 2026-11-23 — the 24 h soak: passed, and the `api-cert` errors are 1.20's too

The soak read at 16:31:12Z, 24 h after the InstallPlan approval (16:26:25Z), read-only (`KUBECONFIG=~/.kube/config-readonly`):

- 3/3 nodes Ready, no ClusterOperator off `True False False`, 55/55 apps Synced and Healthy, every CSV `Succeeded`
  (`cert-manager-operator.v1.21.0-2026-11-21-163714` included).
- All 5 Certificates Ready. Next renewals: `barman-cloud-client`/`-server` 2026-11-24 ~15:10Z, `api-cert` and
  `okd-wildcard` 2026-12-05 ~12:30Z (the first production ACME renewals on 1.21), `homelab-wildcard` 2027-01-19.
- MCP master `True False False`, 62 MachineConfigs: no MachineConfig from the 1.21 operator.
- 0 restarts on cert-manager, cainjector, webhook and the operator.
- cert-manager controller: 5 `E` lines since the switch, all from 2026-11-22: 3 at 16:27:28Z (start-up) and 2 from the
  staging test (16:57:21Z `ACME client for issuer not initialised/available` right after the staging Issuer was
  created, 16:58:48Z a `failed to update status` conflict on `cm-dns01-test-1-…`). Webhook: 0.

The one finding: cainjector logged 8 more lines at 13:49:25Z,

```
E1123 13:49:25.544869 1 indexers.go:67] "unable to fetch certificate that owns the secret" err="Certificate.cert-manager.io \"api-cert\" not found" ... secret="openshift-kube-apiserver/user-serving-cert-000" certificate="openshift-kube-apiserver/api-cert"
```

the same 4 start-up lines as 16:27:09Z yesterday, twice (one per injectable kind: APIService, CRD, mutating and
validating webhook configuration). `user-serving-cert-000` is kube-apiserver-operator's copy of `api-cert`, made with
the cert-manager annotations still on it, in a namespace that has no Certificate. Nothing had written it: its only
managedFields entry is `cluster-kube-apiserver-operator` on 2026-10-06 (`--show-managed-fields`; `oc` hides them by
default). No CRD or webhook-CA write, no pod restart, no leader change either, so it reads as an informer re-list that
re-runs the secret map function.

Is it new in 1.21? The source says no. `certFromSecretToInjectableMapFuncBuilder` in
`pkg/controller/cainjector/indexers.go` has the same `log.Error(err, "unable to fetch certificate that owns the
secret")` in v1.20.4 (line 61) and v1.21.3 (line 67). The only change in 1.21 is an early return for an opt-in
`--ignore-namespaces` list, empty by default. So 1.20 logged these too and nobody had looked. The operator ruled them
expected for the soak. `--ignore-namespaces=openshift-kube-apiserver` on cainjector would silence them; not done,
cosmetic.

Soak: PASS. Left: the draft pipeline PR, the 2026-12-05 renewal, the move back to `okderators` once it publishes 1.21.

## 2026-11-23 — the pipeline PR

Draft PR okd-project/okd-operator-pipeline#56, `[cert-manager] Update to 1.21`, `main` ← `sudoom:cert-manager-1.21`
(2 commits, level with upstream `main` `2b205ade6f8d`). Re-checked before opening: Red Hat still has no
`cert-manager-1.21` (operator) or `release-1.21` (jetstack fork) branch, so the gitlinks stay at operator `master`
`157e4aa1fd03` (the merge of openshift/cert-manager-operator#538, "Bump operator to 1.21.0") and tag `v1.21.3`
`925c22283de5`; operator `master` is 39 commits past that pin. The body names the unchanged istio-csr gitlink
`6d4c57cfdfdc` (older than both operators' expected v0.16.0 / v0.19.1), the approver-policy and trust-manager images
left at upstream defaults, and the MachineConfig RBAC the alpha `HTTP01Proxy` gate brings. No backport: `release-4.22`
still builds 1.18 and has #53 open. Next: maintainer review; after the merge, `cert-manager-deploy.yaml` should open the
catalog PR against `okderators-catalog-index` `release-5.0` itself.
