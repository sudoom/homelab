# oadp-operator

OADP (OpenShift API for Data Protection: Velero, the node agent and the data mover) installed by OLM. The operands
are configured by the sibling chart `components/cluster-config/oadp/` (DPA `dpa`, BSL `truenas-garage` on garage at
`https://s3.homelab.sudops.pl`, Schedule `daily`, which stays `paused: true`). This chart only installs the operator, so
everything here is about the Subscription: where it reads from, which CSV it runs, and how to move it.

**Status 2026-11-03:** the cluster runs the okderators 1.6 test build, CSV `oadp-operator.v1.6.0-2026-11-02-205027` from
the test catalog `okd-test-oadp`, since 2026-11-03 08:00Z (InstallPlan `install-zqssm`, approved by hand;
`installPlanApproval: Manual`). It replaced `oadp-operator.v1.5.0-2026-01-05-165341` from `okderators`
(InstallPlan `install-fj9jr`). The plan and results are in `blog/blog-okderators-oadp-1.6-draft.md`.

## What the chart installs

root-app entry `oadp-operator`, wave 1, destination namespace `openshift-adp`.

| Object | Wave | Notes |
|---|---|---|
| Namespace `openshift-adp` | 0 | |
| OperatorGroup `openshift-adp` | 0 | `targetNamespaces: [openshift-adp]`, OwnNamespace (the only install mode OADP supports) |
| Subscription `oadp-operator` | 1 | channel `alpha`; `source`, `sourceNamespace` in `values.yaml`; `installPlanApproval: Manual` |

The DPA, BSL credentials and the Schedule come from the `oadp` root-app entry (`components/cluster-config/oadp/`).
Velero, the node agent and the data mover are rendered by the operator from the DPA.

## Rules

- **Never set `enabled: false` on `oadp-operator` or `oadp`** in `bootstrap/root-app/values.yaml`. The
  resources-finalizer would cascade-delete the Namespace, the DPA and everything in it.
- **Keep `installPlanApproval: Manual`.** The `okderators` catalog tag moves per OKD minor and an Automatic
  Subscription upgrades unattended (all five okderators operators at once, including GitOps).
- **Never un-pause Schedule `daily`** as part of any of this. Nothing here changes the DPA or the Schedule.
- **A change to the Subscription is a commit to `master`.** ArgoCD selfHeal recreates a Subscription deleted by hand
  from git and reverts a hand edit of its spec.
- **Interim on zot:** while the Subscription reads from `okd-test-oadp`, the operator, Velero, node-agent and
  download-server images exist only in zot `okd-test/oadp/`. During a zot outage a rescheduled pod on a node without
  the image cached cannot start; backups wait.

## What `startingCSV` does and does not do

Read in `pkg/controller/registry/resolver/resolver.go` (`operator-framework/operator-lifecycle-manager` master
`861a2c9f` and `openshift/operator-framework-olm` branch `release-4.22`, the same logic in both):

- The resolver looks up the installed CSV by `Subscription.status.installedCSV` among the CSVs in the namespace. If
  one is found (`current != nil`), it filters the channel to entries that skip from it (`skipRange`) or list it in
  `replaces`; `startingCSV` is **ignored**. The upgrade below is therefore driven by the `replaces` edge in the
  catalog entry, not by `startingCSV`.
- Only when no installed CSV matches (`current == nil`) is the channel filtered by `CSVNamePredicate(startingCSV)`.
  That is the fresh-install case, and the case after the installed CSV has been deleted: the rollback relies on it.
- With `current == nil` and no entry of that name in the channel, the Subscription reports `no operators found with
  name <startingCSV> in channel alpha of package oadp-operator ...`.

Confirmed in source only. Not yet observed on this cluster: that a deleted CSV leaves `status.installedCSV` pointing
at nothing the lookup finds (it must, for the rollback to resolve), and that the 1.6 CSV deletion leaves the CRDs
in place. Check both during the rollback, step by step.

## Upgrade: okderators 1.5 to the 1.6 test build

Everything marked `# OPERATOR` is run with the operator's own `oc login`; every other command is a read under the
readonly SA. Do not start before the drill on 1.5 passed (`tests/oadp-1.6-drill/README.md`).

```bash
ocr() { KUBECONFIG=~/.kube/config-readonly oc "$@"; }
SCR=~/oadp-1.6-upgrade           # durable, outside the repo; holds the "before" captures
mkdir -p "$SCR"
```

