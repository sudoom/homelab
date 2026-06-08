#!/usr/bin/env bash
# Extracts the break-glass-admin SA token from the cluster and writes a
# standalone kubeconfig at ~/.kube/config-breakglass (mode 0600).
#
# Run once after the chart at components/cluster-config/break-glass-sa/
# has synced. Re-run after rotating the Secret to pick up a fresh token.
#
# Prerequisites: a working `oc` session with permission to read
# automation/break-glass-admin-token. Bootstrap from the operator's normal
# OAuth-issued token; subsequent runs can use this same kubeconfig if
# you prefer.
#
# See components/cluster-config/break-glass-sa/README.md for the full
# operational context.

set -euo pipefail

OUT="${KUBECONFIG_BREAKGLASS:-$HOME/.kube/config-breakglass}"
NS="${BREAKGLASS_NS:-automation}"
SA="${BREAKGLASS_SA:-break-glass-admin}"
SECRET="${SA}-token"
SERVER="${BREAKGLASS_SERVER:-https://api.okd.sudops.pl:6443}"
CLUSTER_NAME="${BREAKGLASS_CLUSTER:-okd}"
CONTEXT_NAME="${BREAKGLASS_CONTEXT:-breakglass}"

TOKEN_B64="$(oc -n "${NS}" get secret "${SECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
CA_B64="$(oc -n "${NS}" get secret "${SECRET}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"

if [[ -z "${TOKEN_B64}" || -z "${CA_B64}" ]]; then
  cat >&2 <<EOF
ERROR: secret ${NS}/${SECRET} not populated.

Possible causes:
  - The chart at components/cluster-config/break-glass-sa/ hasn't synced yet.
    Check: oc -n openshift-gitops get application break-glass-sa
  - kube-controller-manager hasn't reconciled the Secret yet (normally <10s).
    Wait a moment and re-run.
  - The current oc session doesn't have permission to read the Secret.
    Re-login as a user with read access to automation/${SECRET}.
EOF
  exit 1
fi

TOKEN="$(printf '%s' "${TOKEN_B64}" | base64 -d)"

mkdir -p "$(dirname "${OUT}")"

# Write atomically — rename is atomic on POSIX, partial files won't be picked up.
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

cat > "${TMP}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA_B64}
contexts:
- name: ${CONTEXT_NAME}
  context:
    cluster: ${CLUSTER_NAME}
    user: ${SA}
users:
- name: ${SA}
  user:
    token: ${TOKEN}
current-context: ${CONTEXT_NAME}
EOF

chmod 600 "${TMP}"
mv "${TMP}" "${OUT}"
trap - EXIT

cat <<EOF
Wrote ${OUT} (mode 0600).

Test:
  KUBECONFIG=${OUT} oc whoami
  KUBECONFIG=${OUT} oc get nodes

WARNING: this kubeconfig has cluster-admin scope. Treat it like a kubeadmin
password — do not commit, do not back up to cloud-synced directories.
EOF
