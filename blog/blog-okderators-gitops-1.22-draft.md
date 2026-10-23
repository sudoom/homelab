# okderators: GitOps 1.22 for OKD 4.20-4.22, and this cluster's upgrade from 1.19

Working notes for an upstream contribution to the OKD community operator catalog ("okderators"): the build pipeline
`okd-project/okd-operator-pipeline` and the catalog `okd-project/okderators-catalog-index`. This homelab runs OpenShift
GitOps 1.19.0 (Argo CD v3.1.11) from okderators, and okderators builds nothing newer than 1.19 for anyone. Argo CD's
own tested table puts 3.1 at Kube 1.31-1.34, which is fine on OKD 4.21 and untested on 4.22's Kube 1.35, so GitOps has to
move before the 4.22 hop. The plan is the one used for logging 6.6 (`blog/blog-okderators-logging-6.6-draft.md`): build
Red Hat's exact release on this cluster, upgrade this cluster from the test build, then file draft PRs with that as proof.

## 2026-10-22 - decisions

- Version: **GitOps 1.22**, Red Hat's current `latest` (operator: "lets go with the latest"), over 1.20 / 1.21. It bundles
  Helm 4.2.4 (this cluster's 49 apps render identically under Helm 3.18.6 and 4.2.4 apart from blank lines before `---`).
  Red Hat ships 1.22.2 as `latest` on OCP 4.20, 4.21 and 4.22 alike, and Argo CD 3.5 is tested on Kube 1.33-1.36.
- Approach: the same as logging 6.6. In-cluster build Job, live upgrade of this cluster from the test build, draft PRs
  with that as proof, catalog PRs after upstream CI has built official images, then move this cluster onto the official
  build.
- Test images in zot under `okd-test/` (accepted: the operator that runs ArgoCD then pulls from zot, and zot is itself an
  ArgoCD app, so a zot outage stops GitOps pods from being rescheduled until zot is back).
- Pin: what Red Hat shipped as 1.22.2, not the branch head. If Red Hat ships a newer 1.22.z before the build Job starts,
  re-pin; once the build has run, a newer z is a follow-up.
- CephCluster health: Argo CD 3.3+ has a built-in CephCluster health check that makes `HEALTH_WARN` Degraded, and this
  cluster's Ceph is permanently `HEALTH_WARN`. A Lua override in the ArgoCD CR is applied on 1.19 first, before the upgrade.
- All four pipeline branches (`main`, `release-4.22`, `release-4.21`, `release-4.20`) get the same `gitops/` change, plus
  each branch's `gitops-deploy.yaml`. One channel (`alpha`) as every okderators package; the new catalog entry replaces
  `gitops-operator.v1.19.0-2026-02-07-151505` and jumps over 1.20 and 1.21.
- Every image the 1.22 CSV can deploy is built, so no okderators install references `registry.redhat.io`. The PF5 console
  plugin (`console-plugin-4-18`, OCP 4.18 only) is skipped.

## 2026-10-22 - recon summary

Read-only research on the pipeline, the catalog and this cluster before any change.

- Pipeline `gitops/` is byte-identical on all four branches: `build.sh` with `MINOR=19`, `env-override.yaml`, a branding
  CSV overlay, `patches/release.patch` and the submodule `gitops/release` -> `rh-gitops-midstream/release` at gitlink
  `96727513` (a 1.19.2-era snapshot).
- `build.sh` does not survive `MINOR=22` alone: `containers/argocd-rhel9/` is now `containers/argocd/`, gitops-operator
  1.22 has no `config/default/manager_auth_proxy_patch.yaml` (kube-rbac-proxy is gone), and `env-override.yaml` names are
  stale (the rollouts extension was renamed; agent, promoter, promoter-extension and the PF5 plugin are new).
- `patches/release.patch` fails `git apply --check` on 1.22 (and on 1.19 head). Builders are now `rhel9/go-toolset:1.26`.
- The argocd and console-plugin UI stages use `pnpm install --offline` with a Hermeto placeholder `.npmrc` (Konflux
  prefetch). Expected to fail outside Konflux; inferred, not run.
- After `make bundle`, `spec.replaces` is a stale `v1.7.3` and there is no skipRange.
- Upstream CI "Deploy GitOps" has never run; whether a hosted runner (about 14 GB disk) can build about a dozen GitOps
  images is unproven.
- Catalog: `catalog/gitops-operator/` is identical on `release-4.20/4.21/4.22`: `alpha` = v1.13 -> v1.16 ->
  `v1.19.0-2026-02-07-151505`, `replaces` only.
- This cluster: Subscription `openshift-operators/gitops-operator`, `alpha`, okderators, Manual. The ArgoCD CR
  `openshift-gitops/openshift-gitops` is operator-defaulted (nothing in git).

## 2026-10-22 - the 1.22.2 pin table

Is there a newer 1.22.z than the one the earlier research found? The Red Hat container catalog GraphQL API
(`https://catalog.redhat.com/api/containers/graphql/`, python urllib: curl is denied on this workstation):

```
find_operator_bundles(package: "openshift-gitops-operator", ocp_version: "4.21", sort_by creation_date DESC)
  -> 1.22.2  channels latest + gitops-1.22   2026-10-15   (same newest bundle for 4.20, 4.22 and 5.0)
find_repository_images_by_registry_path(openshift-gitops-1/gitops-rhel9-operator, newest first)
  -> 2026-10-15 tags 1.22, v1.22.2, v1.22.2-7
```

Nothing newer. The bundle's `related_images` has 17 entries. For each I resolved the image by exact digest with
`find_repository_images_by_registry_path` and read its labels with `get_image { data { parsed_data { labels } } }`.
Konflux-built images carry `vcs-ref` = `downstream-source-ref` = `6c4a911765610abf65a3344d16bafdeca0971e5a` (midstream
`rh-gitops-midstream/release`, "chore(build): bump to v1.22.2-7 (#1762)") and `upstream-source-ref` = the component's
upstream commit. `io.openshift.build.commit.id` exists only on must-gather (a base-image label) and on the two images
built by OCP's own pipeline, so the upstream commit comes from `upstream-source-ref`.

```
gh api repos/rh-gitops-midstream/release/compare/release-1.22...6c4a911765610abf65a3344d16bafdeca0971e5a \
  --jq '.status+" ahead_by="+(.ahead_by|tostring)+" behind_by="+(.behind_by|tostring)'
behind ahead_by=0 behind_by=25
```

The pin is on `release-1.22`; the branch head `189bf8170` (v1.22.2-16, Argo CD v3.5.6) is 25 commits later and unshipped.

| relatedImages name | Red Hat image (`openshift-gitops-1/...`) | upstream repo | `upstream-source-ref` (full) | okderators builds it |
|---|---|---|---|---|
| `(bundle)` | `gitops-operator-bundle` | redhat-developer/gitops-operator | `cf32771491be2ed7f03d43d279171d6c265f2d2b` | no (bundle: built by the pipeline) |
| `argo_rollouts_image` | `argo-rollouts-rhel9` | argoproj/argo-rollouts | `356117c8e9a21b74b58c2c01d640aa91994522b5` | yes |
| `argocd_agent_image` | `argocd-agent-rhel9` | argoproj-labs/argocd-agent | `78a3788f5aa757707c00e563198f3d4c676fe04b` | yes |
| `argocd_principal_image` | `argocd-agent-rhel9` | argoproj-labs/argocd-agent | `78a3788f5aa757707c00e563198f3d4c676fe04b` | yes |
| `rollouts_extension_image` | `argocd-extensions-rhel9` | argoproj-labs/argocd-extension-installer | `379284c7aaa0717c4224ab119133bf2bad2c7bfd` | yes |
| `argocd_image_updater_image` | `argocd-image-updater-rhel9` | argoproj-labs/argocd-image-updater | `6032a807ecf893734999a9f8eb514407b2707b28` | yes |
| `promoter_extension_image` | `argocd-promoter-extension-rhel9` | argoproj-labs/argocd-extension-installer | `379284c7aaa0717c4224ab119133bf2bad2c7bfd` | yes |
| `argocd_image` | `argocd-rhel9` | argoproj/argo-cd | `a5038b0e2bbac1715754380ae0084df8e3d5b48c` | yes |
| `gitops_console_plugin_image_pf5` | `console-plugin-4-18-rhel9` | redhat-developer/gitops-console-plugin | `bc5872a4aa59a01c75eb96da9549a92aee9fb9a8` | no (PF5, OCP 4.18 only) |
| `gitops_console_plugin_image` | `console-plugin-rhel9` | redhat-developer/gitops-console-plugin | `0a2a15ca903e078d712127fb74492bcce96e83ba` | yes |
| `argocd_dex_image` | `dex-rhel9` | rh-gitops-midstream/dex | `c205840eb6e81ab03bac51b33a42d3c31f947a3c` | yes |
| `gitops_promoter_image` | `gitops-promoter-rhel9` | argoproj-labs/gitops-promoter | `cabfecc9ba28cffb0da2f32a7d5a93516ae059c1` | yes |
| `manager` | `gitops-rhel9-operator` | redhat-developer/gitops-operator | `cf32771491be2ed7f03d43d279171d6c265f2d2b` | yes |
| `backend_image` | `gitops-rhel9` | redhat-developer/gitops-backend | `2c16e0c8eaa6923ac35d9256a36f13349e10d339` | yes |
| `must_gather_image` | `must-gather-rhel9` | redhat-developer/gitops-must-gather | `652c9890d6c5c7429d4edb6bed4d006e8d415c32` | yes |
| `argocd_redis_ha_proxy_image` | `ose-haproxy-router-rhel9` (OCP-built, v4.22.0) | openshift/router | `b70b28c0380056950793382f42b9b2eaf9330945` | no (public: `build.sh` takes `haproxy-router` from the OKD release payload) |
| `argocd_redis_image` | `rhel9/redis-7` | Red Hat dist-git | `82146f3573d02102ff9db722ae5f416cecce1e70` (`vcs-ref`) | no (public: `build.sh` uses `quay.io/sclorg/redis-7-c9s:latest`) |

`argocd_agent_image` and `argocd_principal_image` are one digest (one build, two env vars). 17 rows, 13 built rows = 12
distinct images, plus the generated bundle. The 1.19 `build.sh` also built `cli` and `agentctl`; neither is in the 1.22.2
relatedImages.

Every midstream gitlink at the pin equals `config.yaml`'s `commit:`, and each is on its declared ref:

| path | repo | ref | gitlink (full) | `compare/<ref>...<sha>` |
|---|---|---|---|---|
| `sources/gitops-operator` | redhat-developer/gitops-operator | `v1.22` | `cf32771491be2ed7f03d43d279171d6c265f2d2b` | behind |
| `sources/argo-cd` | argoproj/argo-cd | `v3.5.5` | `a5038b0e2bbac1715754380ae0084df8e3d5b48c` | identical |
| `sources/argo-rollouts` | argoproj/argo-rollouts | `v1.10.1` | `356117c8e9a21b74b58c2c01d640aa91994522b5` | identical |
| `sources/kustomize` | kubernetes-sigs/kustomize | `kustomize/v5.8.2` | `2e294e3e92a56fe9cfa1e755e6e57c5f1268ce22` | identical |
| `sources/helm` | helm/helm | `v4.2.4` | `3900f434fd3ef2b84065dc04508df48f288dba00` | identical |
| `sources/dex` | rh-gitops-midstream/dex | `v2.45.1` | `c205840eb6e81ab03bac51b33a42d3c31f947a3c` | identical |
| `sources/git-lfs` | git-lfs/git-lfs | `v3.7.1` | `b84b33847fe6458f36ef521534dc0eac953cb379` | identical |
| `sources/ssh-connect` | gotoh/ssh-connect | `1.106` | `a7443d32e6bf6f00698384b0519adc16fa7656fa` | identical |
| `sources/tini` | krallin/tini | `master` | `369448a167e8b3da4ca5bca0b3307500c3371828` | identical |
| `sources/argocd-extension-installer` | argoproj-labs/argocd-extension-installer | `v1.1.0` | `379284c7aaa0717c4224ab119133bf2bad2c7bfd` | identical |
| `sources/gitops-console-plugin` | redhat-developer/gitops-console-plugin | `v1.22` | `0a2a15ca903e078d712127fb74492bcce96e83ba` | identical |
| `sources/gitops-console-plugin-4-18` | redhat-developer/gitops-console-plugin | `release-4.18` | `bc5872a4aa59a01c75eb96da9549a92aee9fb9a8` | identical |
| `sources/gitops-backend` | redhat-developer/gitops-backend | `master` | `2c16e0c8eaa6923ac35d9256a36f13349e10d339` | behind |
| `sources/rollouts-plugin-trafficrouter-openshift` | argoproj-labs/rollouts-plugin-trafficrouter-openshift | `main` | `cd2cb638dfc1d1ae4eb299f3bcad1dd98ddefc57` | behind |
| `sources/gitops-must-gather` | redhat-developer/gitops-must-gather | `main` | `652c9890d6c5c7429d4edb6bed4d006e8d415c32` | behind |
| `sources/rollout-extension` | argoproj-labs/rollout-extension | `v0.4.0` | `ceef45e6288c4c64f5274f7272f0e3488b3a9332` | identical |
| `sources/argocd-agent` | argoproj-labs/argocd-agent | `v0.10.0` | `78a3788f5aa757707c00e563198f3d4c676fe04b` | identical |
| `sources/argocd-image-updater` | argoproj-labs/argocd-image-updater | `v1.3.1` | `6032a807ecf893734999a9f8eb514407b2707b28` | identical |
| `sources/gitops-promoter` | argoproj-labs/gitops-promoter | `v0.35.0` | `cabfecc9ba28cffb0da2f32a7d5a93516ae059c1` | identical |
| `sources/argo-cd-ui-ref` | argoproj/argo-ui | (none, `.gitmodules` only) | `c089d1d2d84df87f3712ae661273a5ab0d1ef3b0` | behind (13, vs `master`) |
| `sources/argo-rollouts-ui-ref` | argoproj/argo-ui | (none, `.gitmodules` only) | `5ff344ac9692c14dd108468bd3c020c3c75181cb` | behind (60, vs `master`) |

The two `*-ui-ref` submodules are not in `config.yaml` but `containers/argocd/Dockerfile` does `COPY
sources/argo-cd-ui-ref`, so the build has to initialise them (they are nested in the midstream submodule).

Red Hat's own Containerfiles for these digests are kept for comparison (`find_image_files`, `key == "buildfile"`): 16
distinct images, all non-empty. The argocd one confirms the UI stage: `ubi9/nodejs-22`, `pnpm install --frozen-lockfile
--offline --ignore-scripts` (`argocd-rhel9.Dockerfile` lines 20-44).

## 2026-10-22 - migration review: what a direct 1.19.0 -> 1.22 jump skips

The question: does the gitops-operator (or the argocd-operator it embeds) run any one-time migration gated on the previous
version, which a jump over 1.20 and 1.21 would skip? I read `redhat-developer/gitops-operator` at `cf32771`
(1.22.2) against the 1.19-era `63aa7a94d2c3c1e72c6c2bb9359cfb4bffa52c10` (the `sources/gitops-operator` gitlink of the
midstream commit the pipeline pins today), and `argoproj-labs/argocd-operator` at the commits each `go.mod` pins:
`99b07bc7c58060e4ba471c3d24504ba61f38d000` (v0.17.1-0.20260217...) for 1.19, `a213c171036aaae3b90a44754420d14e6752287b`
(v0.20.0-rc1.0.20261011...) for 1.22.

**Result: no migration is gated on the previous operator version.** The only version comparisons are on the *cluster*
version (`semver.Compare(version, "v4.10.999")` in `controllers/util/util.go:292` and
`controllers/argocd/openshift/openshift.go:56`, identical in 1.19; the PF5/PF6 plugin choice below). Everything that
cleans up old state runs on every reconcile, so a direct jump runs it too. What changed between the two, and what each
means here:

1. **Stale `argocd.argoproj.io/tracking-id` / `installation-id` annotations on operator-created RoleBindings (the 1.20
   release-note item).** Cause: in the 1.19-era argocd-operator, `AnnotationsForCluster` copied every annotation of the
   ArgoCD CR onto each Role, RoleBinding and ClusterRole it creates (`controllers/argoutil/resource.go:150-155`, called
   from `controllers/argocd/rolebinding.go:28,51,63` and `role.go:60`). In 1.22 it returns only the two
   `argocds.argoproj.io/name|namespace` annotations (`resource.go:216-219`). No code removes annotations already on
   existing RoleBindings (the only annotation reconcile in `role.go:508-518,554-562` is for the base ClusterRoles, and
   `rolebinding.go` has none), in any version, so the stepwise path skips nothing either: it is a manual step.
   Live check, readonly kubeconfig: the ArgoCD CR has no annotations (`{}`), and the nine operator-created
   RoleBindings/ClusterRoleBindings (`openshift-gitops-*`) carry only `argocds.argoproj.io/name` and `/namespace`.
   **Nothing to clean here.** (The dozens of RoleBindings with `argocd.argoproj.io/tracking-id` on this cluster belong to
   ArgoCD-managed apps, not to the operator.)
2. **Namespace pod-security labels (1.20 notes: "no hard-coded pod-security labels").** 1.19 hard-coded
   `pod-security.kubernetes.io/enforce|audit|warn` = `restricted` (enforce-version `v1.29`) on `openshift-gitops`
   (1.19: `gitopsservice_controller.go:877-882`, `:968-976`). 1.22 sets only
   `security.openshift.io/scc.podSecurityLabelSync=true` on `openshift-` namespaces (`:78-80`, `:946`) and
   `ensurePodSecurityLabels` (`:1041-1049`) adds that one label and never removes the old ones; `ensureNamespaceMetadata`
   (`:1032-1039`, called at `:272` and `:465`) is the only caller. So after the jump the namespace keeps its old labels
   and gains the sync label. Live: `openshift-gitops` carries the full 1.19 set and no sync label. **To watch after the
   upgrade:** the namespace labels, and that the new pods (promoter, agent, image-updater if enabled) are admitted
   under `restricted`/`v1.29`. The syncer is expected to rewrite the labels; this is not proven here.
3. **KAM cleanup (`gitopsservice_controller.go:285`, `:345-390`).** New since 1.19: deletes a `kam` Deployment, Service
   and Route in `openshift-gitops` every reconcile ("KAM is no longer supported since 1.15"). Not version-gated. This
   cluster has none (the live deployment list has no `kam`).
4. **Resource tracking default (argocd-operator 0.17: `label` -> `annotation`; `docs/upgrading.md:83-163`).** Already
   passed: 1.19 ships argocd-operator 0.17.1, and live `argocd-cm` reads `application.resourceTrackingMethod:
   annotation` with `.spec.resourceTrackingMethod` unset. The 1.22 operator changes nothing here.
5. **ApplicationSet tokenRef strict mode (0.19+; `docs/upgrading.md:5-79`).** Only when
   `.spec.applicationSet.sourceNamespaces` is set. Live: it is empty and `oc get applicationsets -A` finds none.
6. **Legacy-name StatefulSet cleanup (`controllers/argocd/statefulset.go:425-450` Redis HA, `:898-925`
   application-controller).** New naming cap of 52 characters (`argoutil/resource.go:164-171`); the old StatefulSet is
   deleted only when the name changes. `openshift-gitops-application-controller` is 39 characters, so it keeps its name;
   Redis HA is off. No effect.
7. **Dex / OpenShift SSO skipped when external auth is enabled** (`controllers/argocd/argocd.go` `getArgoSSOSpec`,
   `controllers/argocd/dex.go:155-162`: `Authentication/cluster` `.spec.type == "OIDC"`). Live: `.spec.type` is empty
   (built-in OAuth), so Dex stays.
8. **Cluster TLS profile (`cmd/main.go:113,141,160-172,234-249`).** The operator now reads the APIServer TLS profile at
   start, exits 1 if it cannot fetch it, applies it to its own metrics and webhook servers and to the ArgoCD CR
   (`CentralTLSConfigProfile`), and restarts itself when the profile changes. `--disable-cluster-tls-profile` or
   `DISABLE_CLUSTER_TLS_PROFILE=true` turns it off. The operator needs `config.openshift.io/apiservers` get/list/watch
   (kubebuilder marker in `gitopsservice_controller.go`, carried into the bundle's permissions). New behaviour, not a
   migration.
9. **Console plugin by OCP version (`gitopsservice_controller.go:315-340`, `common/common.go:42-44`).** PF6 plugin for
   cluster versions >= 4.19.0, PF5 (`GITOPS_CONSOLE_PLUGIN_IMAGE_PF5`) only for 4.18. OKD 4.21's `4.21.0-okd-scos.11`
   parses as a pre-release of 4.21.0, so it takes the PF6 path and the PF5 image is never needed. The operator's own
   defaults point at `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/...` images
   (`gitopsservice_controller.go` `backendImage`, `common.go:35`), so the CSV env must always set `BACKEND_IMAGE` and the
   other `*_IMAGE` vars; otherwise the operator would fall back to a Red Hat tenant registry.

So the direct jump is safe on code grounds. Items 2 and 8 are the ones to look at after the live upgrade.

## 2026-10-22: pre-upgrade prep on GitOps 1.19, the CephCluster health override

Argo CD 3.3 ships a built-in Lua health check for `ceph.rook.io/CephCluster` that maps `HEALTH_WARN` to Degraded. This Ceph is permanently `HEALTH_WARN` (`BLUESTORE_SLOW_OP_ALERT`, `MON_DISK_LOW`), and a Degraded resource fails a multi-wave sync, so after the 1.22 upgrade `rook-ceph-cluster`'s hourly sync would fail before its wave-10/11 bootstrap Jobs. I chose to override the check rather than silence the warnings. The ArgoCD CR is operator-defaulted and not in git, so the override is a hand-applied merge patch in `bootstrap/phase0/06_argocd_cephcluster_health.yaml`.

### Failing test (RED)

Live CephCluster dumped read-only, evaluated offline with the local v3.5.6 CLI against an empty `argocd-cm`:

```
oc -n rook-ceph get cephcluster -o yaml | yq e '.items[0]' - > cephcluster.yaml
argocd admin settings resource-overrides health cephcluster.yaml --argocd-cm-path argocd-cm-empty.yaml
STATUS: Degraded
MESSAGE: Ceph health is HEALTH_WARN (2 OSD(s) experiencing slow operations in BlueStore; mon c is low on available space) - Cluster created successfully
```

I read upstream's `health.lua` (v3.5.6). It also folds in `status.state` and the detail messages; mine is deliberately smaller: no status -> Progressing; `HEALTH_OK`/`HEALTH_WARN` -> Healthy; `HEALTH_ERR` -> Degraded; message = health + sorted `status.ceph.details` keys; no health field -> `status.phase == Ready` -> Healthy else Progressing.

### Passing test (GREEN)

The Lua extracted from the patch file into `resource.customizations.health.ceph.rook.io_CephCluster` of a test `argocd-cm`:

```
argocd admin settings resource-overrides health cephcluster.yaml --argocd-cm-path argocd-cm-test.yaml
STATUS: Healthy
MESSAGE: HEALTH_WARN: BLUESTORE_SLOW_OP_ALERT, MON_DISK_LOW
```

Edited copies (yq): `HEALTH_ERR` -> `Degraded` ("HEALTH_ERR: BLUESTORE_SLOW_OP_ALERT, MON_DISK_LOW"); `del(.status)` -> `Progressing` ("Waiting for status"); `HEALTH_OK` without details -> `Healthy` ("HEALTH_OK"); health field removed + `phase: Ready` -> `Healthy`; health removed + `phase: Progressing` -> `Progressing`.

Live CR check before writing the patch: `oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.resourceHealthChecks}'` printed nothing, so replacing the list loses nothing.

### Drift fix

`bootstrap/phase0/02_gitops_operator.yaml` said `installPlanApproval: Automatic`; live is `Manual` (since before the 4.21 catalog flip). The file now says `Manual`, `source` stays `okderators`.

### Baseline before the upgrade (read-only, ConfigMaps only)

- Subscription: `Manual okderators alpha gitops-operator.v1.19.0-2026-02-07-151505`.
- 49 Applications: 49 Synced / Healthy.
- `openshift-gitops` pods (8): `cluster`, `gitops-plugin`, application-controller-0, applicationset-controller, dex-server, redis, repo-server, server; all Running, 0 restarts.
- ArgoCD CR spec top-level keys: applicationSet, controller, grafana, ha, imageUpdater, initialSSHKnownHosts, monitoring, notifications, prometheus, rbac, redis, repo, resourceExclusions, server, sso, tls. No `resourceHealthChecks`.
- `argocd-cm` keys: admin.enabled, application.instanceLabelKey, application.resourceTrackingMethod, dex.config, ga.*, help.*, kustomize.buildOptions, oidc.config, resource.exclusions, resource.inclusions, server.rbac.disableApplicationFineGrainedRBACInheritance, statusbadge.enabled, url, users.anonymous.enabled. `argocd-cmd-params-cm`: `controller.resource.health.persist`. `argocd-rbac-cm`: policy.csv, policy.default, scopes.
- Bindings carrying an Argo CD `tracking-id` annotation: 43 ClusterRoleBindings + 29 RoleBindings (72); none carry `installation-id`.

### Operator steps

```
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.resourceHealthChecks}{"\n"}'   # expect empty
oc patch argocd openshift-gitops -n openshift-gitops --type merge --patch-file bootstrap/phase0/06_argocd_cephcluster_health.yaml
```

The recovery path for a failed operator upgrade (break-glass, then delete Subscription + CSV and reinstall 1.19.0 from `okderators` with Manual approval) is in `bootstrap/phase0/readme.md`, marked untested.

## 2026-10-22: the build Job for the gitops 1.22 build

The logging build ran as a Job in `okd-build`; the gitops build needs the same thing, so I copied
`tests/okderators-logging-build/` to `tests/okderators-gitops-build/` and changed what had to change.
Files: `README.md`, `kustomization.yaml`, `build.sh`, `catalog-edit.sh`, `catalog-walk.py`,
`job-template.yaml`, `log-reader.yaml`.

What stayed: the Job env contract (`MODE` full/check/catalog, `PIPELINE_REPO`, `PIPELINE_BRANCH`, `DATE`,
`BASE_REGISTRY`, `CATALOG_BRANCHES`, `BUNDLES`), the contract lines (`STEP`, `DISK`, `PUSHED`, `CHECK`,
`RESULT`), contract and log files on the PVC, the `flock`, the tool pins and checksums, the push guards
(only under `okd-test/`, never re-push a tag).

What changed:
- `build.sh` sources `gitops/build.sh` (not `cluster-logging/build.sh`) and reads every `IMG_*` back
  generically, so it follows the image list after the pipeline change. `IMG_KUBE_RBAC_PROXY`,
  `IMG_HAPROXY_ROUTER` and `IMG_REDIS` are the three the pipeline takes from outside the registry; they are
  allowed by name and shape, never pushed. `gettext` joins the dnf list because `build_bundle` runs `envsubst`.
- The Job does not own the namespace. The kustomization generates only ConfigMap `gitops-build-scripts`;
  namespace, SA `builder`, the privileged RoleBinding and PVC `build-storage` stay in the logging
  directory. Job prefix `gitops-build-`, log files `gitops-build-<MODE>-<DATE>`, reader pod `gitops-log-reader`.
- `MODE=full` always starts with a `prune` step: `DISK`, `podman system prune -af`, `DISK` (the logging run
  left ~37 GB of layers; nothing there needs keeping). Base layers are then re-pulled, so `max(DISK)` of the
  run approximates a fresh hosted runner; stop rule: peak > 14 GB.
- `MODE=full` emits `ARGOCD_VERSION <v>` after the push, read with
  `podman run --rm --entrypoint argocd <IMG_ARGOCD> version --client --short`; `CHECK argocd-version` passes
  only for exactly `v3.5.5` (one variable at the top of `build.sh`).
- Verify also fails on: any `registry.redhat.io` / `registry-proxy.engineering.redhat.com` / `brew.registry` string
  anywhere in the rendered CSV, an `olm.skipRange` other than `>=1.0.0 <1.22.0-<DATE>`, and a set `spec.replaces`.
- `MODE=check` tag-checks every tag it would push under `check-<branch>/` before pushing; a redo needs a new
  full run with a new `DATE`.
- `MODE=catalog` edits package `gitops-operator` only: `name: gitops-operator.v1.22.0-<DATE>`,
  `replaces: gitops-operator.v1.19.0-2026-02-07-151505`, `skipRange: '>=1.19.0-0 <1.22.0-<DATE>'`; pushes
  `${BASE_REGISTRY}/gitops-catalog:${DATE}`. The `-0` matters: the installed 1.19.0 is a prerelease.
- The walker gained `--hop FROM TO`: the edges leaving FROM must lead to TO and nowhere else. Dead-end
  checking cannot see a skipRange that is too wide, because every old entry still reaches the head.

Checks, all before any cluster run:
- `bash -n` on both shell scripts, `python3 -I -m py_compile catalog-walk.py`.
- `kubectl kustomize tests/okderators-gitops-build/ | kubeconform -strict -ignore-missing-schemas`: 1 valid.
  Same for the `oc process --local` Job and for `log-reader.yaml`.
- `KUBECONFIG=~/.kube/config-readonly oc diff -k tests/okderators-gitops-build/` fails for the read-only SA:
  `configmaps is forbidden: User "system:serviceaccount:automation:claude-reader" cannot create resource
  "configmaps" in API group "" in the namespace "okd-build"` (server-side dry-run counts as create).
  Instead, `oc -n okd-build get configmap gitops-build-scripts` returns NotFound; namespace, SA and PVC exist.
- `catalog-edit.sh` in test mode against the real `release-4.21` and `release-4.22` `catalog/gitops-operator/`
  files (okderators-catalog-index, upstream remote) plus a hand-written bundle
  `gitops-operator.v1.22.0-2026-10-22-120000`: 0 failed checks on both branches. The walk shows
  1.13 -(replaces)-> 1.16 -(replaces)-> 1.19.0 -(replaces+skipRange)-> 1.22. Negative control 1: the bundle
  file without its channel entry fails `opm validate`
  (`bundle "gitops-operator.v1.22.0-..." not found in any channel entries`). Negative control 2: with
  `skipRange: '>=1.0.0 <1.22.0-...'` `opm validate` passes and the walker fails
  (`hop from ...v1.13... goes to ...v1.16..., ...v1.22..., want only ...v1.16...`).
- Not run locally: `build.sh` itself (bash 3.2 on the Mac, it needs bash 4.3 namerefs), `podman`, the push.
  Those run on the cluster.

Re-run after the tightening commit: `bash -n` on both scripts, `py_compile`, kustomize | kubeconform (1 valid)
and catalog-edit test mode (0 checks failed on both branches).

## 2026-10-22: OKD_VERSION for the GitOps build Job

`common.sh` on the pipeline's `main` defaults to `OKD_VERSION=5.0.0-okd-scos.0`, and the GitOps build takes the haproxy-router and must-gather images from that release payload. The test build runs from the `main`-based `gitops-1.22` branch but gets installed on this 4.21 cluster, so I added an optional `OKD_VERSION` template parameter to `tests/okderators-gitops-build/job-template.yaml`. It is always exported to the container, empty by default: `common.sh` uses `${OKD_VERSION:-"5.0.0-okd-scos.0"}`, and the colon form treats empty as unset. `build.sh` logs `INFO OKD_VERSION=<value or (pipeline default)>`; `load_vars` already prints the resolved `IMG_*` refs, haproxy-router included. The test build runs with `-p OKD_VERSION=4.21.0-okd-scos.10`, the value `release-4.21` uses.

## 2026-10-22: the pipeline change on `main` (`[gitops] Update to 1.22`)

I wrote the okd-operator-pipeline change on a local branch `gitops-1.22` cut from `origin/main` (`2598107`, the
cert-manager 1.20 merge). One commit. Nothing is built or pushed yet; the build runs on the cluster in a later step.
The checks below are static: the patch applies, the gitlink is the pin, every image has a build and a push line, no
Containerfile the build uses pulls from `registry.redhat.io`, and every image variable the operator reads is set.

### What failed first, on `origin/main`

```
$ git ls-tree origin/main gitops/release
160000 commit 96727513ecb31ce9ce798f1814292528bfea67ad	gitops/release
$ git show origin/main:gitops/build.sh | grep MINOR=
MINOR=19
$ git show origin/main:gitops/build.sh | grep -c manager_auth_proxy_patch
1
```

The current patch against a clean checkout of the midstream pin `6c4a911`:

```
$ git apply --check release.patch      # main's gitops/patches/release.patch
error: patch failed: clis/argocd-agentctl/Dockerfile:17
...
error: containers/argocd-rhel9/Dockerfile: No such file or directory
error: patch failed: containers/argocd/Dockerfile:17
...
error: containers/gitops/Dockerfile: patch does not apply
```

Every hunk fails: 1.22 Containerfiles already use RHEL 9 bases, and `containers/argocd-rhel9/` no longer exists
(the RHEL 9 Argo CD Containerfile is now `containers/argocd/`).

`registry.redhat.io` lines in the unpatched Containerfiles the build uses (count, then `pnpm install --offline` count):

```
containers/argo-rollouts/Dockerfile 2 0
containers/argocd/Dockerfile 2 1
containers/argocd-agent/Dockerfile 1 0
containers/argocd-image-updater/Dockerfile 2 0
containers/console-plugin/Dockerfile 0 1
containers/dex/Dockerfile 1 0
containers/gitops/Dockerfile 1 0
containers/gitops-operator/Dockerfile 2 0
containers/gitops-promoter/Dockerfile 2 0
containers/must-gather/Dockerfile 1 0
```

`main`'s `env-override.yaml` misses five variables the 1.22 operator reads, so the operator would fall back to its
compiled-in images for them: `ARGOCD_AGENT_IMAGE`, `GITOPS_CONSOLE_PLUGIN_IMAGE_PF5`, `GITOPS_PROMOTER_IMAGE`,
`PROMOTER_EXTENSION_IMAGE`, `ROLLOUTS_EXTENSION_IMAGE` (renamed from `ARGOCD_EXTENSION_IMAGE`; when it is unset,
argocd-operator uses the upstream extension-installer image and downloads the Rollouts extension from GitHub).

### Which variables the operator reads

I listed the image variables from the source at the pinned commits, not from Red Hat's CSV: gitops-operator
`cf32771` (`grep -rn 'os.Getenv('`), and the two modules it embeds, argocd-operator `a213c171` (`common/keys.go`, the
agent, principal and promoter controllers) and argo-rollouts-manager `67002e569d7f`. Fifteen names: `ARGOCD_IMAGE`,
`ARGOCD_DEX_IMAGE`, `ARGOCD_REDIS_IMAGE`, `ARGOCD_REDIS_HA_IMAGE`, `ARGOCD_REDIS_HA_PROXY_IMAGE`, `BACKEND_IMAGE`,
`GITOPS_CONSOLE_PLUGIN_IMAGE`, `GITOPS_CONSOLE_PLUGIN_IMAGE_PF5`, `ROLLOUTS_EXTENSION_IMAGE`,
`PROMOTER_EXTENSION_IMAGE`, `ARGO_ROLLOUTS_IMAGE`, `ARGOCD_PRINCIPAL_IMAGE`, `ARGOCD_AGENT_IMAGE`,
`ARGOCD_IMAGE_UPDATER_IMAGE`, `GITOPS_PROMOTER_IMAGE`. The defaults behind them are `quay.io/redhat-user-workloads/...`
(console plugin, backend) or upstream images.

One non-image variable matters too. The operator only uses the OpenShift route plugin baked into the Rollouts image when
`ARGO_ROLLOUTS_IMAGE` starts with `registry.redhat.io/openshift-gitops`; otherwise it points Rollouts at an amd64
binary on GitHub (`DefaultOpenShiftRoutePluginURL` in argo-rollouts-manager). Our Rollouts image is built from the same
Containerfile and carries `/plugins/rollouts-trafficrouter-openshift/openshift-route-plugin`, so I set
`OPENSHIFT_ROUTE_PLUGIN_LOCATION=file:/plugins/rollouts-trafficrouter-openshift/openshift-route-plugin`.

### The changes

- `.gitmodules`: `gitops/release` `branch = release-1.22`; gitlink set with
  `git update-index --cacheinfo 160000,6c4a911765610abf65a3344d16bafdeca0971e5a,gitops/release`.
- `gitops/build.sh`: `MINOR=22`; Argo CD from `containers/argocd/Dockerfile`; new `IMG_PROMOTER`
  (`containers/gitops-promoter`) and `IMG_PROMOTER_EXTENSION` (`containers/argocd-promoter-extension`), each with a build
  and a push line; the `cli` and `agentctl` images dropped (the CSV never deploys them, so `gitops/cli` and `gitops/agentctl` are no longer published); kube-rbac-proxy
  dropped (gitops-operator 1.22 has no `config/default/manager_auth_proxy_patch.yaml`, so the old `yq -i` on it would
  abort the build under `set -e`); redis pinned by digest; the cert-manager graph fix on the base CSV before
  `make bundle` (`olm.skipRange: >=1.0.0 <${OCP_DATE}`, `del(.spec.replaces)`, `del(.spec.skips)`); `make bundle` gets
  `OPERATOR_SDK=$(command -v operator-sdk)`, because the 1.22 Makefile otherwise downloads operator-sdk v1.35.0 into
  `bin/`. Three build args Red Hat's Konflux run passes and ours did not: `CI_ARGOCD_AGENT_COMMIT`,
  `CI_ROLLOUT_EXTENSION_VERSION`, `CI_GITOPS_PROMOTER_VERSION`.
- `gitops/env-override.yaml`: all fifteen variables above plus `ARGOCD_REPOSERVER_IMAGE` (Red Hat's CSV still sets it),
  the `RELATED_IMAGE_*` twins that make operator-sdk list each image in `spec.relatedImages`, and the route plugin path.
  `GITOPS_CONSOLE_PLUGIN_IMAGE_PF5` points at the PF6 plugin: the operator reads it only on a 4.18.x cluster, which no
  catalog this targets serves, and the PF5 plugin is not built.
- `gitops/patches/release.patch`, regenerated on a clean checkout of `6c4a911` with `git format-patch HEAD~1 --stdout`
  (the pipeline applies it with `git am -3`, so it has to be a mail-format patch, not a bare `git diff`). 11 files,
  19 insertions, 18 deletions:
  - every `FROM registry.redhat.io/rhel9/go-toolset:1.26` → `registry.access.redhat.com/ubi9/go-toolset:1.26` (11 lines in
    8 Containerfiles; corrected 2026-10-23, this said 12); that tag is Go 1.26.10 today (Red Hat catalog, 2026-10-22), above the 1.26.5 the operator and promoter
    `go.mod` files need;
  - the two `# TODO: switch to registry.redhat.io once the image is available` comments above those lines removed;
  - `containers/must-gather`: `FROM quay.io/openshift/origin-must-gather:latest` instead of `ose-must-gather-rhel9:v4.16.0`;
    `build.sh` still overrides it with `--from` the OKD payload's must-gather;
  - the pnpm installs. Red Hat's Argo CD UI and console plugin stages run `pnpm install --frozen-lockfile --offline` against
    a store Hermeto fills during Konflux prefetch; `containers/argocd/ui/.npmrc` is a placeholder
    (`# Placeholder; Hermeto inject-files overwrites this during prefetch.`). Outside Konflux that store is empty. I dropped
    `--offline` in both stages and made the `.npmrc` `registry=https://registry.npmjs.org/`. The lockfiles stay frozen:
    the Argo CD overlay lockfile resolves everything by integrity from the registry except `argo-ui`, which is a directory
    dependency on the `sources/argo-cd-ui-ref` submodule; the console plugin lockfile has no tarball or git sources at all.
    Same packages as Red Hat's build, fetched from the public registry instead of a prefetched store. Whether that works
    is proven only by the cluster build.

Compared with the Containerfiles Red Hat built 1.22.2 from (fetched by image digest), the only differences are the
lines above. The midstream Containerfiles at `6c4a911` are byte-identical to Red Hat's apart from a trailing newline, so
no Konflux, Hermeto or ART step lives in them; prefetch lives in the Tekton pipeline, which we do not use.

`sources/argo-cd-ui-ref`, which the Argo CD Containerfile copies, is not in the midstream `config.yaml`, but it is in its
`.gitmodules` with a gitlink at `6c4a911` (`c089d1d2`). `submodule_initialize` runs
`git submodule update --init --recursive release`, which initialises every submodule in `.gitmodules`, so it gets
fetched without a change to `init`.

### Redis and HAProxy, the two images we do not build

Redis: `build.sh` used the tag `quay.io/sclorg/redis-7-c9s:latest`. I resolved it through the quay API on 2026-10-22
17:04 UTC and pinned the digest:

```
latest sha256:d772acab11507231a2b152850f47c8b9b859dedb6652ca624949e97cb28c5e6f Wed, 08 Jan 2025 02:19:13 -0000 single
```

The same digest carries the tags `c9s` and `20250108`. The repository has not had a new image since 2025-01-08, and
`latest` is a single-arch manifest, not a list.

HAProxy: `build.sh` takes `haproxy-router` from the OKD release payload of the branch's `OKD_VERSION`, so it is always a
`quay.io/okd/scos-content@sha256:` digest. `oc adm release info` was not available to me, so I read
`release-manifests/image-references` from each payload through the registry API (layer digests verified). What each
branch resolves today:

| branch | OKD_VERSION | haproxy-router | must-gather (`--from`) |
|---|---|---|---|
| main | 5.0.0-okd-scos.0 | `sha256:3b780cf2f6350358655e1a9c5493d6c1f3f2ea806cc9af71d984b03abbabae6d` | `sha256:37760dbe598944231ad88bb9f6896e1d3e35ceb9949590758a61ef1ec1a2a252` |
| release-4.22 | 4.22.0-okd-scos.2 | `sha256:abe64e81007a722ca397c69c806e4083b85f075f0e60c3ab8d7859fc542f7a73` | `sha256:0834efd548122c7e717d5950e3a9f04182a18c8aaf2c008d7b3c17678c1a0abc` |
| release-4.21 | 4.21.0-okd-scos.10 | `sha256:51d9c27b00bc0a38d62ef1f0b0c187c64a704d4afd8bee0ff8526c425cbcff84` | `sha256:a743f7b460c92d4167293e1d53e593dd3ec5caed9dab6d362c66fab350a0afc0` |
| release-4.20 | 4.20.0-okd-scos.6 | `sha256:aa2c8730d15b20297f71426ff7bc9a0eae0ce86b328961a178110cbd3f72fd82` | `sha256:e1bcd28cdeefcdd002d99a01e0ffaba0dfffa0c04da3fb5d044e8d61bc00c73a` |

All four HAProxy digests answer `200` to an anonymous manifest `HEAD` on `quay.io/okd/scos-content`. A build from `main`
gets the 5.0 payload's HAProxy and must-gather base unless `OKD_VERSION` is overridden.

### The checks after the change

A script runs every check against the committed branch and, as a control, against `origin/main`. On the branch:
81 PASS, 0 FAIL. On `origin/main`: 37 FAIL (gitlink, branch, `MINOR`, patch apply, Red Hat FROM lines, `--offline`,
kube-rbac-proxy, missing build lines for argocd/promoter/promoter-extension, five missing variables). The decisive lines:

```
PASS gitlink HEAD:gitops/release = 6c4a911765610abf65a3344d16bafdeca0971e5a
PASS .gitmodules gitops/release branch = release-1.22
PASS git apply --check on fresh 6c4a911765610abf65a3344d16bafdeca0971e5a
PASS git am -3 on fresh 6c4a911765610abf65a3344d16bafdeca0971e5a
PASS registry.redhat.io count 0: containers/<each of the 12 Containerfiles build.sh uses>
PASS no 'pnpm install --offline' in argocd/console-plugin
PASS grep -c manager_auth_proxy_patch gitops/build.sh = 0
PASS build+push IMG_<each of the 12 images> <- containers/<dir>/Dockerfile
PASS env-override sets <each of the 15 variables> / OPENSHIFT_ROUTE_PLUGIN_LOCATION
PASS build_bundle yq edits run cleanly on gitops-operator cf32771
INFO base CSV: replaces=null skipRange=>=1.0.0 <1.22.0-2026-10-22-000000 displayName=OKD GitOps (ArgoCD)
```

The last two run `build_bundle`'s `yq` and `sed` edits on a copy of gitops-operator `cf32771` with dummy image names:
every target file exists, the manager env list grows from 5 to 36 entries with no empty value of ours and no duplicate name,
and the base CSV has no `replaces`.

Still unproven until the cluster build: that the UI stages install online, that `yum install -y cmake` works on the
public go-toolset image (the 1.19 build did the same on UBI and passed), and that `make bundle` carries the skipRange and
the missing `replaces` into the generated CSV (it does for cert-manager 1.20 with the same pattern).

## 2026-10-22 - gitops 1.22 backport to the release branches

Backported the reviewed `main` change (`gitops/` directory, the `gitops/release` gitlink at `6c4a911`, and the `.gitmodules` stanza moving `branch` to `release-1.22`) to three local branches cut from `origin/release-4.22`, `-4.21` and `-4.20`. I left out the `AGENTS.md` hunk because that file exists only on `main`.

```
git checkout -b gitops-1.22-4.21 origin/release-4.21
git checkout gitops-1.22 -- gitops/
git update-index --add --cacheinfo 160000,6c4a911765610abf65a3344d16bafdeca0971e5a,gitops/release
sed -i '' '/path = gitops\/release/,/branch =/ s/branch = release-1.19/branch = release-1.22/' .gitmodules
```

Workflows: `release-4.22` already had `gitops-deploy.yaml` but triggered on `main`, so it never fired from that branch; changed to `release-4.22`. `release-4.21` and `release-4.20` had none, so I added one in the shape of the nmstate deploy workflow (push to own branch with `paths: gitops/**`, `workflow_dispatch`, `operator: gitops`, `secrets: inherit`).

Per-branch checks: `git diff gitops-1.22 -- gitops/` empty, gitlink `6c4a911` on all three, `bash -n gitops/build.sh` ok, `yq e '.on, .jobs'` shows the right branch.

common.sh: diffed each branch against `main`. The functions gitops/build.sh calls (`get_payload_component`, `submodule_initialize`, `submodule_update`) are byte-identical; only `submodule_reset` differs on 4.21 (older nested foreach with `local`/`$path`) and 4.20 (also returns 1 on an uncommitted gitlink). Our gitlink is committed, so I expect no effect; MODE=check decides.

Found while reading `operator-deploy.yaml` on release-4.22: `catalog_branch` defaults to `release-4.21` and the deploy workflows do not override it.

Fix: the release-4.22 call now passes `catalog_branch: release-4.22` (declared input, default `release-4.21`), so a deploy from that branch opens its catalog PR against the 4.22 catalog branch. The 4.21 and 4.20 workflows have no catalog job, so they are unchanged.

## 2026-10-22: in-cluster full build results

Job `okd-build/gitops-build-full-2026-10-22-173433`: MODE=full, DATE `2026-10-22-173433`, `OKD_VERSION=4.21.0-okd-scos.10`,
fork branch `gitops-1.22` at `d4e1b0a`. Result: `RESULT PASS full 2026-10-22-173433`.

| Step | Start (UTC) | Duration | DISK after (bytes) |
|---|---|---|---|
| tools, podman-setup | 17:36:10 | 1 min | 37,158,289,408 (logging layers left on the PVC) |
| prune | 17:37:18 | 1 min | 7,532,003,328 |
| clone, tag-check | 17:38:13 | 0.5 min | 4,440,375,296 |
| init (submodules) | 17:38:42 | 3 min | 5,951,258,624 |
| build_containers | 17:41:54 | 87 min | 39,266,689,024 |
| push_containers, argocd-version, build_bundle, verify | 19:08:57 | 4 min | peak 41,159,110,656 |

Wall time 97 minutes, end 19:13:06Z, under `powersave-experimental`. `build_containers` is one step, so there is no
per-image time.

Pushed 13 refs, 1.27 GiB in total, all under `zot.apps.okd.sudops.pl/okd-test/gitops/` with tag
`1.22.0-2026-10-22-173433`: `agent`, `argocd`, `backend`, `console-plugin`, `dex`, `extensions`, `image-updater`,
`must-gather`, `operator`, `promoter`, `promoter-extension`, `rollouts`, and the bundle
`operator-bundle@sha256:bf349fbe541d91ad55c9073c3fe16597b52679d121115a19c83049dc7bba973a`.

`verify` checks, all PASS:

```
CHECK argocd-version PASS v3.5.5 from zot.apps.okd.sudops.pl/okd-test/gitops/argocd:1.22.0-2026-10-22-173433
CHECK csv/gitops-operator PASS gitops-operator.v1.22.0-2026-10-22-173433 1.22.0-2026-10-22-173433
CHECK no-redhat-registry/gitops-operator PASS no registry.redhat.io, registry-proxy.engineering.redhat.com or brew.registry reference in the CSV
CHECK skip-range/gitops-operator PASS >=1.0.0 <1.22.0-2026-10-22-173433
CHECK no-replaces/gitops-operator PASS spec.replaces is not set
CHECK max-openshift-version/gitops-operator PASS none (reported: the pipeline does not set it for gitops; the 1.19 bundle in the catalog has none)
CHECK images/gitops-operator PASS 44 refs, all zot.apps.okd.sudops.pl/okd-test/...@sha256 or an external image of gitops/build.sh
CHECK images-built/gitops-operator PASS every zot.apps.okd.sudops.pl/okd-test ref is a digest this run pushed
CHECK external-images/gitops-operator PASS quay.io/okd/scos-content@sha256:51d9c27b… quay.io/sclorg/redis-7-c9s@sha256:d772acab…
CHECK branding/gitops-operator PASS no valid-subscription, support not Red Hat; 0 text lines mention Red Hat (reported, not failed): none
CHECK provider/gitops-operator PASS OKD Community
```

zot `data-zot-0`: 15.96 GiB free before the build, 16.84 GiB after (kubelet stats summary, read about 19:15Z). The
pull-through cache moves more than the 1.27 GiB this build pushed, so the before/after pair does not isolate it.

**Peak disk is over the hosted-runner line.** Peak `DISK` is 41.2 GB (38.3 GiB), measured after an unconditional
prune, so it approximates a fresh runner; the design's stop rule is ~14 GB free on an `ubuntu-latest` runner.
`build_containers` alone added 33.3 GB (5.95 → 39.27 GB) for twelve images. Per the plan I stopped here: filing the
pipeline PRs waits on the operator's decision on the CI disk question.

Not covered by this run: `operator-sdk bundle validate`. The tool is installed in the Job (v1.36.1), but the pod log has
no validate output, so the plan's Step 3 item is still open.

## 2026-10-22: CI disk decision

The 41.2 GB peak is about three times what an `ubuntu-latest` runner has free. Logging hit the same limit at 37.0 GB, and
its answer, an opt-in `free_disk_space` input, exists only in the unmerged #35 on `main`; nobody has measured whether it
frees enough for 41 GB. Decision: file the GitOps pipeline PRs without a workflow change and without depending on #35.
The PR body states the peak, the per-step figures and the runner limit, and the maintainers choose the remedy (larger
runner, self-hosted runner, or a disk step).

## 2026-10-22: bundle content check and `operator-sdk bundle validate`

The Job's `verify` did not run `operator-sdk bundle validate`, so I ran both remaining Task 4 checks from the Mac
against the pushed bundle. opm v1.74.0 refuses a `repo:tag@sha256:` reference ("Docker references with both a tag and
digest are currently not supported"), so the reference is digest-only.

```
opm render zot.apps.okd.sudops.pl/okd-test/gitops/operator-bundle@sha256:bf349fbe541d91ad55c9073c3fe16597b52679d121115a19c83049dc7bba973a -o json
```

| Check | Result |
|---|---|
| CSV name | `gitops-operator.v1.22.0-2026-10-22-173433` |
| `olm.skipRange` | `>=1.0.0 <1.22.0-2026-10-22-173433` |
| `spec.replaces` | unset |
| `provider.name` | `OKD Community` |
| image refs (`relatedImages`, container images, 29 `*_IMAGE`/`RELATED_IMAGE_*` env values) | 15 distinct, all by digest: 13 under `zot.apps.okd.sudops.pl/okd-test/gitops/`, plus `quay.io/okd/scos-content@sha256:51d9c27b…` (HAProxy from the OKD payload) and `quay.io/sclorg/redis-7-c9s@sha256:d772acab…` (Redis), both public, reasons above |
| `kube-rbac-proxy` | none |
| `registry.redhat.io` anywhere in the rendered bundle | 0 |

```
operator-sdk bundle validate zot.apps.okd.sudops.pl/okd-test/gitops/operator-bundle@sha256:bf349fbe… -b none
level=info msg="All validation tests have completed successfully"
```

operator-sdk v1.36.1 (the Job's version, darwin/arm64 release binary, checksum verified). 21 warnings: 20 "provided API
should have an example annotation" (promoter and rollouts CRDs) and one "csv.Spec.minKubeVersion is not informed".
None is an error.

## 2026-10-22: catalog graphs validated and the test catalog image

Before the edit, on all three upstream catalog branches the `alpha` channel is the chain
`v1.13.0-2024-08-09-135916` → `v1.16.0-2025-06-04-121801` → `v1.19.0-2026-02-07-151505` (head), and the homelab
Subscription is `AtLatestKnown` on that head.

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S); echo $DATE      # 2026-10-22-194508
oc process --local -f tests/okderators-gitops-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.20 release-4.21 release-4.22' \
  -p BUNDLES='zot.apps.okd.sudops.pl/okd-test/gitops/operator-bundle:1.22.0-2026-10-22-173433@sha256:bf349fbe541d91ad55c9073c3fe16597b52679d121115a19c83049dc7bba973a' \
  | oc -n okd-build create -f -
```

The pod sat in `CreateContainerError: context deadline exceeded` twice on node5 (19:47:13Z, then `RST_STREAM ... CANCEL`
at 19:49:14Z) and started on kubelet's third attempt at 19:49:29Z, about four minutes after scheduling. The full-build
pod at 17:35Z started in about a minute. I have no node-log access, so the cause is open. The run itself took 3 minutes.

Result `RESULT PASS catalog 2026-10-22-194508`. Per branch (4.20 shown; 4.21 and 4.22 are identical):

```
CHECK edit-release-4.20 PASS gitops-operator.v1.22.0-2026-10-22-173433 replaces gitops-operator.v1.19.0-2026-02-07-151505, skipRange '>=1.19.0-0 <1.22.0-2026-10-22-173433' (+3 lines)
CHECK opm-validate-release-4.20 PASS opm validate catalog
CHECK walk-release-4.20 PASS 4 entries reach gitops-operator.v1.22.0-2026-10-22-173433; hops 1.13.0-2024-08-09-135916 -> 1.16.0-2025-06-04-121801 -> 1.19.0-2026-02-07-151505 -> 1.22.0-2026-10-22-173433
CHECK negative-control-release-4.20 PASS opm validate failed as expected without the channel entry: ... bundle "gitops-operator.v1.22.0-2026-10-22-173433" not found in any channel entries
CHECK negative-control-skiprange-release-4.20 PASS with skipRange '>=1.0.0 <1.22.0-2026-10-22-173433' opm validate passes and the walker fails: hop from gitops-operator.v1.13.0-2024-08-09-135916 goes to gitops-operator.v1.16.0-2025-06-04-121801, gitops-operator.v1.22.0-2026-10-22-173433, ...
```

The second negative control is the reason the catalog entry's skipRange starts at `1.19.0-0`: with the CSV's own
`>=1.0.0` range in the channel entry, `opm validate` still passes but a 1.13 install would be offered a direct jump to
1.22 (Argo CD 2.x to 3.5). The walker catches that; `opm validate` does not.

Test catalog image, from the edited `release-4.21` tree with package `gitops-operator` only, rendered back from zot
with the one head and the same walk:

```
CHECK catalog-image PASS zot.apps.okd.sudops.pl/okd-test/gitops-catalog:2026-10-22-194508: package gitops-operator; head gitops-operator.v1.22.0-2026-10-22-173433; every entry and gitops-operator.v1.19.0-2026-02-07-151505 reach the head
PUSHED zot.apps.okd.sudops.pl/okd-test/gitops-catalog:2026-10-22-194508@sha256:695277834f9911e47d657c27e79bb022442677d8b391feaf1ceb9c720c1fcd7b 33587446
```

## 2026-10-22: the GitOps 1.22 test CatalogSource

`components/operators/gitops-test-catalog/` mirrors `logging-test-catalog`: one CatalogSource `okd-test-gitops` in
`openshift-marketplace`, `sourceType: grpc`, image pinned by digest
(`zot.apps.okd.sudops.pl/okd-test/gitops-catalog@sha256:695277834f9911e47d657c27e79bb022442677d8b391feaf1ceb9c720c1fcd7b`),
no `updateStrategy`. Root-app entry `gitops-test-catalog`, wave 1. Nothing subscribes to it yet: the gitops-operator
Subscription still points at `okderators` until the phase0 `02` change.

Validation: `helm lint` clean; `helm template` renders the one CatalogSource; kubeconform `Valid: 1`; the root app
renders 49 child Applications (48 before). `oc diff` cannot run: the readonly SA has no create permission for the
server-side dry run, and the object does not exist live (`NotFound`), so the diff is the whole object.

Commit B: `bootstrap/phase0/02_gitops_operator.yaml` `source: okderators` → `okd-test-gitops` (comment says why and until when; the old comment's "cert-manager 1.19.0 recovery" meant the GitOps 1.19.0 recovery). `bootstrap/phase0/readme.md`: Step 3 and the recovery step now apply the file through `sed 's/source: okd-test-gitops/source: okderators/'`, because the test CatalogSource only exists once ArgoCD runs and the recovery target 1.19.0 belongs to `okderators`.

## 2026-10-22: live upgrade of this cluster, 1.19.0 → 1.22

Test CatalogSource first (`136820c`): app `gitops-test-catalog` Synced/Healthy, CatalogSource `okd-test-gitops` `READY`
at 19:59Z, packagemanifest `gitops-operator` from it with `alpha=gitops-operator.v1.22.0-2026-10-22-173433`. The
Subscription stayed `AtLatestKnown` on `okderators` with no new InstallPlan.

Then the Subscription source (`24114e3`), applied by the operator:

```
oc apply -f bootstrap/phase0/02_gitops_operator.yaml
subscription.operators.coreos.com/gitops-operator configured
```

OLM created one InstallPlan, which proves the edge from the installed 1.19.0:

```
install-2wsdj  approved=false  RequiresApproval  ["gitops-operator.v1.22.0-2026-10-22-173433"]
bundle: zot.apps.okd.sudops.pl/okd-test/gitops/operator-bundle@sha256:bf349fbe… (catalog okd-test-gitops)
```

42 steps: 28 CRDs, the CSV, ClusterRole/ClusterRoleBinding, two Role/RoleBinding pairs, two Services, a
ServiceAccount, a ServiceMonitor, two ConfigMaps and the bundle secret. No conditions, no failed bundle lookup. Against
the 1.19.0 CSV's owned CRDs: all 14 updated in place, none dropped, 14 new `promoter.argoproj.io` CRDs (GitOps
Promoter, unused here).

Baseline before approval: 50 apps Synced/Healthy, 8 `openshift-gitops` pods Running, CephCluster override in the CR,
server image `quay.io/okderators/gitops/argocd@sha256:f2ce883860c9…`.

The operator approved through the console at 20:55Z. Timeline (readonly watcher, 30 s polls):

```
20:55:52 ip[true/Installing] csv[Pending/RequirementsNotMet] old[Replacing]
20:56:15 csv Installing/InstallWaiting: waiting for deployment openshift-gitops-operator-controller-manager ... 1 outdated replica(s) to be terminated
20:57:25 ip[true/Complete] csv[Succeeded/InstallSucceeded] old[] pods_notready=4
20:58:27 csv[Succeeded/InstallSucceeded] pods_notready=0 containers_not_new_image=0
```

All eight `openshift-gitops` pods were recreated between 20:56:49Z and 20:56:55Z on the zot images; 0 restarts.

Checks after the upgrade:

| Check | Result |
|---|---|
| `GET /api/version` through the route | `v3.5.5+a5038b0` |
| Applications | 50/50 Synced/Healthy; all 50 reconciled after 20:57Z, no conditions |
| CephCluster override | in the ArgoCD CR and `argocd-cm` (30 lines); `rook-ceph-cluster` reports CephCluster `Healthy` "HEALTH_WARN: BLUESTORE_SLOW_OP_ALERT, MON_DISK_LOW" |
| Logs, 10 min | server and application-controller: no `level=error`; Dex: one `failed to get signing algorithm: no signing key found` at 20:58:07Z, keys rotated at 20:58:08Z, nothing since |
| NetworkPolicies (new in 1.20+) | seven, all `Ingress`-only (application-controller, applicationset-controller, dex, redis, redis-ha, repo-server, server); router → server works (the version call above), repo-server serves the controller, egress to github.com untouched |
| Prometheus | `up{namespace="openshift-gitops"}` = 1 for server, repo-server and application-controller |
| Alerts | 9 firing, the same set as since 10-16; none new |

The repo-server logged three `level=error` lines right after start, one each for `immich`, `rook-ceph-operator` and
`nfs-csi`, the three charts with external dependencies:

```
helm template . --name-template immich ... failed exit status 1: Error: an error occurred while checking for chart dependencies.
You may need to run 'helm dependency build' to fetch missing dependencies: found in Chart.yaml, but missing in charts/ directory: immich
```

Each is followed by the repo-server's own fallback: `helm repo add https:--charts.rook.io-release https://charts.rook.io/release`,
then `helm dependency build` (immich, OCI, 2.8 s; rook-ceph 1.5 s), then a successful render. All three apps are
Synced/Healthy at `24114e3` with no conditions. The new repo-server started with an empty cache, so every chart
rendered fresh under Helm 4.2.4, including the OCI dependency the design flagged.

Still to do: an OpenShift login to the Argo CD UI and the console plugin (operator), the hourly `rook-ceph-cluster`
multi-wave sync under 3.5, and the 24 h soak.

Login and console plugin, after the upgrade: the operator logged in to the Argo CD UI through "Log in via OpenShift"
and reports it fine. Dex agrees: `{"level":"INFO","msg":"login successful","connector_id":"openshift",...}` at
20:58:13Z, through the Dex image this build made. The GitOps console plugin cannot be exercised here: ConsolePlugin
`gitops-plugin` exists and its pod runs the zot `console-plugin` image with 0 restarts, but the console operator's
`spec.plugins` lists only `monitoring-plugin`, `networking-console-plugin` and `nmstate-console-plugin`, and the console
already reported `gitops: disabled` at 20:35Z, before the upgrade. Enabling it is a cluster-wide console change, so
it stays as it was.

End to end: `516c730` (the docs commit) reached all 50 apps, Synced/Healthy, at 21:03:29Z, about a minute after the
push.

First multi-wave `rook-ceph-cluster` sync under Argo CD 3.5.5, triggered by the hourly TTL clean-up of its four
bootstrap Jobs:

```
operationState: Succeeded 2026-10-22T21:20:51Z -> 2026-10-22T21:21:14Z "successfully synced (all tasks run)"
rbd-trash-purge-schedule-bootstrap      completed 21:21:08Z
mgr-pool-crush-rule-bootstrap           completed 21:21:12Z
csi-rbd-provisioner-caps-fix-bootstrap  completed 21:21:13Z
pg-num-floor-bootstrap                  completed 21:21:21Z
CephCluster health: Healthy "HEALTH_WARN: BLUESTORE_SLOW_OP_ALERT, MON_DISK_LOW"
```

Without the override (Task 7) the CephCluster would have read Degraded and this sync would have stopped before the
wave-10/11 Jobs. Task 8 is done; the 24 h soak runs from 20:57Z to 2026-10-23 20:57Z.

## 2026-10-22: release-branch checks (MODE=check)

One `check` run per backport branch, against the full run's images (`DATE=2026-10-22-173433`) and without
`OKD_VERSION`, so each branch uses its own payload default. The three runs share the Job name
`gitops-build-check-2026-10-22-173433` and the PVC lock, so they ran one after another with the Job deleted in between:

```bash
oc -n okd-build delete job gitops-build-check-2026-10-22-173433      # before the 2nd and 3rd run
oc process --local -f tests/okderators-gitops-build/job-template.yaml \
  -p MODE=check -p DATE=2026-10-22-173433 -p PIPELINE_BRANCH=gitops-1.22-4.22 \
  | oc -n okd-build create -f -
```

| Branch | Result | Time | Bundle under `okd-test/check-<branch>/gitops/` | HAProxy (`quay.io/okd/scos-content`) |
|---|---|---|---|---|
| `gitops-1.22-4.22` | PASS, 10/10 CHECK | 7 min | `operator-bundle@sha256:47d8638e3725…` | `@sha256:abe64e81…` (4.22 payload) |
| `gitops-1.22-4.21` | PASS, 10/10 CHECK | 8 min | `operator-bundle@sha256:180d3b355333…` | `@sha256:51d9c27b…` (4.21 payload, same as the full run) |
| `gitops-1.22-4.20` | PASS, 10/10 CHECK | 7 min | `operator-bundle@sha256:703f2639f065…` | `@sha256:aa2c8730…` (4.20 payload) |

The ten checks are the full run's verify set: CSV name, no Red Hat registry, exact skipRange, no `replaces`,
`maxOpenShiftVersion` (none), images by digest, images built by this run, external images, branding, provider. The
one per-branch difference is the HAProxy digest, which `build.sh` reads from each branch's OKD payload. The older
`submodule_reset` on 4.20 and 4.21 made no difference, as expected from the committed gitlink.

zot: 16.07 GiB free after the three runs, 0.77 GiB less than after the full build (that includes the catalog image and
the pull-through cache). Each check run's 13 refs are `skopeo copy` of blobs already in zot, so the copies cost little.
As with logging (ruling P24 there), the `check-*` repos stay until the final clean-up of all `okd-test/gitops*` images.

## 2026-10-23: 24 h soak — PASS

Checked at 20:58Z, 24 h after the upgrade (20:57Z on 10-22). All reads were made with the readonly kubeconfig. The
alert list came from Alertmanager through the break-glass kubeconfig.

```bash
oc -n openshift-gitops get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} r={.status.containerStatuses[*].restartCount}{"\n"}{end}'
oc -n openshift-gitops get applications -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status} {.status.sync.revision}{"\n"}{end}'
oc -n openshift-gitops logs openshift-gitops-application-controller-0 --since-time=2026-10-22T20:57:00Z \
  | grep 'rook-ceph-cluster' | grep -oE '(Partial )?[Ss]ync operation to [0-9a-f]+ (succeeded|failed)'
```

| Check | Result |
|---|---|
| CSV / Subscription | `gitops-operator.v1.22.0-2026-10-22-173433` `Succeeded`; Subscription on `okd-test-gitops`, `Manual`, `AtLatestKnown` |
| ArgoCD CR | `phase=Available`, server `Running`; server reports `version=v3.5.5+a5038b0` |
| Restarts | 0 on all 8 `openshift-gitops` pods and the operator pod in `openshift-operators`, all started 20:56:39-20:56:55Z on 10-22 |
| Applications | 50/50 Synced/Healthy, all at `047f1db` (pushed 10-23, so commits sync end to end) |
| `rook-ceph-cluster` | 79 sync operations in 24 h, 79 `succeeded`, 0 `failed`; the history adds an entry only when the revision changes (2 since the upgrade), so the controller log is the count |
| Controller log | 183,248 lines, 0 `level=error`, 0 failed syncs |
| Other components | repo-server, applicationset-controller and redis: no error lines; server: 5 lines and Dex: 1, all at 20:58:03-20:58:07Z on 10-22 (a browser session token checked before Dex had a signing key; the startup transient already noted above), nothing since |
| CephCluster override | still in the ArgoCD CR (`resourceHealthChecks` kind `CephCluster`) and in `argocd-cm` |
| NetworkPolicies | the same seven |
| Cluster sweep | 3/3 nodes Ready; CV 4.21.0-okd-scos.11 Available, not Progressing or Failing; no ClusterOperator off True/False/False; every CSV `Succeeded`; every Certificate Ready; no non-running or waiting pods; no container terminated since 16:00Z; CNPG 2/2 and archiving on both clusters; Ceph `HEALTH_WARN` with the standing `BLUESTORE_SLOW_OP_ALERT` + `MON_DISK_LOW`; LokiStack Ready |
| Alerts | 10 firing: the 9 standing since 10-16, plus `TrueNASPoolScrubOverdue` from 19:40Z (below) |

The only warning in the controller log repeats about once an hour: `DiffFromCache: cannot get managed resources for
app oadp: cache: key is missing`, with `Failed to get cached managed resources for tree reconciliation, fall back to
full reconciliation`. That is 17 in 24 h. `oadp` stays Synced/Healthy and reconciles as often as the other apps. The previous
controller's logs went with its pod, so I checked Loki (`Loki (infrastructure)` datasource in Grafana, 3-day
retention, range 2026-10-20 19:00Z to now; run by the operator):

```
{kubernetes_namespace_name="openshift-gitops"} |= "DiffFromCache"
{kubernetes_namespace_name="openshift-gitops"} |= "DiffFromCache" != "oadp"
```

The first query shows the same hourly warning through 10-21 and 10-22, on Argo CD 3.1 before the upgrade. The
second returns no lines (9.45 GB scanned), so every one of these warnings names `oadp`. It predates 1.22 and is not
a soak finding. Why only `oadp` loses its cache key is still open.

`TrueNASPoolScrubOverdue` is not related to GitOps. Pool `tank` was last scrubbed at 2026-09-08 18:41Z
(`truenas_zpool_scrub_age_seconds` = 45.10 days), and the 2026-10-01 run was skipped by the 35-day threshold
(`blog-truenas-migration-draft.md`, 2026-10-11). The next scheduled scrub is 2026-11-01, 54 days after the last, so the
45-day alert was expected to fire in this gap.

Soak passed; Task 10 (draft pipeline PRs) is unblocked.

## 2026-10-23: pipeline PRs filed (drafts)

| PR | Base ← head | Head |
|---|---|---|
| [#39](https://github.com/okd-project/okd-operator-pipeline/pull/39) `[gitops] Update to 1.22` | `main` ← `gitops-1.22` | `d4e1b0a` |
| [#40](https://github.com/okd-project/okd-operator-pipeline/pull/40) `[gitops] Update to 1.22 (release-4.22)` | `release-4.22` ← `gitops-1.22-4.22` | `2662789` |
| [#41](https://github.com/okd-project/okd-operator-pipeline/pull/41) `[gitops] Update to 1.22 (release-4.21)` | `release-4.21` ← `gitops-1.22-4.21` | `fa92259` |
| [#42](https://github.com/okd-project/okd-operator-pipeline/pull/42) `[gitops] Update to 1.22 (release-4.20)` | `release-4.20` ← `gitops-1.22-4.20` | `90c088a` |

#39 carries the argument: why 1.22 (Argo CD 3.1 is tested to Kube 1.34; OKD 4.22 is 1.35), the changes, five
points for review (PF5 plugin variable, redis by digest, online pnpm, the Rollouts route plugin path, the weekly
update moving the gitlink past 1.22.2), CI disk (41.2 GB peak against about 14 GB on `ubuntu-latest`; no workflow
change, per the 10-22 decision), and the verification summary. The backports are three lines each.

The first draft was about 1,400 words for `main`. The operator asked for it plainer, so it was rewritten to about 475
words. The CHECK output, the disk table, the image list and diff-visible details were dropped.

Checking the drafts turned up one thing the plan had not accounted for. Merging #39 or #40 makes the deploy workflow
open a catalog-index PR by itself: `operator-deploy.yaml` defaults to `update_catalog: true`, `main` targets
`release-5.0` and #40 targets `release-4.22`. `scripts/update-catalog-package.sh:81` writes that entry with `replaces`
only. So Task 11 becomes a follow-up on those bot PRs that adds `skipRange: '>=1.19.0-0 <…'` (the same "keep the bot"
shape as NMState), plus catalog PRs by hand for `release-4.21` and `release-4.20`, whose `operator-deploy.yaml` has no
catalog job. #39 says this under "Catalog".