**1. Gates (readonly).** All must hold; `drill-15` expiry is at least 24 h away.

```bash
ocr -n openshift-adp get dpa dpa -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}{"\n"}'   # True
ocr -n openshift-adp get bsl truenas-garage -o jsonpath='{.status.phase} {.status.lastValidationTime}{"\n"}' # Available
ocr -n openshift-adp get schedules.velero.io daily -o jsonpath='{.spec.paused}{"\n"}'                       # true
ocr -n openshift-adp get backups.velero.io drill-15 -o jsonpath='{.status.phase} {.status.expiration}{"\n"}' # Completed
ocr -n openshift-marketplace get catalogsource okd-test-oadp -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'  # READY
ocr get packagemanifests -l catalog=okd-test-oadp -o jsonpath='{range .items[*].status.channels[*]}{.name} {.currentCSV}{"\n"}{end}'   # alpha oadp-operator.v1.6.0-2026-11-02-205027
ocr -n openshift-adp get dpa dpa -o yaml > "$SCR/dpa-before.yaml"        # saved for the post-upgrade diff
ocr -n openshift-adp get networkpolicies -o name > "$SCR/netpol-before.txt"
```

`oc get packagemanifest oadp-operator` without the label selector returns the `community-operators` entry of the same
name on this cluster; always select by `catalog=okd-test-oadp`.

**2. The commit.** In `components/operators/oadp/values.yaml` set `source: okd-test-oadp` and
`startingCSV: oadp-operator.v1.6.0-2026-11-02-205027` (the template renders a `startingCSV` line only when the value is set; `installPlanApproval`
stays `Manual`). Commit `oadp: move to the okderators 1.6 test build`, push. The Subscription resolves and OLM
generates an InstallPlan with `approved: false`.

```bash
ocr -n openshift-adp get subscription oadp-operator -o jsonpath='{.status.state} {.status.installPlanRef.name}{"\n"}'
ocr -n openshift-adp get installplan -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames,APPROVED:.spec.approved,PHASE:.status.phase
# select the plan by the CSV it installs: status.installPlanRef can still name an older, Complete plan
IP=$(ocr -n openshift-adp get installplan -o jsonpath='{range .items[?(@.spec.clusterServiceVersionNames[0]=="oadp-operator.v1.6.0-2026-11-02-205027")]}{.metadata.name}{"\n"}{end}')
echo "$IP"                                                      # exactly one name
ocr -n openshift-adp get installplan "$IP" -o jsonpath='{range .status.plan[*]}{.resolving} {.resource.kind} {.resource.name} {.status}{"\n"}{end}'
```

Read the plan before approving: the CSV, the updated CRDs, the two new CRDs, RBAC. No CRD version may be removed:
record `storedVersions` of every `velero.io` and `oadp.openshift.io` CRD now and compare after.

```bash
ocr get crd -o jsonpath='{range .items[?(@.spec.group=="velero.io")]}{.metadata.name} {.status.storedVersions}{"\n"}{end}' > "$SCR/crd-versions-before.txt"
ocr get crd -o jsonpath='{range .items[?(@.spec.group=="oadp.openshift.io")]}{.metadata.name} {.status.storedVersions}{"\n"}{end}' >> "$SCR/crd-versions-before.txt"
```

**3. Approve (OPERATOR).**

```bash
oc -n openshift-adp patch installplan "$IP" --type merge -p '{"spec":{"approved":true}}'    # OPERATOR
```

**4. Checks (readonly).**

```bash
ocr -n openshift-adp get csv                                  # 1.6 Succeeded, 1.5 gone
ocr -n openshift-adp get dpa dpa -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}{"\n"}'   # True (the diff below ignores .status)
STRIP='del(.status, .metadata.resourceVersion, .metadata.generation, .metadata.managedFields)'
diff <(yq "$STRIP" "$SCR/dpa-before.yaml") <(ocr -n openshift-adp get dpa dpa -o yaml | yq "$STRIP")   # spec unchanged
ocr -n openshift-adp get bsl truenas-garage -o jsonpath='{.status.phase} {.status.lastValidationTime}{"\n"}'   # Available, fresh
ocr -n openshift-adp get pods -o custom-columns='NAME:.metadata.name,IMAGES:.spec.containers[*].image,INIT:.spec.initContainers[*].image,READY:.status.containerStatuses[*].ready'
ocr -n openshift-adp get networkpolicies -o name      # 1.5 had none; the five 1.6 creates are owned by the DPA; record them
ocr get crd -o jsonpath='{range .items[?(@.spec.group=="velero.io")]}{.metadata.name} {.status.storedVersions}{"\n"}{end}'   # same storedVersions as the blog's pre-upgrade CRD baseline
```

