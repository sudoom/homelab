# OADP: `backupLocations[].velero.default` is not propagated to an existing BackupStorageLocation

**Observed:** 2026-09-07, OADP 1.5.0 on OKD 4.20.0-okd-scos.17 (Kube 1.33).

## Summary

Changing `default` on a `backupLocations` entry in an existing
`DataProtectionApplication` does not update `spec.default` on the
BackupStorageLocation the DPA owns. The operator reconciles the BSL — its
`metadata.generation` advances — but the `default` field is left untouched. The
result is a DPA that reports `Reconciled=True` while the cluster has **no
default BSL at all**.

## Reproduction

1. A DPA with two `backupLocations`, one named `default` (`default: true`) and a
   second named `truenas-garage` (`default: false`). Both BSLs Available.
2. Edit the DPA so `truenas-garage` has `default: true` and remove the other
   location entirely.
3. Operator reconciles, deletes the removed BSL, reports `Reconciled=True`,
   reason `Complete`.

**Expected:** `truenas-garage` BSL ends with `spec.default: true`.

**Actual:** `spec.default` is absent.

```
$ oc -n openshift-adp get bsl truenas-garage \
    -o jsonpath='generation={.metadata.generation} default=[{.spec.default}]'
generation=28200 default=[]

$ oc -n openshift-adp get dpa dpa \
    -o jsonpath='{.spec.backupLocations[0].name}={.spec.backupLocations[0].velero.default}'
truenas-garage=true

$ oc -n openshift-adp get dpa dpa -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}'
True
```

The BSL was created 2026-08-28 with `default: false` and generation advanced
from 28194 to 28200 across the reconcile, so the operator is writing to the
object — it simply does not carry this field.

## Why it matters

`Reconciled=True` with zero default BSLs is a silent trap. A `Schedule` naming
its `storageLocation` explicitly keeps working, so nothing fails; the exposure
is an ad-hoc `velero backup create` or a restore issued without
`--storage-location`, which is exactly what an operator reaches for during an
incident.

## Related validation quirk, same area

The DPA controller enforces that a location **named** `default` must have
`default: true`:

```
Reconciled=False  Error: Storage location named 'default' must be set as default
```

That is reasonable on its own, but combined with the above it removes the
obvious migration path. The intuitive two-step — demote the old default, promote
the new one, then delete the old — is rejected at step one, and the alternative
(delete the old, promote the new in a single change) hits the propagation bug
instead. Neither ordering produces a default BSL without deleting and letting
the operator recreate it.

## Workaround

Delete the BSL and let the DPA recreate it; `default` is honoured at creation:

```
oc -n openshift-adp delete bsl <name>
```

## Same shape as

`bugs/upstream-rook-deviceclass-change-not-propagated-existing-pool.md` — an
operator honouring a field at create time and ignoring it on update, while
reporting success.
