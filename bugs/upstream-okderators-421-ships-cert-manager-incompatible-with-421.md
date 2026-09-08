# `catalog-index:4.21` ships `cert-manager-operator` v1.18, which does not support Kubernetes 1.34 (= OKD 4.21)

**Upstream:** https://github.com/okd-project/okderators-catalog-index
**Component:** `cert-manager-operator` bundle in the `release-4.21` branch / `quay.io/okderators/catalog-index:4.21`
**Affected version:** `catalog-index:4.21` (built 2026-07-13), observed 2026-09-08 on OKD `4.21.0-okd-scos.11`
**Severity:** Functional, delayed-fuse — the operator runs fine in steady state, so the problem is invisible until a
certificate renewal exercises a code path against an unsupported API server. cert-manager issues this cluster's API
serving cert and the `*.apps` wildcard, so the blast radius is all cluster TLS.

## Summary

The 4.21 catalog's `cert-manager-operator` channel head is:

```
$ oc get packagemanifest cert-manager-operator -o jsonpath='{.status.catalogSource} {.status.channels[*].currentCSV}'
okderators  cert-manager-operator.v1.18.0-2025-12-25-214537
```

Per the upstream support matrix (https://cert-manager.io/docs/releases/), cert-manager **1.18 supports Kubernetes
1.29 → 1.33** and reached **end of life on 2026-03-10**.

**OKD 4.21 is Kubernetes 1.34.** So the catalog built specifically for OKD 4.21 ships a cert-manager that does not
support OKD 4.21, and which has been EOL for six months.

| cert-manager | Kubernetes support | EOL |
|---|---|---|
| 1.21 | 1.33 → 1.36 | supported |
| 1.20 | 1.32 → 1.35 | supported |
| 1.19 | 1.31 → 1.35 | 2026-07-08 |
| **1.18 (shipped in `:4.21`)** | **1.29 → 1.33** | **2026-03-10** |

Either 1.20 or 1.21 would cover 1.34. 1.20 is the more useful choice for this catalog line, because its
1.32 → 1.35 range covers **both** OKD 4.21 (1.34) and OKD 4.22 (1.35) — one bundle bump clears two OKD minors.

## Reproduction

On any OKD 4.21 cluster with the okderators CatalogSource at `:4.21`:

```
$ oc -n openshift-marketplace get catalogsource okderators \
    -o jsonpath='{.spec.image} {.status.connectionState.lastObservedState}'
quay.io/okderators/catalog-index:4.21 READY

$ oc get packagemanifest cert-manager-operator \
    -o jsonpath='{range .status.channels[*]}{.name}={.currentCSV}{"\n"}{end}'
alpha=cert-manager-operator.v1.18.0-2025-12-25-214537

$ oc get clusterversion version -o jsonpath='{.status.desired.version}'
4.21.0-okd-scos.11              # Kubernetes 1.34
```

## Why this is not merely cosmetic

An operator being out of matrix does not stop it running — ours is `3/3 Running, 0 restarts` and all five
`Certificate` objects report `Ready=True` immediately after the 4.20 → 4.21 hop. The exposure is at **renewal**,
which exercises API paths a steady-state controller does not, and renewals are exactly the moment when a TLS
operator failing is most expensive.

There is also no escape hatch inside the catalog ecosystem. Every CatalogSource available to a stock OKD cluster
offers an equal or older cert-manager:

| Catalog | Package | Head | Kubernetes support |
|---|---|---|---|
| `okderators:4.21` | `cert-manager-operator` | v1.18.0 | 1.29 → 1.33 |
| `community-operator-index:v4.21` | `cert-manager` | v1.16.5 | 1.25 → 1.32 |
| `operatorhubio/catalog:latest` | `cert-manager` | v1.16.5 | 1.25 → 1.32 |

So a user who follows the documented OKD path to 4.21 has **no supported cert-manager available by OLM at all**,
and the only remedy is to leave OLM and install cert-manager from its upstream Helm chart.

## Secondary finding: `cluster-logging` regressed between `:4.20` and `:4.21`

Same catalog, observed in the same session:

```
:4.20 alpha head = cluster-logging.v6.5.0-2026-06-04-101319
:4.21 alpha head = cluster-logging.v6.3.0-2025-08-08-133408
```

The 4.21 catalog carries an **older** cluster-logging than the 4.20 catalog. A cluster upgrading 4.20 → 4.21 and
bumping the catalog tag as documented sees its logging channel head move backwards by two minors and ten months.
Nothing downgrades in practice — OLM only walks the upgrade graph forward — but the channel is dead as an upgrade
source, and no InstallPlan is generated for any okderators operator after the tag flip. This looks like the
already-open issue #44 ("logging-operator and loki-operator have to be updated to be compatible with 4.21"),
recorded here as a measurement rather than a report.

## Suggested fix

1. Rebuild the `cert-manager-operator` bundle in `release-4.21` against cert-manager **1.20.x** (covers Kubernetes
   1.32 → 1.35, i.e. OKD 4.21 *and* 4.22) or **1.21.x** (1.33 → 1.36).
2. Consider a CI gate that fails the catalog build when a bundle's declared upstream Kubernetes support range does
   not include the Kubernetes version of the OKD minor the branch targets. That single check would have caught both
   findings here.
3. For `cluster-logging`, either carry forward the 4.20 bundle or document the channel as unsupported on 4.21 so
   operators do not flip the tag expecting an upgrade path.

## Environment

- OKD `4.21.0-okd-scos.11` (Kubernetes 1.34), 3-node bare-metal compact cluster, CentOS Stream CoreOS 10
- `okderators` CatalogSource `quay.io/okderators/catalog-index:4.21`, `lastObservedState: READY`
- Installed: `cert-manager-operator.v1.18.0-2025-12-25-214537`, subscription channel `alpha`,
  `installPlanApproval: Manual`
