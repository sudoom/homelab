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