Every operator, Velero and node-agent image must be under `zot.apps.okd.sudops.pl/okd-test/oadp/` by digest. 1.6
also creates two download servers at operator start (`console-cli-download`, `vmdp-cli-download`) when the
`ConsoleCLIDownload` CRD exists, whether or not KubeVirt does: for each a Deployment, Service and Route owned by the
operator Deployment, plus a cluster-scoped `ConsoleCLIDownload` with no owner. Record their names (confirmed at the 2026-11-03 upgrade: `openshift-adp-oadp-cli` and `openshift-adp-oadp-vmdp`); the
rollback deletes the `ConsoleCLIDownload`s by hand.

```bash
ocr -n openshift-adp get deploy,svc,route
ocr get consoleclidownload                                   # new entries since the upgrade
```

Each Route (`oadp-cli-server-route`, `oadp-vmdp-server-route`) must be admitted and serve one archive with HTTP 200.
The `ConsoleCLIDownload` link points at the Route root (`https://<host>/`, `cli_download_controller.go:305`), which
the server answers with its archive listing; fetch one file named in it. The fetch runs from the operator's shell
(OPERATOR, a network read of our own Route; the listing, confirmed 2026-11-03, has `href="/static/style.css"` first, then the GitHub repo link, then the `href="/download/<file>"` links, so the loop selects the first `/download/` link).

```bash
for r in oadp-cli-server-route oadp-vmdp-server-route; do
  H=$(ocr -n openshift-adp get route $r -o jsonpath='{.spec.host}')
  echo "$r $H admitted=$(ocr -n openshift-adp get route $r -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}')"
  F=$(curl -sk "https://$H/" | grep -o 'href="/download/[^"]*"' | head -1 | cut -d'"' -f2)       # OPERATOR; first archive in the listing (not the stylesheet)
  if [ -z "$F" ]; then echo "  FAIL: no archive found in the listing at https://$H/"; continue; fi   # an empty name would fetch the root, which is 200
  echo "  archive=$F http=$(curl -sk -o /dev/null -w '%{http_code}' "https://$H$F")"                  # OPERATOR; want 200
done
```

**5. Drill.** `tests/oadp-1.6-drill/README.md`, run 2. If any step above or the drill fails, stop; fix forward if the
cause is clear, otherwise roll back.

## Rollback: 1.6 test build back to okderators 1.5

Every step is operator-run and goes in the blog draft as it happens. Low stakes while `daily` is paused and nothing
else is backed up. The order is load-bearing.

**1. Commit the revert first (OPERATOR, a `master` commit).** `source: okderators` and
`startingCSV: oadp-operator.v1.5.0-2026-01-05-165341`; `installPlanApproval` stays `Manual`. Push and let ArgoCD
sync `oadp-operator`. This comes first because selfHeal recreates a Subscription deleted by hand from git: deleting
before the commit would bring the 1.6 Subscription straight back. Expect the Subscription to report a resolution
condition or nothing while the 1.6 CSV is still installed (the okderators catalog has no entry that replaces it);
that is fine and changes nothing.

**2. Delete the 1.6 CSV (OPERATOR).**

```bash
oc -n openshift-adp delete csv oadp-operator.v1.6.0-2026-11-02-205027      # OPERATOR
```

With no installed CSV matching `status.installedCSV`, the resolver honours `startingCSV` and OLM generates an
InstallPlan for `oadp-operator.v1.5.0-2026-01-05-165341` from `okderators`. Deleting the CSV removes the operator
Deployment and, through it, the download servers' Deployments, Services and Routes. The CRDs stay (to be confirmed
here, see above); Velero, node-agent and the DPA are not owned by the CSV and keep running until the 1.5 operator
reconciles them.

```bash
ocr -n openshift-adp get subscription oadp-operator -o jsonpath='{.status.state} {.status.installPlanRef.name} {.status.conditions[*].message}{"\n"}'
ocr -n openshift-adp get installplan -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames,APPROVED:.spec.approved
```

If no InstallPlan appears after a few minutes, the fallback is a supervised re-subscribe: with the revert already
committed, delete the Subscription as well (`oc -n openshift-adp delete subscription oadp-operator`, OPERATOR);
ArgoCD recreates it from git with no `installedCSV`, which is the same `current == nil` path.

