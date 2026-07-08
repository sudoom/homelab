# sealed-secrets

Bitnami **sealed-secrets** controller (vendored chart `2.19.1` → controller
`0.38.4`, committed `charts/*.tgz` + `Chart.lock`). Decrypts `SealedSecret` CRs
into plain `Secret`s in-cluster; the cluster-private key never leaves the controller.

## Key auto-rotation (`--key-renew-period=720h`)

`values.yaml` sets `--key-renew-period=720h` (30d). **Do NOT set this to `0`** —
that *disables* rotation, and on 2026-05-28 it let the single sealing key's cert
expire (~30d after creation) with nothing replacing it, so `kubeseal` failed with
`expired certificate` and **all new sealing was blocked** (existing SealedSecrets
kept decrypting — cert expiry only breaks *sealing*). With rotation on, the
controller mints a fresh key + **10-year** cert each cycle and **retains old keys
for decryption**, so nothing silently expires. Full incident: README TODO +
the rotation note.

## `sealed-secrets-pub.pem` — offline sealing cert

The controller's **current public sealing certificate**, committed so `kubeseal`
can seal **offline** (no cluster / no `oc login` needed), e.g. in CI:

```bash
kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem \
  --format yaml < secret.yaml > sealed.yaml
```

- It is a **public** key — it can only *seal*, never *unseal* — so it is safe to
  commit and share.
- Refresh it after a key rotation if you want to seal against the newest key (the
  controller still decrypts secrets sealed with older retained keys, so this is a
  forward-secrecy nicety, not a hard requirement):
  ```bash
  kubeseal --controller-namespace sealed-secrets --fetch-cert \
    > components/operators/sealed-secrets/sealed-secrets-pub.pem
  ```
- Current cert validity: **Jun 2036** (fetched 2026-06-27 after the rotation fix).

## Files

| File | Purpose |
|---|---|
| `Chart.yaml` / `Chart.lock` / `charts/` | vendored bitnami sealed-secrets 2.19.1 (controller 0.38.4) |
| `values.yaml` | `fullnameOverride` + `--key-renew-period=720h` |
| `sealed-secrets-pub.pem` | current public sealing cert (offline `kubeseal --cert`) |
| `templates/` | namespace + any local extras |
