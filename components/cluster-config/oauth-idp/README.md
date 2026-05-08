# oauth-idp

Adopts the singleton `OAuth/cluster` CR and adds two identity providers:
**GitHub OAuth** (primary) and **htpasswd** (optional break-glass). Plus the
ClusterRoleBinding that grants `cluster-admin` to the GitHub user(s) you
choose.

`kubeadmin` keeps working alongside this — the built-in admin account isn't
gated by `OAuth.spec.identityProviders`, so it remains available as the
ultimate break-glass.

## One-time setup runbook

Order matters — register the OAuth App first so you have the client ID and
secret to seal before flipping this chart on.

### 1. Register the GitHub OAuth App

Org-level (recommended): https://github.com/organizations/sudoom/settings/applications/new

- **Application name**: `OKD Cluster - sudops`
- **Homepage URL**: `https://api.okd.sudops.pl:6443`
- **Authorization callback URL**: `https://oauth-openshift.apps.okd.sudops.pl/oauth2callback/github`

Hit **Generate a new client secret**. Save the **Client ID** and **Client
Secret** somewhere safe (Bitwarden / 1Password / your shell). The client
secret is only shown once.

### 2. Seal the client secret

Make sure you're logged in to the cluster (`oc login` against `api.okd.sudops.pl`)
and `kubeseal` is on PATH.

```sh
oc -n openshift-config create secret generic github-oauth-client-secret \
  --from-literal=clientSecret='<paste-the-client-secret>' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > components/cluster-config/oauth-idp/templates/sealed-github-oauth-client-secret.yaml
```

That overwrites the placeholder stub with the real SealedSecret.

### 3. Fill values.yaml

Edit `components/cluster-config/oauth-idp/values.yaml`:

```yaml
github:
  clientID: "Iv1...."             # from step 1
  organizations:
    - sudoom                      # already set
  teams: []                       # or ["sudoom/admins"] to restrict
  clusterAdminUser: "<your-github-username>"
```

### 4. (Optional) Seal an htpasswd break-glass user

Skip this if `kubeadmin` is sufficient as your fallback.

```sh
htpasswd -c -B -b /tmp/users.htpasswd 'breakglass' '<strong-password>'

oc -n openshift-config create secret generic htpasswd-secret \
  --from-file=htpasswd=/tmp/users.htpasswd \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > components/cluster-config/oauth-idp/templates/sealed-htpasswd.yaml

rm /tmp/users.htpasswd
```

Then in `values.yaml`:

```yaml
htpasswd:
  enabled: true
  username: "breakglass"
```

### 5. Validate the chart locally before turning it on

```sh
helm lint components/cluster-config/oauth-idp/
helm template oauth-idp components/cluster-config/oauth-idp/ \
  -f components/cluster-config/oauth-idp/values.yaml
```

The rendered output should show the `OAuth/cluster` CR with your IdP block,
two SealedSecrets (or one if you skipped htpasswd), and the
ClusterRoleBinding(s).

### 6. Enable the chart in the root app

In `bootstrap/root-app/values.yaml`, add:

```yaml
oauth-idp:
  enabled: true
  path: components/cluster-config/oauth-idp
  namespace: openshift-config
  syncWave: "2"
```

Commit + push. Argo applies. The OAuth pods restart automatically once the
new IdP config lands. Watch:

```sh
oc -n openshift-authentication get pods -w
oc get oauth cluster -o yaml
```

### 7. Test login end-to-end before disabling kubeadmin (recommended: don't)

```sh
oc login --username='<your-github-username>' --web
```

You should be redirected to GitHub, asked to authorize the app, redirected
back, and end up logged in. Then verify cluster-admin:

```sh
oc whoami
oc auth can-i '*' '*' --all-namespaces   # should print "yes"
```

### 8. Optional: disable kubeadmin

`kubeadmin` is intentionally still active even after IdPs are configured —
it's the documented break-glass for OpenShift. Most homelabs leave it on.
If you want it gone:

```sh
oc -n kube-system delete secret kubeadmin
```

Reversible only by recreating the Secret; consider keeping the htpasswd IdP
above as your second factor before doing this.

## What's in the chart

| File | What it does |
|---|---|
| `templates/oauth-cluster.yaml` | Owns the `OAuth/cluster` singleton; renders identityProviders for GitHub (always when clientID set) and htpasswd (if enabled) |
| `templates/sealed-github-oauth-client-secret.yaml` | SealedSecret for the GitHub OAuth client secret. Stub until you replace via kubeseal |
| `templates/sealed-htpasswd.yaml` | SealedSecret for the htpasswd file content. Renders only when htpasswd.enabled |
| `templates/clusterrolebinding-github.yaml` | Grants `cluster-admin` to `github.clusterAdminUser` (and `htpasswd.username` if enabled) |

## Rotating the GitHub client secret

If GitHub rotates the secret or you suspect compromise:

1. Generate a new client secret in the GitHub OAuth App settings.
2. Re-run the kubeseal command from step 2 above (overwrites the same file).
3. Commit + push. Argo applies the new SealedSecret; sealed-secrets controller
   updates the underlying Secret in `openshift-config`; the OAuth pod picks
   up the change on next read (no restart needed for client secret rotation,
   but it doesn't hurt to bounce: `oc -n openshift-authentication delete pod -l app=oauth-openshift`).