**3. Approve the 1.5 InstallPlan (OPERATOR).** Read its steps first: it re-applies the 1.5 CRDs, a schema step down
that is harmless while no 1.6-only field is in use. The two CRDs 1.6 added stay, unused.

```bash
IP=$(ocr -n openshift-adp get installplan -o jsonpath='{range .items[?(@.spec.clusterServiceVersionNames[0]=="oadp-operator.v1.5.0-2026-01-05-165341")]}{.metadata.name}{" "}{.spec.approved}{"\n"}{end}')
echo "$IP"          # the one with approved=false; the 2026-01 plan install-fj9jr (Complete) is also listed, do not approve that
oc -n openshift-adp patch installplan <the unapproved name> --type merge -p '{"spec":{"approved":true}}'    # OPERATOR
```

**4. Delete the two `ConsoleCLIDownload`s (OPERATOR).** Cluster-scoped, no owner, so nothing garbage-collects them.
The names were recorded at the 2026-11-03 upgrade.

```bash
oc delete consoleclidownload openshift-adp-oadp-cli openshift-adp-oadp-vmdp           # OPERATOR
```

**5. Remove what 1.6 wrote to the drill (OPERATOR).** Not `tests/oadp-1.6-drill/delete-requests.yaml`: that file
also purges `drill-15`, which the retry gate (upgrade step 1) needs; it holds only the one `drill-schedule-*` entry (`drill-schedule-20261103083008`, from the 2026-11-03 run); a `DeleteBackupRequest` for a Backup that does not exist yet stays `Processed` and a later
`oc apply` of the same name is then unchanged; and nothing there deletes `drill-schedule`. Instead: Schedule first, so
it takes no more backups, then one rollback-named request per 1.6 Backup that exists (never `drill-15`, never anything
`daily` made). The 1.5 Velero reads what the 1.6 Velero wrote, so these are removed rather than left to be misread.

```bash
oc -n openshift-adp delete schedules.velero.io drill-schedule --ignore-not-found             # OPERATOR
for b in $(ocr -n openshift-adp get backups.velero.io -o name | sed 's#.*/##' | grep -E '^drill-(16|schedule-)'); do
  cat <<YAML | oc apply -f -                                                                 # OPERATOR
apiVersion: velero.io/v1
kind: DeleteBackupRequest
metadata: { name: ${b}-rollback, namespace: openshift-adp }
spec: { backupName: $b }
YAML
done
ocr -n openshift-adp get deletebackuprequests.velero.io      # none left, or read .status.errors
```

**6. Checks (readonly).** CSV `oadp-operator.v1.5.0-2026-01-05-165341` `Succeeded`, DPA `Reconciled`, BSL
`Available` with a fresh validation, Velero and node-agent pods on the 1.5 images, Schedule `daily` still
`paused: true`, no `console-cli-download` / `vmdp-cli-download` objects left, `storedVersions` as in the CRD baseline of
the blog's 2026-11-03 pre-upgrade baseline section (21 CRDs, one version each). 1.6's NetworkPolicies are owned by the DPA, not the CSV, so they stay after the
rollback:

```bash
ocr -n openshift-adp get networkpolicies -o name      # 1.5 had none, so every policy listed is 1.6's
```

List them. If BSL validation stays `Available` and a 1.5 backup works (the drill's run 1 again, with `drill-15`
replaced by a retry name), leave them and record them in the blog. If a leftover policy blocks the data mover or
node agent, delete that policy by hand (OPERATOR); only a running 1.6 operator recreates it.

The failed attempt goes into the blog draft with the commands and outputs that drove the decision.

## Back to okderators for good

When `catalog-index:5.0` (the okderators tag since the 5.0 hop, 2026-11-10) lists the official 1.6 entry, commit `source: okderators` and `startingCSV` = the official
CSV. The installed test CSV is a `1.6.0-2026-11-02-205027` prerelease; the official entry's `skipRange`
(`>=1.4.0-0 <1.6.0-<its date>`) is what lets OLM offer it. If no InstallPlan appears, do the supervised re-subscribe
above (delete the test CSV and the Subscription after the commit). Check that the installed CSV is the official one and every pod image (containers and initContainers) is under
`quay.io/okderators/oadp/`, as in the drill's run 4. Repeat the drill on the official images
(`tests/oadp-1.6-drill/README.md`, run 4), then remove `components/operators/oadp-test-catalog/`.
