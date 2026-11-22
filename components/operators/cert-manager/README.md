# cert-manager-operator

The cert-manager Operator through OLM, with the `CertManager/cluster` CR that configures its operand. Since 2026-11-22
the Subscription reads our okderators 1.21 test catalog `okd-test-cert-manager`
(`components/operators/cert-manager-test-catalog/`, CSV `cert-manager-operator.v1.21.0-2026-11-21-163714`), until
okderators publishes 1.21; before that `okderators` (CSV `cert-manager-operator.v1.20.0-2026-10-22-132146`,
cert-manager v1.20.4). Why: 1.20 supports Kube 1.32–1.35 and the cluster runs Kube 1.36 since the OKD 5.0 hop; 1.21
supports 1.33–1.36. Record: `blog/blog-okderators-cert-manager-draft.md`.

## What it installs

`templates/operator.yaml`, one file:

- Namespace `cert-manager-operator` and an OperatorGroup with `spec: {}` (AllNamespaces), wave 0.
- Subscription `cert-manager-operator`: channel `alpha`, source from `values.yaml`, `installPlanApproval: Manual`,
  wave 1. Do not set it to Automatic: a catalog change would then upgrade the operator unsupervised.
- `CertManager/cluster`, wave 5: the controller's DNS-01 recursive nameservers `1.1.1.1:53,8.8.8.8:53`, only those
  (cluster DNS cannot resolve the public zone, so without them the DNS-01 self-check fails).

`startingCSV` is unset by default and then renders nothing. It exists for the rollback below; OLM ignores it while a
CSV from the Subscription is installed.

The 1.21 operator can create MachineConfigs (the alpha `HTTP01Proxy` feature, off by default). Never enable that
feature gate here: a MachineConfig rerolls every node.

## Rendering locally

Always render with `--show-only templates/operator.yaml`. `charts/` holds a gitignored Helm fallback tarball
(`cert-manager-v1.20.3.tgz`, branch `cert-manager-helm-fallback`); a plain `helm template` renders its 46 objects as
a subchart, and ArgoCD never sees them.

```
helm template cert-manager-operator components/operators/cert-manager/ --show-only templates/operator.yaml \
  | KUBECONFIG=~/.kube/config-readonly oc diff -f -
```

## The zot dependency

The test catalog, the 1.21 operator and its operand images (`cert-manager`, `acme-solver`, `istio-csr`) live in zot
under `okd-test/`. A zot outage or data loss stops cert-manager pods from restarting, and the running ones keep
working. The loop: zot's own route certificate is `okd-wildcard`, which this cert-manager renews. A cert-manager that
cannot start cannot renew it; once that certificate expires, pulls from `zot.apps.okd.sudops.pl` fail TLS, which in
turn keeps cert-manager from starting. Watch `okd-wildcard` (`renewalTime` 2026-12-05 for the first 1.21 renewal).

## Upgrade

Change `source` (or the test catalog image), commit, push, then read the InstallPlan and approve it. Needs the
operator's approval (prompt):

```
KUBECONFIG=~/.kube/config-readonly oc -n cert-manager-operator get installplan,csv,subscription
oc -n cert-manager-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```

## Rollback to 1.20

OLM does not downgrade, so this is a re-subscribe. Every `oc` mutation needs the operator's approval (prompt); the
commit is pushed by the operator. Never delete the `CertManager` CR or a CRD.

1. Check the 1.20 entry is still offered:
   `KUBECONFIG=~/.kube/config-readonly oc get packagemanifest -n openshift-marketplace -l catalog=okderators -o json | jq -r '.items[]|select(.metadata.name=="cert-manager-operator")|.status.channels[]|.name+" "+.currentCSV+" "+([.entries[]?.name]|join(","))'`
   lists `cert-manager-operator.v1.20.0-2026-10-22-132146`. Not offered: stop; the Helm fallback branch is what
   remains (ask first).
2. Auto-sync off, `root-app` first (or its selfHeal turns the child back on), then read both back
   (`automated=` as in `components/operators/nmstate/README.md` "Runbook conventions"):

```
oc -n openshift-gitops patch application root-app --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false,"prune":false,"selfHeal":false}}}}'
oc -n openshift-gitops patch application cert-manager-operator --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

   Then commit `source: okderators` and uncomment `startingCSV` in `values.yaml`, push; `SHA` = that commit.
3. Remove the 1.21 operator (the operand Deployments stay and keep issuing):

```
oc -n cert-manager-operator delete subscription cert-manager-operator
oc -n cert-manager-operator delete csv cert-manager-operator.v1.21.0-2026-11-21-163714
```

   Read `ocr -n cert-manager get deploy` (cert-manager, -cainjector, -webhook still Ready), `ocr get certmanager cluster`
   and the CRD list (the three CRDs 1.21 added stay; OLM leaves them). If an operand Deployment is gone, go straight
   to step 4 and do not create or change any Certificate or Issuer until it is back.
4. Sync `cert-manager-operator` at `$SHA` by hand:

```
oc -n openshift-gitops patch application cert-manager-operator --type merge \
  -p '{"operation":{"sync":{"revision":"'"$SHA"'","syncOptions":["ServerSideApply=true","ServerSideDiff=true","RespectIgnoreDifferences=true","SkipDryRunOnMissingResource=true"]}}}'
```

   Read the InstallPlan: it names only the 1.20 CSV, and its CRDs keep storedVersions `v1` / `v1alpha1`. Anything
   else: do not approve, ask. Approve; the 1.20 operator reconciles the operand back to the 1.20 images.
5. Check the CSV `Succeeded`, the operand on 1.20 and all Certificates Ready. Auto-sync back on, `root-app` last:

```
oc -n openshift-gitops patch application cert-manager-operator --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
oc -n openshift-gitops patch application root-app --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
```

   Remove `startingCSV` in a follow-up commit. The test catalog chart stays until the cause is understood.
