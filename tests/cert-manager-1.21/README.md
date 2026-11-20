# cert-manager staging DNS-01 issuance kit

Issues a Let's Encrypt **staging** certificate through the same Cloudflare DNS-01 solver the production
`letsencrypt-prod` ClusterIssuer uses. Run it on cert-manager 1.20 as a baseline, then again on 1.21 after the
operator switch (plan `okd5-cert-manager`, Task 2 and Task 9 Step 4). It proves the whole ACME path (account
registration, Order, Challenge, issuance) without touching a production certificate or the rate limits.

Not ArgoCD-managed: the operator applies and deletes these by hand. The kit references the Cloudflare token Secret
`cloudflare-api-token` by name only. **Never read a Secret** here, including `cm-dns01-test-tls`: verify through
the Certificate, CertificateRequest and Order status.

Files: `staging-issuer.yaml` (ClusterIssuer `letsencrypt-staging-test`), `test-certificate.yaml` (Certificate
`cm-dns01-test` in `cert-manager`, name `cm-dns01-test.homelab.sudops.pl`).

## Apply (operator)

```bash
oc apply -f tests/cert-manager-1.21/staging-issuer.yaml
oc apply -f tests/cert-manager-1.21/test-certificate.yaml
```

## Read (every 15 s until Ready or 10 min)

```bash
ocr() { KUBECONFIG=~/.kube/config-readonly oc "$@"; }
ocr get clusterissuer letsencrypt-staging-test -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{end}{"\n"}'
ocr -n cert-manager get certificate cm-dns01-test -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {end}notAfter={.status.notAfter}{"\n"}'
ocr -n cert-manager get certificaterequest,order,challenge -o wide | grep cm-dns01-test
```

Expected: ClusterIssuer `Ready=True ACMEAccountRegistered`; Challenge `dns-01` pending, then valid and deleted;
Order `valid`; Certificate `Ready=True` with a future `notAfter`.

## Clean up (operator)

Order matters: the ClusterIssuer goes before the account Secret, or its controller re-creates the Secret.

```bash
oc -n cert-manager delete certificate cm-dns01-test
oc delete clusterissuer letsencrypt-staging-test
oc -n cert-manager delete secret cm-dns01-test-tls letsencrypt-staging-test-account --ignore-not-found
```

Then read-only (default table output only, never `-o yaml/json/name` on a Secret):

```bash
ocr -n cert-manager get secret cm-dns01-test-tls letsencrypt-staging-test-account   # both NotFound
ocr get clusterissuer letsencrypt-staging-test                                      # NotFound
ocr -n cert-manager get certificaterequest,order,challenge | grep cm-dns01-test     # empty
```
