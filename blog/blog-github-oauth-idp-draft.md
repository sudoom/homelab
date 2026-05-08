# GitHub OAuth IdP for OKD: two ways to do it wrong, one way to do it right

The recurring annoyance: every Claude Code session that touches the cluster
starts with `oc login --token=sha256~...` pasted from the OpenShift web
console. The token expires after ~24 h, the paste is fiddly, and the
session-start friction is real.

The fix: configure the cluster's `OAuth/cluster` singleton with a GitHub
identity provider. After that, `oc login --username=<gh-user> --web` opens a
browser, the OAuth dance happens, and `oc` lands a long-lived bearer token in
my kubeconfig. Conceptually a 15-minute task. In practice, two failure modes
ate about 30 minutes between them. Worth writing up because they're going to
catch the next person.

## The chart

Component layout fits the existing pattern: a Helm chart at
`components/cluster-config/oauth-idp/` that owns the `OAuth/cluster` CR
(singleton, adopted by Argo), a `SealedSecret` for the OAuth client secret in
`openshift-config`, and a `ClusterRoleBinding` granting `cluster-admin` to
the configured GitHub user. Wired into `bootstrap/root-app/values.yaml` at
sync wave 2 alongside `cert-manager-config`.

The chart is intentionally GitHub-only — no `htpasswd` break-glass. OpenShift's
built-in `kubeadmin` user is *not* gated by `OAuth.spec.identityProviders`
(it's a special account in `kube-system`), so it remains available as the
ultimate fallback regardless of how the IdP block is configured. Two separate
break-glass paths felt like overkill for a homelab. The chart README warns
against deleting `kubeadmin` until GitHub OAuth has been working reliably for
a while.

`values.yaml` is small:

```yaml
github:
  clientID: "Ov23li..."
  organizations:
    - sudoom-homelab
  teams: []
  clusterAdminUser: "sudoom"
```

`organizations` is required for security — without it any GitHub user with a
valid token can authenticate. `teams` is optional and not used here.
`clusterAdminUser` drives a `ClusterRoleBinding` granting cluster-admin to
that exact GitHub username (case-sensitive).

The client secret lands in `templates/sealed-github-oauth-client-secret.yaml`
via the standard kubeseal flow:

```
oc -n openshift-config create secret generic github-oauth-client-secret \
  --from-literal=clientSecret='<from-github-app>' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > components/cluster-config/oauth-idp/templates/sealed-github-oauth-client-secret.yaml
```

## Failure mode 1: user-owned OAuth App returns empty org membership

The first attempt registered the OAuth App at `https://github.com/settings/developers`
— the **user-account** scope. Wired everything up, ran `oc login --web`, got
through GitHub's consent screen, and landed at:

```
AuthenticationError: User sudoom is not a member of any allowed organizations
[sudoom] (user is a member of [])
```

The "user is a member of []" is the giveaway. GitHub's `/user/orgs` API
returned an empty list, even though I'm a member of the `sudoom` org with
`read:org` scope explicitly granted in the consent flow.

This is GitHub's third-party OAuth app access policy doing exactly what it
says on the tin: **a user-owned OAuth App authenticating against an org with
restricted third-party app access is invisible to that org until an org owner
explicitly approves the App for the org.** The user can grant `read:org` to
the App in their personal settings; that's necessary but not sufficient. The
org-side approval is the missing half.

Two ways to fix it:

1. **Approve the user-owned App at the org level**: org owner clicks Approve
   at `https://github.com/organizations/<org>/settings/oauth_application_policy`.
2. **Re-register the App under the org**: org-owned Apps don't need separate
   approval — they're inherently approved within their owning org.

I went with option 2, both because it's the cleaner architectural choice
(the App is conceptually an org asset, not a personal one) and because option
1 leaves a permanent dependency on someone remembering to approve future App
changes.

But — second twist — I created a *new* org for it: `sudoom-homelab`. The
existing `sudoom` org is for unrelated personal projects, and giving an
admin OAuth App to the same org I use for one-off pushes felt wrong. So:
new org, new App, separate trust boundary.

## Failure mode 2: clientID changes, clientSecret doesn't

After re-registering the App in `sudoom-homelab`, I did the obvious thing:
update `clientID` in `values.yaml`, re-seal a *new* client secret produced by
the new App, push. Argo applied, oauth-openshift rolled, login attempt
returned:

```
Error getting access token from an external OIDC provider
(https://github.com/login/oauth/access_token): The code passed is incorrect
or expired.
AuthenticationError: The code passed is incorrect or expired.
```

This error message is misleading. The auth code is in fact freshly minted —
it's not expired. What's actually happening: GitHub generates the auth code
*against the clientID it was sent*. OpenShift then exchanges that code at the
token endpoint *signed with the clientSecret*. If the clientSecret on file
doesn't match the App that issued the clientID, GitHub rejects the exchange
with this exact text.

In my case, the rotation went sideways somewhere — most likely a partial
clipboard paste of the new client secret that left the sealed value tied to
the old App. The fix was simple: regenerate the client secret in the GitHub
App UI (since the previous-attempt's secret was now suspect), copy *the entire
value* including the trailing dot-separated segments that GitHub recently
added, re-seal, push.

The lesson is procedural rather than conceptual: **when you change the
clientID, regenerate the matching client secret in the same operation, even
if the previous secret was theoretically still valid for the new App.** The
secret is the only piece of evidence GitHub uses to bind a code-exchange
request to an App. Mismatches die loudly with this specific error and waste
ten minutes of "but I just sealed it."

## Net result

`oc login --username=sudoom --web --server=https://api.okd.sudops.pl:6443`
works. Browser opens, GitHub consent shows `sudoom-homelab` org access
(approved by default since the App is org-owned), redirects back, lands a
bearer token. `oc whoami` returns `sudoom`. `oc auth can-i '*' '*' --all-namespaces`
prints `yes`.

The GitHub Apps page in `sudoom-homelab` settings shows three login events
since deployment, all clean. The user-owned App from the first attempt got
revoked at `https://github.com/settings/developers` — same name, no longer
needed.

## What's in the chart

| File | Purpose |
|---|---|
| `templates/oauth-cluster.yaml` | Owns the singleton `OAuth/cluster`; renders the GitHub identityProvider |
| `templates/sealed-github-oauth-client-secret.yaml` | SealedSecret for the OAuth client secret in `openshift-config` |
| `templates/clusterrolebinding-github.yaml` | Grants `cluster-admin` to `github.clusterAdminUser` |
| `values.yaml` | `clientID`, `organizations`, `teams`, `clusterAdminUser` |
| `README.md` | Step-by-step runbook, including rotation instructions |

## Rotation runbook (for future me)

When the GitHub OAuth client secret expires or needs rotation:

1. GitHub UI: Settings → Developer settings → OAuth Apps → "Generate a new client secret"
2. Re-seal:
   ```
   oc -n openshift-config create secret generic github-oauth-client-secret \
     --from-literal=clientSecret='<new>' \
     --dry-run=client -o yaml | \
   kubeseal --controller-namespace sealed-secrets --format yaml \
     > components/cluster-config/oauth-idp/templates/sealed-github-oauth-client-secret.yaml
   ```
3. `git commit + push`. Argo applies, sealed-secrets controller updates the
   underlying Secret, oauth-openshift picks it up on next read (no restart
   strictly needed, but bouncing `oc -n openshift-authentication delete pod -l app=oauth-openshift`
   forces an immediate refresh).

## What I'd do differently

- Register OAuth Apps under the org from the start. The cost of getting it
  wrong is ~10 minutes; the cost of doing it right is ~10 seconds (different
  URL, otherwise identical flow).
- When sealing a credential that just got rotated, paste it into a `cat | wc -c`
  first to verify the length matches what GitHub showed. Catches truncated
  pastes before they reach kubeseal.
- The `OAuth/cluster` singleton-adoption pattern is fine as long as you
  understand that Argo will wipe anything *not* declared in the chart on
  first sync. A bare cluster has empty `identityProviders`, so adoption is
  safe; an inherited cluster with manual IdP config would lose it.
