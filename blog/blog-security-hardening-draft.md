# Security hardening — working draft

Running notes for security-focused changes on the cluster. One file per
discrete change, chronologically appended. Anything that touches the
threat-model floor (etcd encryption, OSD encryption, NetworkPolicies,
SCC tightening, key rotation) belongs here.

## 2026-05-18 — etcd encryption at rest (`aescbc`)

### What

Set `spec.encryption.type: aescbc` on the cluster `APIServer/cluster`
CR. OpenShift's kube-apiserver-operator handles everything else:
key generation, weekly auto-rotation, and re-encryption of existing
objects on the first enable.

### Why now

Cheapest meaningful security floor we can set today. Previously, every
Secret in the cluster sat in etcd as a base64-decoded plaintext — pull
the etcd database file off any node's disk and the entire credential
graph is yours (CNPG superuser, sealed-secrets master key, OAuth
tokens, Cloudflare API token, NORDVPN creds, etc.). With encryption
on, the etcd blob is AES-CBC-encrypted with a key that lives **only in
memory and on the master nodes** (the operator manages key material in
the openshift-config-managed namespace via per-resource Secrets).

Threat model coverage:
- ✅ **Compromised disk** (lost node, decommissioned drive, image
   snapshot from a hypervisor) — etcd contents unreadable.
- ✅ **Offline etcd backup** — encrypted at rest, useless without the
   in-memory key material.
- ❌ **Compromised live API server** — encryption is at rest, not in
   transit; anyone with API access gets plaintext like before. (Not a
   regression: this was always the case. RBAC + audit logs are the
   defense here.)
- ❌ **Compromised master node** — the operator's encryption-key
   Secrets live in the same etcd. Total node compromise = key
   exposure. (Out of homelab threat model.)

Not a silver bullet, but: ~5 minutes of API-server-operator churn for
zero ongoing operational cost is one of those rare unambiguous wins.

### What gets encrypted

Per the OpenShift docs (matches `kube-apiserver-operator` source):

- `secrets` (in every namespace, all kinds)
- `configmaps` (in every namespace — non-obvious, but ConfigMaps often
  carry sensitive data in homelabs)
- `oauthaccesstokens.oauth.openshift.io`
- `oauthauthorizetokens.oauth.openshift.io`
- `routes.route.openshift.io` (TLS cert data inlined in Route specs)

Not encrypted (intentionally; required for cluster bootstrap):
- ServiceAccount tokens
- CSRs
- Cluster events
- Plain API objects (Pods, Deployments, etc.) — they don't carry
  credentials.

### Algorithm choice — `aescbc` vs `aesgcm`

OpenShift supports both. Going with `aescbc` because:

- It's the OpenShift-recommended default (long-tested, FIPS-compatible).
- `aesgcm` provides authenticated encryption (ties an integrity tag
  to the ciphertext) — modestly better cryptographic properties — but
  is newer and less battle-tested in the OKD ecosystem.
- Performance is functionally identical for the workload (etcd reads
  happen at boot + on object updates; not in app hot paths).
- Switching algorithms later is supported — the operator handles
  the migration by re-encrypting everything under the new algorithm
  before retiring the old keys.

Will reassess if there's a stated reason to flip — e.g. FIPS-180-4
compliance preference, NIST guidance shift, or a CVE in the AES-CBC
implementation.

### Implementation

Single change to the existing `components/cluster-config/api-server/`
chart (which already owns the CR — was previously only setting
`servingCerts.namedCertificates` for the api.okd.sudops.pl TLS).

```yaml
# components/cluster-config/api-server/values.yaml
encryption:
  type: aescbc
```

Template renders the `spec.encryption.type` field conditionally; empty
string disables (leaves the spec block out, so existing encryption
state is preserved if you ever want to manually pause without
re-encryption side effects).

`helm template ... | oc diff -f -` shows the change is purely additive
— no field removals, no managedFields surprises (this CR has clean
SSA ownership from prior changes).

### Roll-out behavior

What happens after ArgoCD syncs the change:

1. kube-apiserver-operator notices `spec.encryption.type` changed.
2. Generates the first encryption-key Secret in
   `openshift-config-managed`.
3. Rolls a new kube-apiserver Deployment revision with the encryption
   provider configured.
4. Once the new pods are up, marks the cluster as `Encrypted=True` in
   the APIServer CR's status conditions.
5. Walks the encrypted-resource list (secrets, configmaps,
   oauthaccesstokens, etc.) and re-writes each object with the new
   cipher — this triggers an etcd write per object but takes
   ~minutes for a homelab-sized cluster.
6. Sets the `EncryptionInProgress` condition False and
   `Encrypted=True` finalized.

No app downtime. The API server stays available throughout — the
encryption-provider chain is configured so the new pods can decrypt
old (unencrypted) objects via the identity provider fallback, then
re-encrypt with the active key on next write.

### Post-sync verification

Wait ~5 min after ArgoCD reports the app `Synced+Healthy`, then:

```bash
# Top-level condition — should flip to True
oc get apiserver/cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")]}{"\n"}'

# Per-resource progress (one entry per encrypted GVR)
oc get apiserver/cluster -o jsonpath='{.status.conditions[?(@.type=="EncryptionInProgress")]}{"\n"}'

# Verify a Secret is actually encrypted in etcd (debug node access required)
# — read the raw etcd value and confirm it's an AES-CBC blob, not plaintext base64
oc -n openshift-etcd debug node/node4.okd.sudops.pl -- chroot /host etcdctl get /kubernetes.io/secrets/default/<some-secret> 2>&1 | head -5
# Expected: binary blob starting with `k8s:enc:aescbc:v1:` prefix
# Pre-encryption: prefixed with the type, then plaintext-ish protobuf
```

