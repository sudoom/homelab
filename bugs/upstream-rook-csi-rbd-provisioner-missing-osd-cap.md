# `client.csi-rbd-provisioner.1` observed without an `osd` cap after a fresh bootstrap (observed once, cause unknown)

**Filing recommendation: do not file.** One observation, no reproduction, and the Rook source at the observed version
does not explain it. The first draft claimed the Rook caps template lacks the osd cap; that is wrong (see "Code path").
File only if it recurs on a fresh bootstrap with the operator log and `ceph auth get` captured at the time. Until then
the hourly `csi-rbd-provisioner-caps-fix` Job stays (see "Local state").

**Upstream:** https://github.com/rook/rook (not filed)
**Component:** `pkg/operator/ceph/csi/secrets.go`
**Version at observation:** Rook v1.19.5, Ceph Squid 19.2.3 (`quay.io/ceph/ceph:v19.2.3`), OKD 4.20 / Kube 1.33

## Observed (2026-05-15)

Fresh `CephCluster` bootstrap after a teardown, `network.provider: host` with `addressRanges.public/cluster:
["192.168.10.0/24"]`. The Rook operator was running through the whole teardown and re-bootstrap (not removed).
`ceph auth ls` showed:

```
client.csi-rbd-provisioner.1
  caps mgr "allow rw"
  caps mon "profile rbd, allow command 'osd blocklist'"
  (no osd cap)
```

The other CSI users from the same reconcile had the expected caps:

| User | mon cap | osd cap |
|---|---|---|
| `client.csi-rbd-node.1` | `profile rbd` | `profile rbd` |
| `client.csi-rbd-provisioner.1` | `profile rbd, allow command 'osd blocklist'` | missing |
| `client.csi-cephfs-node.1` | (via mds path) | `allow rwx tag cephfs metadata=*, allow rw tag cephfs data=*` |
| `client.csi-cephfs-provisioner.1` | (via mds path) | `allow rw tag cephfs metadata=*` |

Effect: a PVC on the RBD StorageClass stayed `Pending`. `CreateVolume` ended in `DeadlineExceeded` (`stream
terminated by RST_STREAM with error code: CANCEL`), then `Aborted ... an operation with the given Volume ID ... already
exists` on every retry. Restarting the CSI plugin pods did not help. `ceph auth caps client.csi-rbd-provisioner.1 mgr
"allow rw" mon "profile rbd, allow command 'osd blocklist'" osd "profile rbd"`, clearing the orphan omap entry in
`csi.volumes.default` and restarting the ctrlplugin made provisioning work.

Operator log, two lines for the user during bootstrap:

```
2026-05-15 08:02:03.794635 I | cephclient: getting or creating ceph auth key "client.csi-rbd-provisioner.1"
2026-05-15 08:02:56.634135 I | cephclient: getting or creating ceph auth key "client.csi-rbd-provisioner.1"
```

The log excerpt kept from that day does not show the `Error getting or creating key ... Attempting to update
capabilities` or `updating ceph auth caps` lines that the update path writes (below). The full operator log was not kept,
so absence of those lines is not established.

## Code path (v1.19.5, identical caps function in v1.21.1)

`cephCSIKeyringRBDProvisionerCaps()` returns the full set, including the osd cap:

```go
return []string{
    "mon", "profile rbd, allow command 'osd blocklist'",
    "mgr", "allow rw",
    "osd", "profile rbd",
}
```

`CreateCSISecrets` passes it to `createCSIKeyring`, which calls `SecretStore.GenerateKey(latestClientId, keyCaps)`:

1. `client.AuthGetOrCreateKey` runs `ceph auth get-or-create-key <user> <caps...>` (`args := append([]string{"auth",
   "get-or-create-key", name}, caps...)`).
2. If that returns an error, `GenerateKey` logs `Attempting to update capabilities in case the user already exists`,
   runs `client.AuthUpdateCaps` (`ceph auth caps <user> <caps...>`) and then `AuthGetKey`.
3. Both calls are made on every reconcile of `CreateCSISecrets`.

Consequences for the observed state:

- The caps list has six elements in fixed order, so an odd-length or empty-value argument list is not possible from this
  function. `ceph auth caps` replaces the whole cap set, so only a call that omits `osd` leaves the observed state.
  Rook's calls all include it.
- Nothing in `pkg/operator/ceph/csi/secrets.go` creates this user with fewer caps. In the Rook tree the only other
  references to `csi-rbd-provisioner` are the StorageClass examples, tests, the chart and
  `deploy/examples/create-external-cluster-resources.py`, which is a manual external-cluster tool and is not run by the
  operator.
- If the user had been created with fewer caps by something else, the next `get-or-create-key` with the full set is
  expected to be rejected by Ceph because the existing caps differ (from memory of the Ceph auth monitor, not read for
  this note), and `GenerateKey` would then run `AuthUpdateCaps` with the full set. The second reconcile at 08:02:56
  would have repaired it.
- If `AuthUpdateCaps` fails, `GenerateKey` returns an error and `CreateCSISecrets` fails. The mon applies `auth caps`
  as one command, so a failure leaves the previous caps unchanged. That would leave a stale cap set, but not one with
  `osd` removed unless it was created that way.
- `git log` for `secrets.go` shows no change to the provisioner caps between the commit that added the executable
  permission (2025-04-29) and v1.21.1. The v1.19.5 template is not a regression window.

## Not ruled out

- A manual `ceph auth` command or script run earlier that day. No such step is recorded in the 2026-05-15 notes, but the
  notes are a chronology written afterwards, not a command log.
- A Ceph-side effect during bootstrap, when the osd cap was submitted before any OSD existed (the OSDs came up about
  3 minutes after the mons). Not tested, and the other users' osd caps in the same reconcile were stored correctly.
- The caps were read through `ceph auth ls | grep -A4 csi-rbd`. A `grep -A4` window could cut off a fifth line. The same
  session's `ceph auth caps` fix and the PVC outcome suggest the cap really was missing, but the full `ceph auth get`
  output was not saved.

## Local state

- The workaround Job `components/storage/rook-ceph-cluster/templates/csi-rbd-provisioner-caps-fix.yaml` re-applies the
  full caps hourly, so a live read of the user on the current cluster always shows the Job's set and cannot show whether
  Rook produced it.
- Rook v1.21.1 and Ceph Tentacle 20.2.5 have run since 2026-11-06 and 2026-11-09. The caps read after each stage equal the
  Job's set. That does not separate Rook's output from the Job's.
- A reproduction needs the Job suspended and a teardown plus re-bootstrap of the CephCluster with the operator running,
  which is a degraded window on a cluster with no drain headroom. Not worth doing for this.
- Chronology: `blog/blog-multus-ceph-migration-draft.md`, section "2026-05-15 — fresh bootstrap on `host +
  addressRanges` + Rook 1.19.5 csi-rbd-provisioner cap bug", and `blog/blog-rook-ceph-draft.md` (close-out decisions,
  2026-11-10).
