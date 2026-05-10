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
  clusterAdminUsers:
    - "sudoom"
```

`organizations` is required for security — without it any GitHub user with a
valid token can authenticate. `teams` is optional and not used here.
`clusterAdminUsers` populates an OpenShift `Group` named `cluster-admins`
and a single Group-bound `ClusterRoleBinding` to `cluster-admin` — see the
"Argo UI RBAC gap" section below for why the indirection through a Group
matters.

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
| `templates/group-cluster-admins.yaml` | OpenShift `Group/cluster-admins` populated from `github.clusterAdminUsers` |
| `templates/clusterrolebinding-github.yaml` | Binds `Group/cluster-admins` → `cluster-admin` ClusterRole |
| `values.yaml` | `clientID`, `organizations`, `teams`, `clusterAdminUsers` |
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

## Update 2026-05-10: the Argo UI RBAC gap

Two days after the IdP shipped, attempting to log into Argo via the OpenShift
button (Dex `openShiftOAuth: true`) revealed the missed half of the work:
auth worked, but the user landed in a "no apps visible, no actions allowed"
view. `oc whoami` was happy, `oc auth can-i '*' '*' --all-namespaces` printed
`yes` — so the K8s side was fine. Argo's UI was the regression.

### Why it happened

`argocd-rbac-cm` (operator-managed; lives at `openshift-gitops/argocd-rbac-cm`)
ships with this default policy from the OpenShift GitOps operator:

```
g, system:cluster-admins, role:admin
g, cluster-admins, role:admin
policy.default: ""
scopes: '[groups]'
```

The first rule is a virtual group OpenShift only assigns to `kube:admin`,
not to users with cluster-admin via a regular ClusterRoleBinding. The second
rule keys on a real OpenShift `Group` named `cluster-admins` — but no such
Group existed on this cluster. `policy.default: ""` denies everything else.

When `sudoom` logged in, Dex emitted a JWT carrying the OpenShift User's
`groups` claim. `oc get user sudoom -o yaml` showed the smoking gun:

```yaml
apiVersion: user.openshift.io/v1
fullName: Vadzim Dziadziulia
groups: null            # ← nothing
identities:
  - github:32463123
kind: User
name: sudoom
```

`groups: null`. The `cluster-admin` ClusterRoleBinding the IdP chart shipped
was bound to `User: sudoom` directly, which was the right answer for K8s
RBAC but invisible to Argo's group-keyed policy. Argo got `groups: []` from
Dex, matched neither admin rule, fell through to `policy.default`, and
silently denied everything.

This is the textbook "two RBAC layers, one configured, one forgotten"
mistake. K8s RBAC was complete on day 1; Argo RBAC was untouched.

### The fix

Three options surfaced:

1. **Patch `argocd-rbac-cm` directly with `g, sudoom, role:admin`.** Simplest
   on paper, but `argocd-rbac-cm` is owned by the operator-managed `ArgoCD`
   CR, so the patch has to land on the CR's `spec.rbac.policy` field — which
   means GitOps-adopting a CR that the operator already created. Doable with
   ServerSideApply, but it's architectural surface for a one-line config.
2. **Loosen `policy.default` to `role:admin`.** Authenticated → admin. Defen-
   sible here because the GitHub IdP already gates auth to the
   `sudoom-homelab` org, but it's the most permissive option and any future
   "give a non-admin a read-only login" need would force a redesign.
3. **Add an OpenShift `Group/cluster-admins` containing the configured
   users.** Reuses the `g, cluster-admins, role:admin` rule already in
   `argocd-rbac-cm` — no Argo-CR surgery, the IdP chart stays self-contained,
   and adding a user is a one-line edit in `values.yaml`.

Picked option 3 — it's small, GitOps-clean, and turns out to align with
exactly what the operator's default policy was assuming. Concretely:

- `values.yaml`: rename `clusterAdminUser: "sudoom"` to a list:
  `clusterAdminUsers: ["sudoom"]`.
- New template `templates/group-cluster-admins.yaml` rendering an OpenShift
  `Group/cluster-admins` with `users: <list>`.
- Update the existing `templates/clusterrolebinding-github.yaml` to bind
  `Group/cluster-admins` → `cluster-admin` (instead of `User: sudoom`),
  renaming the CRB to `github-cluster-admins` to reflect the new shape.

The CRB rename is technically a delete-then-create transition — there's a
sub-second window during sync where neither the old User-bound CRB nor the
new Group-bound CRB exists. Acceptable here because (a) the kubeadmin
break-glass remains active, (b) tokens already issued to `sudoom` are
authenticated independent of CRB state — only authz fails during the gap,
and only for the milliseconds Argo takes to apply the new CRB after pruning
the old one.

### Rendered diff

`oc diff` showed three deltas:

```
+ Group/cluster-admins                        users: [sudoom]
+ ClusterRoleBinding/github-cluster-admins    subjects: Group cluster-admins → cluster-admin
- ClusterRoleBinding/github-sudoom-cluster-admin   (pruned by Argo on sync)
```

(Plus two cosmetic `argocd.argoproj.io/tracking-id` re-annotations on the
already-tracked `OAuth/cluster` and `SealedSecret`. Argo re-adds them on
sync.)

### Verification: User.groups vs computed groups

A near-miss after sync. `oc get user sudoom -o yaml` still showed
`groups: null` — the static User.groups field is the snapshot from the
last login. I worried for a moment that Dex would emit `groups: []`
regardless of the new `Group/cluster-admins` because the User CR didn't
reflect it.

The truth is better. OpenShift exposes a *computed* group endpoint at
`/apis/user.openshift.io/v1/users/~` that merges User.groups with
membership in any `Group` listing the user. Querying it as `sudoom`:

```
$ oc get --raw '/apis/user.openshift.io/v1/users/~' | jq '{name,groups,identities}'
{
  "name": null,
  "groups": [
    "cluster-admins",
    "system:authenticated",
    "system:authenticated:oauth"
  ],
  "identities": ["github:32463123"]
}
```

`cluster-admins` shows up dynamically — the User CR's static field stays
null, but the live endpoint Dex actually uses returns the merged set.
This means the Group-only fix is sufficient: no `oc adm groups add-users`
bootstrap, no User CR mutation, no re-login at the OpenShift layer.

### Confirmed

After Argo synced (`oauth-idp` app on `d0b43ca`, `Synced/Healthy`),
opening Argo's UI in an incognito window → **Log in via OpenShift** →
GitHub authorize → landed in Argo with all Applications visible, sync /
refresh / hard-refresh enabled. The fix took on first login.

One caveat captured in the chart README: **existing browser sessions
held stale JWTs** issued before `Group/cluster-admins` existed. Argo
doesn't re-evaluate group membership until a fresh token is issued, so
old sessions need a logout + login (or a private window) once. Same
applies after any rebuild that recreates the Group.

### Lesson

Whenever a chart configures *authentication* into a stack with its own
*authorization* layer, do the second half. For OpenShift GitOps in
particular: the operator's default policy is the cheat sheet — it tells
you exactly which groups it expects to see (`cluster-admins`), and shipping
that Group via the IdP chart is cheaper than fighting the operator-managed
ConfigMap.

If a future cluster needs more granular roles (e.g. a `developers` Group
with `role:readonly`), the same pattern extends: list the groups in
`values.yaml`, render the matching `Group` resources, ensure the
operator-managed `argocd-rbac-cm` rules cover them or extend
`spec.rbac.policy` on the ArgoCD CR.

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