### Key rotation

The operator auto-rotates the encryption key every **7 days** by
default. No manual intervention needed. To force an immediate rotation
(e.g., suspected key compromise):

```bash
oc patch apiserver/cluster --type=merge \
  -p '{"spec":{"encryption":{"type":"aescbc"}}}'
# (touching the field even with the same value triggers rotation)
```

After rotation, the operator re-encrypts under the new key on the next
write of each resource. There's also a passive re-encryption sweep
that walks all encrypted-resource GVRs to migrate everything
proactively — same logic as the first enable.

### Open follow-ups

- **Verify after initial roll-out** — capture the `Encrypted=True`
  condition timestamp + the actual etcd blob byte-level check (the
  `k8s:enc:aescbc:v1:` prefix is the irrefutable proof).
- **Trigger a manual key rotation drill** once verification passes —
  not for operational reasons but to validate the rotation flow works.
- **Consider `aesgcm` later** — newer, authenticated. Not urgent;
  algorithm migration is reversible.
- **Sealed-secrets master key rotation** — separate from etcd
  encryption, but adjacent. The bitnami-labs/sealed-secrets controller
  generates its own master key on first start and never rotates by
  default. Should be on a quarterly rotation; coupled with re-sealing
  the in-repo SealedSecrets. Add to the security-followups list.

### Proof: same etcd key, before vs after

Created a canary Secret in `default` before the rollout and read it
directly from etcd via `etcdctl` on a master node — both reads bypass
the API server, so they see the raw stored bytes:

```bash
oc create secret generic etcd-encryption-canary \
  --from-literal=plaintext-marker=DEMO_SECRET_VALUE_2026_05_18 \
  -n default

oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- \
  etcdctl get /kubernetes.io/secrets/default/etcd-encryption-canary
```

**Before** (spec.encryption.type not yet set):
```
/kubernetes.io/secrets/default/etcd-encryption-canary
k8s
v1Secret
  etcd-encryption-canary default" *$977f7cb5-7436-43c5-...
  plaintext-markerDEMO_SECRET_VALUE_2026_05_18Opaque
```

The marker string `DEMO_SECRET_VALUE_2026_05_18` is plainly visible in
the binary protobuf — `grep` against the etcd snapshot would find it.

**After** (post-`EncryptionMigrationController` sweep):
```
/kubernetes.io/secrets/default/etcd-encryption-canary
k8s:enc:aescbc:v1:1:P�`�z/��Ȫ�E<* �#����B�� v���,r��2���V%p��SkP�c�...
```

The envelope is the irrefutable proof:
- `k8s:enc:aescbc:v1:1:` = AES-CBC v1, key index 1
- Key index `1` matches the `encryption-key-openshift-kube-apiserver-1`
  Secret in `openshift-config-managed` (gets rotated weekly by the
  operator; index increments on each rotation).
- The marker string is no longer grep-able — the ciphertext is
  AES-CBC-encrypted under the in-memory key.

### What gets encrypted — actual list

The Progressing message during rollout showed only
`[core/configmaps core/secrets]` being migrated by the
`EncryptionMigrationController`. That looked too narrow at first, but
post-rollout there are **three separate encryption configs** in
`openshift-config-managed`:

```
encryption-config-openshift-apiserver         # OpenShift-specific APIs
encryption-config-openshift-kube-apiserver    # core kube APIs
encryption-config-openshift-oauth-apiserver   # OAuth tokens
encryption-key-openshift-apiserver-1
encryption-key-openshift-kube-apiserver-1
encryption-key-openshift-oauth-apiserver-1
```

Each API server runs its own migration cycle against its own keys. So
the original docs claim holds:

- **kube-apiserver** encrypts: core `secrets`, core `configmaps`.
- **openshift-apiserver** encrypts: `routes.route.openshift.io` and a
  few other OpenShift-specific resources.
- **oauth-apiserver** encrypts: `oauthaccesstokens.oauth.openshift.io`,
  `oauthauthorizetokens.oauth.openshift.io`.

The `EncryptionMigrationControllerProgressing` message visible during
rollout was only the kube-apiserver's portion because that's the
component my watch was scoped to. The other two API servers run their
migrations independently and update their own clusteroperator messages.

### Rollout timing

For reference, on this 3-node cluster on PM9A1 NVMe:

- Spec change to first Progressing=True: ~30s (kube-apiserver-operator
  reconcile cycle).
- Each node revision install: ~2-3 min (new static pod manifest +
  kubelet roll + readiness wait).
- Three-node revision roll (23 → 24): ~9 min wall-clock.
- Re-encryption migration of all existing Secrets+ConfigMaps:
  ~tens-of-seconds (the workload is tiny — ~hundreds of objects total,
  not the thousands a production cluster would have).
- Total wall-clock from `git push` to ciphertext-confirmed:
  approximately 12 minutes (including ArgoCD poll lag).

No app-visible disruption observed throughout — API requests stayed
responsive (ArgoCD apps held `Synced+Healthy`, ScheduledBackup
continued archiving WAL).

### Cleanup

```bash
oc -n default delete secret etcd-encryption-canary
```

Trivial demo artifact; not worth keeping in etcd as historical noise.
