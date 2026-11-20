#!/bin/bash
# Entry point of the okderators-cert-manager-build Job (see README.md in this directory). Adapted from
# the other okderators build Jobs under tests/: same contract lines, tool pins, log persistence, lock,
# prune and push guards; it runs the pipeline's cert-manager/build.sh and checks the 1.21 bundle.
#
# Runs as root in a privileged quay.io/podman/stable pod in namespace okd-build, with the PVC
# cert-manager-build-storage mounted at /var/lib/containers (subPath containers) and /work (subPath work).
#
# Inputs (env, set by job-template.yaml):
#   MODE                full | catalog
#   PIPELINE_REPO       okd-operator-pipeline clone URL
#   PIPELINE_BRANCH     MODE=full: the branch to build (cert-manager-1.21)
#   OPERATOR_COMMIT     MODE=full: the cert-manager/operator gitlink the branch must record (40 hex)
#   CERT_MANAGER_COMMIT MODE=full: the cert-manager/cert-manager gitlink the branch must record (40 hex)
#   DATE                YYYY-MM-DD-HHMMSS, new per run; in MODE=full the image tags' suffix
#   BASE_REGISTRY       must be zot.apps.okd.sudops.pl/okd-test or a path under it
#   CATALOG_BRANCHES    MODE=catalog only, passed through to catalog-edit.sh
#   BUNDLES             MODE=catalog only, passed through to catalog-edit.sh
#                       (<catalog-branch>=<bundle ref@digest>, space-separated)
#   IMAGE_BRANCH        MODE=catalog only, passed through to catalog-edit.sh (default release-5.0)
#   OKD_VERSION         optional, leave empty. cert-manager/build.sh sets MAJOR=1 and MINOR=21 itself,
#                       so OKD_VERSION only names the payload common.sh reads with `oc adm release info`
#                       when it is sourced; it does not change a tag, the CSV or a base image.
# MODE=catalog pushes one image, ${BASE_REGISTRY}/cert-manager-catalog:${DATE}, chosen and guarded here.
#
# Laptop use (no Job, no cluster; bash 3.2 is enough, README "Bundle checks on the laptop"):
#   bash build.sh extract-bundle <bundle ref> <dir>     the Job's bundle_extract: <dir>/fs, <dir>/config.json
#   bash build.sh check-bundle <bundle root> [<work>]   the Job's bundle checks against <bundle root>
#                                                       (manifests/ + metadata/), expectations from CHECK_*
#
# Machine-greppable output (everything else is free-form):
#   STEP <name> START|END <epoch seconds>
#   DISK <bytes>                     du of /var/lib/containers + /work, after every step (and twice
#                                    around the prune that starts MODE=full)
#   PUSHED <ref>@<digest> <bytes>    bytes = config + layer sizes in the registry manifest
#   CHECK <name> PASS|FAIL|INFO|SKIP <detail>   (INFO: recorded only; SKIP: laptop only, tool missing)
#   RESULT PASS|FAIL <reason>
# The contract lines are also appended to /work/logs/cert-manager-build-<MODE>-<DATE>.contract, and the
# whole output is copied to /work/logs/cert-manager-build-<MODE>-<DATE>.log, so both survive a deleted
# pod or a rotated container log. A lock on /work/.lock keeps a second run off the same PVC.
set -euo pipefail
# bash 4.4+ in the Job; the laptop's bash 3.2 only runs the extract-bundle and check-bundle commands.
shopt -s inherit_errexit 2>/dev/null || true

MODE=${MODE:-}
PIPELINE_REPO=${PIPELINE_REPO:-https://github.com/sudoom/okd-operator-pipeline}
PIPELINE_BRANCH=${PIPELINE_BRANCH:-}
OPERATOR_COMMIT=${OPERATOR_COMMIT:-}
CERT_MANAGER_COMMIT=${CERT_MANAGER_COMMIT:-}
DATE=${DATE:-}
BASE_REGISTRY=${BASE_REGISTRY:-zot.apps.okd.sudops.pl/okd-test}
CATALOG_BRANCHES=${CATALOG_BRANCHES:-}
BUNDLES=${BUNDLES:-}

# zot mirrors quay.io, docker.io, ghcr.io and registry.k8s.io for the whole cluster under
# one namespace: a push outside okd-test/ could shadow a real upstream image.
REGISTRY_RE='^zot\.apps\.okd\.sudops\.pl/okd-test(/[a-z0-9]+([._-][a-z0-9]+)*)*$'

# skopeo errors that mean "this tag or repository does not exist"; anything else fails closed.
# zot answers NAME_UNKNOWN for a repository nobody has pushed yet, which skopeo prints as
# "repository name not known to registry" (the first full run, 2026-10-20). 404 must stand
# alone: every error quotes the ref, and a DATE like ...-140412 contains the digits 404.
ABSENT_RE='manifest unknown|name unknown|repository name not known|not found|(^|[^0-9])404([^0-9]|$)'

# Images the CSV references that this Job does not build: the operator's own defaults from
# config/manager/manager.yaml, which cert-manager/build.sh leaves alone (trust-manager on 1.20 and
# 1.21; approver-policy since operator #538). operator-sdk --use-image-digests pins them by digest.
# They are listed as EXTERNAL in images-by-digest; anything else outside the run's registry fails.
EXTERNAL_REF_RE='^quay\.io/jetstack/(trust-manager|cert-manager-approver-policy)@sha256:[0-9a-f]{64}$'

# What the build must be (README.md, "Verify").
OP_DIR=cert-manager                           # the operator's directory in okd-operator-pipeline
PKG=cert-manager-operator
EXPECT_RELEASE=1.21                           # MAJOR.MINOR that cert-manager/build.sh must set
OPERATOR_SUB=cert-manager/operator            # submodule paths in the pipeline repository
CERT_MANAGER_SUB=cert-manager/cert-manager
ISTIO_CSR_SUB=cert-manager/istio-csr
OPERATOR_BRANCH_PREFIX=cert-manager-          # .gitmodules: cert-manager-<OCP_SHORT> (operator)
CERT_MANAGER_BRANCH_PREFIX=release-           # .gitmodules: release-<OCP_SHORT> (cert-manager)
CSV_BASE=config/manifests/bases/cert-manager-operator.clusterserviceversion.yaml
FEATURES_GO=api/operator/v1alpha1/features.go
MIN_KUBE=1.31.0
# The bundle's objects besides its CSV, Kind/name (operator 157e4aa1fd03 bundle/manifests, 17 files
# with the CSV; Task 3 Step 1 of the plan). CHECK_OBJECTS replaces it on the laptop.
BUNDLE_OBJECTS_121='CustomResourceDefinition/challenges.acme.cert-manager.io
CustomResourceDefinition/orders.acme.cert-manager.io
CustomResourceDefinition/certificaterequests.cert-manager.io
CustomResourceDefinition/certificates.cert-manager.io
CustomResourceDefinition/clusterissuers.cert-manager.io
CustomResourceDefinition/issuers.cert-manager.io
CustomResourceDefinition/approverpolicymanagers.operator.openshift.io
CustomResourceDefinition/certmanagers.operator.openshift.io
CustomResourceDefinition/http01proxies.operator.openshift.io
CustomResourceDefinition/istiocsrs.operator.openshift.io
CustomResourceDefinition/trustmanagers.operator.openshift.io
CustomResourceDefinition/certificaterequestpolicies.policy.cert-manager.io
CustomResourceDefinition/bundles.trust.cert-manager.io
Service/cert-manager-operator-controller-manager-metrics-service
ClusterRole/cert-manager-operator-metrics-reader
ConfigMap/cert-manager-operator-trusted-ca-bundle'
REDHAT_REGISTRY_RE='registry\.redhat\.io|registry-proxy\.engineering\.redhat\.com|brew\.registry'

# Pinned tools. Every sha256 is the one the project publishes (go.dev JSON, GitHub release
# checksums files, mirror.openshift.com sha256sum.txt).
GO_VERSION=1.26.10
GO_SHA256=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5
OPERATOR_SDK_VERSION=v1.36.1
OPERATOR_SDK_SHA256=25872268c422fb63a350d85741a1f26052c953c7e9654167b0e8dbd6dbfb6c1d
OPM_VERSION=v1.74.0
OPM_SHA256=cf1bd699be72e0a4511208afdf45444fc47d21eb2ffed0c204520ff50b5a4691
YQ_VERSION=v4.54.1
YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
KUSTOMIZE_VERSION=v5.8.1
KUSTOMIZE_SHA256=029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d
OC_VERSION=4.21.36
OC_SHA256=f38cbe69694ebca49f067b9e3830f62c62c27bbe29dd00ad29c11c45509fde42

WORK=/work
RUN=$WORK/run              # wiped at the start of every run
PIPE=$RUN/pipeline
TOOLS=$WORK/tools
CACHE=$WORK/cache          # kept between runs: downloads, dnf metadata, Go caches

LOGS=$WORK/logs
LOCK=$WORK/.lock

STEP_NAME=validate
RESULT_DONE=0
CHILD=
CONTRACT=                  # set by open_logs; empty until then (stdout only)
TEE_PID=
VERIFY_FAILS=0
LAPTOP=0                   # 1 in the extract-bundle / check-bundle commands
IMAGE_VARS=()
BUNDLE_VARS=()
# The bundle checks' expectations (plain strings, so the laptop's bash 3.2 runs them too).
EXP_VERSION=               # <MAJOR>.<MINOR>.0-<DATE>
EXP_OBJECTS=$BUNDLE_OBJECTS_121
EXP_REGISTRY=              # the registry path the built images live under
EXP_MIN_KUBE=$MIN_KUBE
PUSHED_IMAGE_REFS=         # space-separated <repo>@<digest> of the images this run pushed (no bundle)
BUNDLE_REF=                # <repo>@<digest> of the bundle being checked (dropped from opm's relatedImages)
EXP_EXTERNAL='trust-manager cert-manager-approver-policy'  # quay.io/jetstack repos the CSV must reference

# ---------------------------------------------------------------------------------------
# result, traps, steps

# Every contract line goes to the contract file on the PVC first (a plain synchronous append,
# so it is there even if the pod is deleted right after), then to stdout.
contract() {
  if [[ -n $CONTRACT ]]; then echo "$*" >>"$CONTRACT" || true; fi
  echo "$*"
}

# Copy all further output to the .log file on the PVC. Exit statuses are untouched: this is
# a redirection of the shell's own stdout/stderr, not a pipeline.
open_logs() {
  local base="$LOGS/cert-manager-build-${MODE}-${DATE}"
  mkdir -p "$LOGS"
  exec > >(tee -a "${base}.log") 2>&1
  TEE_PID=${!:-}
  CONTRACT="${base}.contract"
  echo "INFO logs ${base}.log ${CONTRACT}"
}

# At exit, close our end of the tee pipe and give tee a few seconds to write the last lines.
drain_logs() {
  local i
  if [[ -z $TEE_PID ]]; then return 0; fi
  exec 1>&- 2>&-
  for i in $(seq 50); do
    if ! kill -0 "$TEE_PID" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
}

finish() {  # finish PASS|FAIL <reason...>
  RESULT_DONE=1
  contract "RESULT $*"
  if [[ $1 == PASS ]]; then exit 0; fi
  exit 1
}

on_exit() {
  local rc=$?
  if [[ $RESULT_DONE == 0 ]]; then
    contract "RESULT FAIL ${STEP_NAME} (exit ${rc})"
  fi
  drain_logs
}

on_term() {
  RESULT_DONE=1
  contract "RESULT FAIL ${STEP_NAME} (terminated)"
  if [[ -n $CHILD ]]; then kill -TERM "$CHILD" 2>/dev/null || true; fi
  exit 143
}

# One run at a time on the PVC: both would wipe /work/run and share one podman graph root.
# RWO only keeps pods on other nodes away. flock is released when this process dies.
take_lock() {
  STEP_NAME=lock
  if ! command -v flock >/dev/null; then
    # util-linux-core; default dnf cache inside the container, nothing on the shared PVC yet
    TMPDIR=/var/tmp dnf -y -q --setopt=install_weak_deps=False install util-linux-core
  fi
  exec 9>"$LOCK"
  if ! flock -n 9; then
    finish FAIL "another run holds ${LOCK}"
  fi
  echo "INFO holding ${LOCK}"
}

disk() {
  local bytes
  bytes=$(du -sx --block-size=1 /var/lib/containers "$WORK" 2>/dev/null | awk '{s += $1} END {printf "%d\n", s}') || true
  contract "DISK ${bytes:-0}"
}

step_start() {
  STEP_NAME=$1
  contract "STEP $1 START $(date +%s)"
}

step_end() {
  contract "STEP ${STEP_NAME} END $(date +%s)"
  disk
}

# Long commands run in the background so that SIGTERM (activeDeadlineSeconds, oc delete)
# is handled while they run and the log still ends with a RESULT line.
run_bg() {
  "$@" &
  CHILD=$!
  wait "$CHILD"
  CHILD=
}

first_line() {
  local out
  out=$("$@" 2>&1) || true
  echo "${out%%$'\n'*}"
}

one_line() {  # squeeze multi-line tool output into one CHECK detail
  tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//' | cut -c1-400
}

# ---------------------------------------------------------------------------------------
# inputs and environment

guard_registry() {
  if [[ ! $1 =~ $REGISTRY_RE ]]; then
    finish FAIL "registry $1 is outside zot.apps.okd.sudops.pl/okd-test"
  fi
}

validate() {
  local sha_re='^[0-9a-f]{40}$'
  case $MODE in
    full | catalog) ;;
    *) finish FAIL "MODE '${MODE}' is not full or catalog" ;;
  esac
  if [[ ! $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    finish FAIL "DATE '${DATE}' is not YYYY-MM-DD-HHMMSS"
  fi
  guard_registry "$BASE_REGISTRY"
  if [[ $MODE == full && (-z $PIPELINE_REPO || -z $PIPELINE_BRANCH) ]]; then
    finish FAIL "PIPELINE_REPO and PIPELINE_BRANCH are required"
  fi
  if [[ $MODE == full && (! $OPERATOR_COMMIT =~ $sha_re || ! $CERT_MANAGER_COMMIT =~ $sha_re) ]]; then
    finish FAIL "OPERATOR_COMMIT and CERT_MANAGER_COMMIT must be full 40-character commit hashes"
  fi
  if [[ $MODE == catalog && (! -f /scripts/catalog-edit.sh || ! -f /scripts/catalog-branches.tsv) ]]; then
    finish FAIL "catalog-edit.sh or catalog-branches.tsv not present"
  fi
}

print_inputs() {
  echo "INFO MODE=${MODE} DATE=${DATE} BASE_REGISTRY=${BASE_REGISTRY}"
  echo "INFO PIPELINE_REPO=${PIPELINE_REPO} PIPELINE_BRANCH=${PIPELINE_BRANCH}"
  echo "INFO OPERATOR_COMMIT=${OPERATOR_COMMIT} CERT_MANAGER_COMMIT=${CERT_MANAGER_COMMIT}"
  echo "INFO CATALOG_BRANCHES=${CATALOG_BRANCHES} BUNDLES=${BUNDLES} IMAGE_BRANCH=${IMAGE_BRANCH:-release-5.0}"
  echo "INFO OKD_VERSION=${OKD_VERSION:-(pipeline default)}"
  echo "INFO node=${NODE_NAME:-unknown} nproc=$(nproc)"
}

setup_env() {
  # Everything big or cached goes to the PVC, not to the container's root fs (node disk).
  export HOME=$WORK/home
  export TMPDIR=$WORK/tmp
  export GOPATH=$CACHE/gopath
  export GOMODCACHE=$CACHE/gopath/pkg/mod
  export GOCACHE=$CACHE/go-build
  export PATH=$TOOLS/bin:$TOOLS/go/bin:$GOPATH/bin:$PATH
  # git am (patches/operator.patch in init) needs a committer identity and the pod has none. git am
  # keeps each patch's own author; the author variables only matter for a plain git commit.
  export GIT_COMMITTER_NAME=okd-build
  export GIT_COMMITTER_EMAIL=okd-build@localhost
  export GIT_AUTHOR_NAME=okd-build
  export GIT_AUTHOR_EMAIL=okd-build@localhost
  export BUILDAH_ISOLATION=chroot
}

make_dirs() {  # after take_lock
  mkdir -p "$HOME" "$TMPDIR" "$TOOLS/bin" "$CACHE/dl" "$GOPATH"
}

# ---------------------------------------------------------------------------------------
# tools

fetch() {  # fetch <url> <sha256> <file name under $CACHE/dl>
  local url=$1 sum=$2 dest=$CACHE/dl/$3 got
  if [[ -f $dest ]] && echo "${sum}  ${dest}" | sha256sum -c --status; then
    return 0
  fi
  curl -fsSL --retry 5 --retry-delay 5 -o "${dest}.part" "$url"
  got=$(sha256sum "${dest}.part" | awk '{print $1}')
  if [[ $got != "$sum" ]]; then
    echo "ERROR sha256 mismatch for ${url}: got ${got}, want ${sum}"
    rm -f "${dest}.part"
    return 1
  fi
  mv "${dest}.part" "$dest"
}

install_tools() {
  local -a rpms=(git make jq skopeo tar gzip gawk findutils diffutils which)
  # The Fedora base ships curl (or curl-minimal); asking for "curl" next to curl-minimal conflicts.
  if ! command -v curl >/dev/null; then rpms+=(curl); fi
  # catalog-edit.sh and catalog-walk.py (MODE=catalog), standard library only
  if ! command -v python3 >/dev/null; then rpms+=(python3); fi
  dnf -y -q --setopt=install_weak_deps=False --setopt=system_cachedir="$CACHE/dnf" install "${rpms[@]}"

  fetch "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" "$GO_SHA256" "go${GO_VERSION}.linux-amd64.tar.gz"
  rm -rf "$TOOLS/go"
  tar -C "$TOOLS" -xzf "$CACHE/dl/go${GO_VERSION}.linux-amd64.tar.gz"

  fetch "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_linux_amd64" \
    "$OPERATOR_SDK_SHA256" "operator-sdk-${OPERATOR_SDK_VERSION}"
  install -m 0755 "$CACHE/dl/operator-sdk-${OPERATOR_SDK_VERSION}" "$TOOLS/bin/operator-sdk"

  fetch "https://github.com/operator-framework/operator-registry/releases/download/${OPM_VERSION}/linux-amd64-opm" \
    "$OPM_SHA256" "opm-${OPM_VERSION}"
  install -m 0755 "$CACHE/dl/opm-${OPM_VERSION}" "$TOOLS/bin/opm"

  fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    "$YQ_SHA256" "yq-${YQ_VERSION}"
  install -m 0755 "$CACHE/dl/yq-${YQ_VERSION}" "$TOOLS/bin/yq"

  fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    "$KUSTOMIZE_SHA256" "kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
  tar -C "$TOOLS/bin" -xzf "$CACHE/dl/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" kustomize

  fetch "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}/openshift-client-linux-${OC_VERSION}.tar.gz" \
    "$OC_SHA256" "openshift-client-linux-${OC_VERSION}.tar.gz"
  tar -C "$TOOLS/bin" -xzf "$CACHE/dl/openshift-client-linux-${OC_VERSION}.tar.gz" oc

  echo "INFO tool $(first_line go version)"
  echo "INFO tool $(first_line operator-sdk version)"
  echo "INFO tool opm $(first_line opm version)"
  echo "INFO tool $(first_line yq --version)"
  echo "INFO tool kustomize $(first_line kustomize version)"
  echo "INFO tool oc $(first_line oc version --client)"
  echo "INFO tool $(first_line podman --version)"
  echo "INFO tool $(first_line skopeo --version)"
  echo "INFO tool $(first_line git --version)"
  echo "INFO tool $(first_line jq --version)"
  echo "INFO tool $(first_line python3 --version)"
  echo "INFO tool $(first_line make --version)"
}

configure_podman() {
  # Native kernel overlay on the PVC (ext4) instead of the image's fuse-overlayfs: the pod
  # is privileged, and the graph root is a real filesystem, not the container's overlay.
  cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mountopt = "nodev"
EOF
  # The image's containers.conf already sets cgroups="disabled", cgroup_manager="cgroupfs"
  # and host namespaces for nested use. Add: no SELinux relabelling, temp copies on the PVC.
  mkdir -p /etc/containers/containers.conf.d
  cat >/etc/containers/containers.conf.d/90-okd-build.conf <<EOF
[containers]
label = false

[engine]
image_copy_tmp_dir = "${TMPDIR}"
EOF
  local info  # an assignment, so a podman failure here stops the run
  info=$(podman info --format 'driver={{.Store.GraphDriverName}} graphroot={{.Store.GraphRoot}} backing={{index .Store.GraphStatus "Backing Filesystem"}} native-diff={{index .Store.GraphStatus "Native Overlay Diff"}} d_type={{index .Store.GraphStatus "Supports d_type"}}')
  echo "INFO podman ${info}"
}

# ---------------------------------------------------------------------------------------
# pipeline

clone_pipeline() {
  rm -rf "$RUN"
  mkdir -p "$RUN"
  git clone --quiet --depth 1 --branch "$PIPELINE_BRANCH" "$PIPELINE_REPO" "$PIPE"
  echo "INFO pipeline ${PIPELINE_REPO} ${PIPELINE_BRANCH} $(git -C "$PIPE" rev-parse HEAD)"
}

# Source cert-manager/build.sh (main() does not run when sourced) and read back its variables, so
# the image list always comes from the cloned pipeline, never from here. OKD_VERSION (if set)
# is inherited from the Job's environment, as in every pipeline_step.
load_vars() {  # load_vars <base registry> <associative array name>
  local base=$1 out="$RUN/vars-${2,,}.env" k v
  local -n arr=$2
  if ! env -C "$PIPE/$OP_DIR" BASE_REGISTRY="$base" DATE="$DATE" bash -c '
      source ./build.sh
      set +x
      printf "%s=%s\n" MAJOR "$MAJOR" MINOR "$MINOR" OCP_SHORT "$OCP_SHORT" OCP_DATE "$OCP_DATE" \
        REGISTRY "$REGISTRY" OKD_VERSION "$OKD_VERSION"
      for v in $(compgen -v IMG_); do printf "%s=%s\n" "$v" "${!v}"; done
    ' >"$out" 2>"${out}.log"; then
    echo "ERROR sourcing ${OP_DIR}/build.sh with BASE_REGISTRY=${base} failed:"
    tail -n 20 "${out}.log"
    return 1
  fi
  while IFS='=' read -r k v; do
    arr[$k]=$v
  done <"$out"
  for k in $(printf '%s\n' "${!arr[@]}" | sort); do
    echo "INFO var ${k}=${arr[$k]}"
  done
}

guard_images() {  # every IMG_* in array $1 must be under registry $2 (cert-manager/build.sh has no external IMG_*)
  local -n arr=$1
  local k
  for k in "${!arr[@]}"; do
    if [[ $k == IMG_* && ${arr[$k]} != "$2/"* ]]; then
      finish FAIL "${k}=${arr[$k]} is outside $2"
    fi
  done
}

split_vars() {  # fill IMAGE_VARS (built images, operator included) and BUNDLE_VARS from array $1
  local -n arr=$1
  local k
  IMAGE_VARS=()
  BUNDLE_VARS=()
  for k in $(printf '%s\n' "${!arr[@]}" | sort); do
    if [[ $k == IMG_BUNDLE* ]]; then
      BUNDLE_VARS+=("$k")
    elif [[ $k == IMG_* ]]; then
      IMAGE_VARS+=("$k")
    fi
  done
  if [[ ${#IMAGE_VARS[@]} == 0 || ${#BUNDLE_VARS[@]} != 1 ]]; then
    finish FAIL "${OP_DIR}/build.sh defines no IMG_* or not exactly one IMG_BUNDLE* variable"
  fi
}

pipeline_step() {  # pipeline_step <registry> <build.sh step>
  step_start "$2"
  run_bg env -C "$PIPE/$OP_DIR" BASE_REGISTRY="$1" DATE="$DATE" bash ./build.sh "$2"
  step_end
}

gitlink() {  # gitlink <submodule path>: the commit the cloned pipeline branch records for it
  git -C "$PIPE" ls-tree HEAD "$1" | awk '$2 == "commit" {print $3}'
}

# ---------------------------------------------------------------------------------------
# registry helpers

manifest_raw() {
  skopeo inspect --raw --retry-times 3 "docker://$1"
}

ref_digest() {  # digest of the exact manifest bytes the registry serves for a ref
  manifest_raw "$1" | sha256sum | awk '{print "sha256:" $1}'
}

ref_bytes() {  # ref_bytes <repo> <digest>: config + layer bytes, summed over an index
  local raw d sum=0 n
  raw=$(manifest_raw "$1@$2")
  if jq -e 'has("manifests")' >/dev/null <<<"$raw"; then
    for d in $(jq -r '.manifests[].digest' <<<"$raw"); do
      n=$(manifest_raw "$1@$d" | jq '[.config.size // 0, (.layers // [])[].size] | add')
      sum=$((sum + n))
    done
    echo "$sum"
  else
    jq '[.config.size // 0, (.layers // [])[].size] | add' <<<"$raw"
  fi
}

report_pushed() {  # report_pushed <array name> <IMG_* names...>
  local -n arr=$1
  shift
  local name ref repo digest bytes
  for name in "$@"; do
    ref=${arr[$name]}
    repo=${ref%:*}
    digest=$(ref_digest "$ref")
    DIGEST[$repo]=$digest
    bytes=$(ref_bytes "$repo" "$digest") || bytes=unknown
    contract "PUSHED ${ref}@${digest} ${bytes}"
  done
}

tag_check() {  # tag_check <ref>. A run never re-pushes a tag
  local ref=$1 err
  if err=$(skopeo inspect --raw "docker://${ref}" 2>&1 >/dev/null); then
    finish FAIL "tag exists ${ref}"
  fi
  if ! grep -qiE "$ABSENT_RE" <<<"$err"; then
    echo "ERROR cannot tell whether ${ref} exists: ${err##*$'\n'}"
    finish FAIL "tag check failed"
  fi
  echo "INFO ${ref} does not exist yet"
}

# ---------------------------------------------------------------------------------------
# checks on the pipeline tree (MODE=full only, after the clone and after init)

check() {  # check <name> PASS|FAIL|INFO|SKIP <detail...>
  contract "CHECK $1 $2 ${*:3}"
  if [[ $2 == FAIL ]]; then VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

# gitmodules-branch: .gitmodules declares cert-manager-<OCP_SHORT> for the operator and
# release-<OCP_SHORT> for cert-manager (OCP_SHORT 1.21 from cert-manager/build.sh MAJOR/MINOR).
# .gitmodules is not what gets built (the gitlink is: operator-commit, cert-manager-commit), but a
# mismatch means the branch and its build.sh disagree, so mode_full stops before building.
check_gitmodules_branch() {  # <pipeline dir> <OCP_SHORT>; returns 1 on FAIL
  local pipe=$1 short=$2 sub want got istio
  local -a seen=() bad=()
  for sub in "$OPERATOR_SUB" "$CERT_MANAGER_SUB"; do
    if [[ $sub == "$OPERATOR_SUB" ]]; then want="${OPERATOR_BRANCH_PREFIX}${short}"; else want="${CERT_MANAGER_BRANCH_PREFIX}${short}"; fi
    got=$(git config -f "${pipe}/.gitmodules" "submodule.${sub}.branch" 2>/dev/null || echo none)
    seen+=("${sub}=${got}")
    if [[ $got != "$want" ]]; then bad+=("${sub}=${got} (want ${want})"); fi
  done
  istio=$(git config -f "${pipe}/.gitmodules" "submodule.${ISTIO_CSR_SUB}.branch" 2>/dev/null || echo none)
  if [[ ${#bad[@]} == 0 ]]; then
    check gitmodules-branch PASS "${seen[*]}, the release of OCP_SHORT ${short}; ${ISTIO_CSR_SUB}=${istio} (recorded)"
  else
    check gitmodules-branch FAIL "${bad[*]} in .gitmodules (OCP_SHORT ${short} from ${OP_DIR}/build.sh)"
    return 1
  fi
}

# operator-commit: init (submodule_reset to the gitlink, `git submodule update --init`, then
# `git am -3 ../patches/operator.patch`) leaves the operator submodule one commit ahead of the gitlink:
# HEAD~1 must be the recorded gitlink = OPERATOR_COMMIT, HEAD the patch's commit, the tree clean.
operator_commit() {
  local sub=$PIPE/$OPERATOR_SUB link base head subj want_subj dirty
  if [[ ! -f $PIPE/$OP_DIR/patches/operator.patch ]]; then
    check operator-commit FAIL "${OP_DIR}/patches/operator.patch is missing on ${PIPELINE_BRANCH}"
    return 0
  fi
  link=$(gitlink "$OPERATOR_SUB")
  base=$(git -C "$sub" rev-parse HEAD~1 2>/dev/null) || base=none
  head=$(git -C "$sub" rev-parse HEAD 2>/dev/null) || head=none
  subj=$(git -C "$sub" log -1 --format=%s 2>/dev/null) || subj=none
  want_subj=$(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$PIPE/$OP_DIR/patches/operator.patch" | head -n 1) || want_subj=
  dirty=$(git -C "$sub" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty=unknown
  if [[ $link == "$OPERATOR_COMMIT" && $base == "$link" && $head != "$link" && -n $want_subj \
    && $subj == "$want_subj" && $dirty == 0 ]]; then
    check operator-commit PASS "${OPERATOR_SUB} HEAD~1 ${base} = gitlink = OPERATOR_COMMIT; HEAD ${head} is the patch commit '${subj}'; clean tree"
  else
    check operator-commit FAIL "${OPERATOR_SUB} gitlink ${link:-none} (OPERATOR_COMMIT ${OPERATOR_COMMIT}), HEAD~1 ${base}, HEAD ${head} '${subj}' (want the patch subject '${want_subj:-none}'), ${dirty} changed paths"
  fi
}

# cert-manager-commit: no patch for cert-manager, so its HEAD is the gitlink = CERT_MANAGER_COMMIT.
# The operand's real version (v1.21.3) is proven here: the CSV's *_VERSION env carries the build tag.
cert_manager_commit() {
  local sub=$PIPE/$CERT_MANAGER_SUB link head dirty patch=none
  link=$(gitlink "$CERT_MANAGER_SUB")
  head=$(git -C "$sub" rev-parse HEAD 2>/dev/null) || head=none
  dirty=$(git -C "$sub" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty=unknown
  if [[ -f $PIPE/$OP_DIR/patches/cert-manager.patch ]]; then patch=patches/cert-manager.patch; fi
  echo "INFO ${ISTIO_CSR_SUB} HEAD $(git -C "$PIPE/$ISTIO_CSR_SUB" rev-parse HEAD 2>/dev/null || echo none) gitlink $(gitlink "$ISTIO_CSR_SUB")"
  if [[ $link == "$CERT_MANAGER_COMMIT" && $head == "$link" && $dirty == 0 && $patch == none ]]; then
    check cert-manager-commit PASS "${CERT_MANAGER_SUB} HEAD ${head} = gitlink = CERT_MANAGER_COMMIT, clean tree, no patch"
  else
    check cert-manager-commit FAIL "${CERT_MANAGER_SUB} gitlink ${link:-none} (CERT_MANAGER_COMMIT ${CERT_MANAGER_COMMIT}), HEAD ${head}, ${dirty} changed paths, patch ${patch}"
  fi
}

# patch-applied: init's `git am -3` exited 0 (init runs under set -e, so the step got here), no am
# is left half-done, the patch commit changes exactly the files the patch names, and the patched CSV
# base carries the OKD branding.
patch_applied() {
  local sub=$PIPE/$OPERATOR_SUB patch=$PIPE/$OP_DIR/patches/operator.patch gd want got am=none brand=0
  if [[ ! -f $patch ]]; then
    check patch-applied FAIL "${OP_DIR}/patches/operator.patch is missing on ${PIPELINE_BRANCH}"
    return 0
  fi
  want=$(grep '^diff --git a/' "$patch" | awk '{print substr($3, 3)}' | LC_ALL=C sort | paste -sd ' ' -) || want=
  got=$(git -C "$sub" diff --name-only HEAD~1 HEAD 2>/dev/null | LC_ALL=C sort | paste -sd ' ' -) || got=none
  gd=$(git -C "$sub" rev-parse --absolute-git-dir 2>/dev/null) || gd=
  if [[ -z $gd || -d $gd/rebase-apply ]]; then am=in-progress; fi
  if grep -q '^    support: OKD Community$' "$sub/$CSV_BASE" && grep -q '^  displayName: cert-manager Operator for OKD$' "$sub/$CSV_BASE"; then
    brand=1
  fi
  if [[ -n $want && $got == "$want" && $am == none && $brand == 1 ]]; then
    check patch-applied PASS "git am -3 patches/operator.patch exited 0; HEAD changes ${got}; ${CSV_BASE} has support 'OKD Community' and displayName 'cert-manager Operator for OKD'"
  else
    check patch-applied FAIL "patch files '${want:-none}', HEAD~1..HEAD files '${got}', am ${am}, OKD branding in the CSV base ${brand}"
  fi
}

# feature-defaults: the operator's feature gates as features.go declares them. HTTP01Proxy writes an
# nftables MachineConfig (node reroll), so it must default to false; no gate besides IstioCSR may
# default to true (plan Task 3 Step 1).
feature_defaults() {
  local f=$PIPE/$OPERATOR_SUB/$FEATURES_GO gates http on=
  if [[ ! -f $f ]]; then
    check feature-defaults FAIL "${FEATURES_GO} is missing"
    return 0
  fi
  gates=$(sed -n -E 's/^[[:space:]]*Feature([A-Za-z0-9]+):[[:space:]]*\{Default:[[:space:]]*(true|false).*/\1=\2/p' "$f" | paste -sd ' ' -)
  http=$(tr ' ' '\n' <<<"$gates" | sed -n 's/^HTTP01Proxy=//p')
  on=$(tr ' ' '\n' <<<"$gates" | grep '=true$' | grep -v '^IstioCSR=' | paste -sd ' ' - || true)
  if [[ $http == false && -z $on ]]; then
    check feature-defaults PASS "${gates}"
  else
    check feature-defaults FAIL "${gates:-no gates parsed}; HTTP01Proxy default '${http:-not found}' (want false); other gates on by default: ${on:-none}"
  fi
}

# ---------------------------------------------------------------------------------------
# bundle checks. Plain variables and bash 3.2 constructs only: the laptop runs them too
# (check-bundle). Inputs: EXP_VERSION, EXP_OBJECTS, EXP_REGISTRY, EXP_MIN_KUBE, PUSHED_IMAGE_REFS.
# <work> holds the outputs (files.json, csv.json, images.txt) and, if opm rendered the bundle,
# render.json; <root> is the bundle's files (manifests/, metadata/).

# The bundle image's files as the registry serves them: skopeo copies the manifest and layers to a
# dir: layout (blobs named by their hex digest), and each layer is unpacked into <dir>/fs in order.
bundle_extract() {  # bundle_extract <ref> <dir>
  local ref=$1 dir=$2 hex blob
  rm -rf "$dir/image" "$dir/fs"
  mkdir -p "$dir/fs" || return 1
  skopeo copy --quiet --retry-times 3 "docker://${ref}" "dir:${dir}/image" || return 1
  skopeo inspect --config --retry-times 3 "docker://${ref}" >"$dir/config.json" || return 1
  if [[ $(jq '.layers | length' "$dir/image/manifest.json" 2>/dev/null || echo 0) == 0 ]]; then
    echo "ERROR ${ref}: no layers in the copied manifest"
    return 1
  fi
  for hex in $(jq -r '.layers[].digest | sub("^sha256:"; "")' "$dir/image/manifest.json"); do
    blob=$dir/image/$hex
    if [[ ! -f $blob && -f ${blob}.tar ]]; then blob=${blob}.tar; fi
    tar -xf "$blob" -C "$dir/fs" || return 1
  done
  [[ -d $dir/fs/manifests ]] || return 1
  echo "INFO bundle files: $(cd "$dir/fs" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | paste -sd ' ' -)"
}

# files.json: every document of every file under <root>/manifests (yq). If <work>/render.json exists
# (opm render, the Job): bundle.json, objects.json (decoded olm.bundle.object) and csv.json from it;
# otherwise (laptop without opm) csv.json comes from the files.
bundle_prepare() {  # <work> <root>
  local work=$1 root=$2 f
  : >"$work/files.ndjson"
  : >"$work/files.txt"
  if [[ -d $root/manifests ]]; then
    (cd "$root/manifests" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) >"$work/files.txt"
    while read -r f; do
      yq -o json -I0 '.' "$root/manifests/$f" >>"$work/files.ndjson"
    done <"$work/files.txt"
  fi
  jq -s '[.[] | select(. != null)]' "$work/files.ndjson" >"$work/files.json"
  if [[ -s $work/render.json ]]; then
    jq -s 'map(select(.schema == "olm.bundle")) | first' "$work/render.json" >"$work/bundle.json"
    jq '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson]' \
      "$work/bundle.json" >"$work/objects.json"
    jq '[.[] | select(.kind == "ClusterServiceVersion")] | first' "$work/objects.json" >"$work/csv.json"
  else
    rm -f "$work/bundle.json" "$work/objects.json"
    jq '[.[] | select(.kind == "ClusterServiceVersion")] | first' "$work/files.json" >"$work/csv.json"
  fi
}

obj_list() {  # <objects json array file>: sorted Kind/name lines
  jq -r '.[] | "\(.kind)/\(.metadata.name // "-")"' "$1" | LC_ALL=C sort
}

want_list() {  # EXP_OBJECTS plus the CSV, sorted Kind/name lines
  printf '%s\n' $EXP_OBJECTS "ClusterServiceVersion/${PKG}.v${EXP_VERSION}" | LC_ALL=C sort
}

# bundle-objects: exactly the expected objects by kind and name, one per file under manifests/, and
# (when opm rendered the bundle) the same set in the render.
check_bundle_objects() {  # <work>
  local work=$1 want files render=n/a rendered nwant nfiles missing extra crds
  want=$(want_list)
  files=$(obj_list "$work/files.json")
  nwant=$(printf '%s\n' "$want" | wc -l | tr -d ' ')
  nfiles=$(wc -l <"$work/files.txt" | tr -d ' ')
  if [[ -f $work/objects.json ]]; then
    rendered=$(obj_list "$work/objects.json")
    if [[ $rendered == "$want" ]]; then
      render=same
    else
      render="differs (missing: $(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$rendered") | paste -sd ' ' -);"
      render="${render} unexpected: $(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$rendered") | paste -sd ' ' -))"
    fi
  fi
  missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$files") | paste -sd ' ' -)
  extra=$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$files") | paste -sd ' ' -)
  crds=$(printf '%s\n' "$files" | grep -c '^CustomResourceDefinition/' || true)
  if [[ $files == "$want" && $nfiles == "$nwant" && $render != differs* ]]; then
    check bundle-objects PASS "${nwant} objects as expected (${crds} CRDs, ClusterServiceVersion/${PKG}.v${EXP_VERSION}, $(printf '%s\n' "$files" | grep -v -E '^(CustomResourceDefinition|ClusterServiceVersion)/' | paste -sd ' ' -)); manifests/ ${nfiles} files; opm render: ${render/n\/a/not run}"
  else
    check bundle-objects FAIL "missing: ${missing:-none}; unexpected: ${extra:-none}; manifests/ ${nfiles} files, want ${nwant}; opm render: ${render/n\/a/not run}"
  fi
}

# csv-name: CSV cert-manager-operator.v<EXP_VERSION> with spec.version EXP_VERSION; the bundle's
# package annotation; with opm: the olm.bundle's package and olm.package version.
check_csv_name() {  # <work> <root>
  local work=$1 root=$2 want_name="${PKG}.v${EXP_VERSION}" n pkgfile=none pkg=n/a pv=n/a chans=none
  n=$(jq -r '[.metadata.name, .spec.version] | join(" ")' "$work/csv.json")
  if [[ -f $root/metadata/annotations.yaml ]]; then
    pkgfile=$(yq '.annotations["operators.operatorframework.io.bundle.package.v1"]' "$root/metadata/annotations.yaml")
    chans=$(yq '.annotations["operators.operatorframework.io.bundle.channels.v1"]' "$root/metadata/annotations.yaml")
  fi
  if [[ -f $work/bundle.json ]]; then
    pkg=$(jq -r '.package // "none"' "$work/bundle.json")
    pv=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "$work/bundle.json")
  fi
  if [[ $n == "${want_name} ${EXP_VERSION}" && $pkgfile == "$PKG" \
    && ($pkg == n/a || ($pkg == "$PKG" && $pv == "$EXP_VERSION")) ]]; then
    check csv-name PASS "${n}; package annotation ${pkgfile}; opm render package ${pkg}, olm.package version ${pv}"
  else
    check csv-name FAIL "CSV '${n}', package annotation ${pkgfile}, opm render package ${pkg} version ${pv}; want '${want_name} ${EXP_VERSION}', package ${PKG}"
  fi
  # The channels in the bundle's annotations are not what OLM uses here: the catalog entry is.
  echo "INFO bundle channels annotation: ${chans}"
}

# skiprange: what cert-manager/build.sh writes into the CSV base: olm.skipRange '>=1.0.0 <EXP_VERSION',
# no replaces, no skips. The catalog entry carries the real replaces edge (MODE=catalog).
check_skiprange() {  # <work>
  local work=$1 sr rep sk want=">=1.0.0 <${EXP_VERSION}"
  sr=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$work/csv.json")
  rep=$(jq -r '.spec.replaces // "none"' "$work/csv.json")
  sk=$(jq -c '.spec.skips // empty' "$work/csv.json")
  sk=${sk:-none}
  if [[ $sr == "$want" && $rep == none && $sk == none ]]; then
    check skiprange PASS "olm.skipRange '${sr}', no replaces, no skips"
  else
    check skiprange FAIL "olm.skipRange '${sr}' (want '${want}'), replaces ${rep}, skips ${sk} (want none)"
  fi
}

check_min_kube() {  # <work>
  local mk
  mk=$(jq -r '.spec.minKubeVersion // "none"' "$1/csv.json")
  if [[ $mk == "$EXP_MIN_KUBE" ]]; then
    check min-kube PASS "minKubeVersion ${mk}"
  else
    check min-kube FAIL "minKubeVersion ${mk}, want ${EXP_MIN_KUBE}"
  fi
}

# no-max-openshift: an olm.maxOpenShiftVersion (CSV annotation, olm.properties, bundle property or
# file) would make the cluster report Upgradeable=False. Searched as text in every source.
check_no_max_openshift() {  # <work> <root>
  local work=$1 root=$2 hits=
  if grep -q 'maxOpenShiftVersion' "$work/csv.json"; then hits="${hits} CSV"; fi
  if [[ -f $work/render.json ]] && grep -q 'maxOpenShiftVersion' "$work/render.json"; then hits="${hits} opm-render"; fi
  if [[ -d $root ]] && grep -rq 'maxOpenShiftVersion' "$root"; then hits="${hits} bundle-files"; fi
  if [[ -z $hits ]]; then
    check no-max-openshift PASS "no olm.maxOpenShiftVersion in the CSV, the bundle files$([[ -f $work/render.json ]] && echo ' or the opm render')"
  else
    check no-max-openshift FAIL "olm.maxOpenShiftVersion found in:${hits}"
  fi
}

# version-env: the pipeline sets OPERAND_IMAGE_VERSION, ISTIOCSR_OPERAND_IMAGE_VERSION and
# OPERATOR_IMAGE_VERSION to its build version, each exactly once. The other *_VERSION env values
# (trust-manager, approver-policy: upstream versions) are printed as INFO.
check_version_env() {  # <work>
  local work=$1 got want
  got=$(jq -r '.spec.install.spec.deployments[]?.spec.template.spec.containers[]? | .env[]?
    | select(.name | test("^(OPERAND_IMAGE_VERSION|ISTIOCSR_OPERAND_IMAGE_VERSION|OPERATOR_IMAGE_VERSION)$"))
    | "\(.name)=\(.value // "")"' "$work/csv.json" | LC_ALL=C sort | paste -sd ' ' -)
  want="ISTIOCSR_OPERAND_IMAGE_VERSION=${EXP_VERSION} OPERAND_IMAGE_VERSION=${EXP_VERSION} OPERATOR_IMAGE_VERSION=${EXP_VERSION}"
  echo "INFO other version env: $(jq -r '.spec.install.spec.deployments[]?.spec.template.spec.containers[]? | .env[]?
    | select(.name | test("_VERSION$")) | select(.name | test("^(OPERAND_IMAGE_VERSION|ISTIOCSR_OPERAND_IMAGE_VERSION|OPERATOR_IMAGE_VERSION)$") | not)
    | "\(.name)=\(.value // "")"' "$work/csv.json" | paste -sd ' ' -)"
  if [[ $got == "$want" ]]; then
    check version-env PASS "${got}"
  else
    check version-env FAIL "${got:-none}; want ${want}"
  fi
}

# images-by-digest: relatedImages (CSV, and the olm.bundle when opm rendered it), every deployment
# container and init container image, every RELATED_IMAGE_* / *_IMAGE env value and the
# containerImage annotation is @sha256:. Refs under EXP_REGISTRY/ must be digests this run pushed,
# and every pushed image must be referenced; the only other refs allowed are EXTERNAL_REF_RE
# (trust-manager, approver-policy), listed as EXTERNAL, and each repository named in EXP_EXTERNAL
# must be referenced by exactly one digest. opm render lists the bundle image itself in the
# olm.bundle's relatedImages: that one exact ref (BUNDLE_REF) is dropped from the opm source only,
# so the bundle anywhere in the CSV, or under another digest, still fails.
check_images_by_digest() {  # <work>
  local work=$1 src img n r e cnt bad= notbuilt= missing= ext= extmiss= digest_re='@sha256:[0-9a-f]{64}$'
  {
    if [[ -f $work/bundle.json ]]; then
      jq -r --arg b "$BUNDLE_REF" '.relatedImages[]?.image | select($b == "" or . != $b) | "relatedImages " + .' "$work/bundle.json"
    fi
    jq -r '.spec.relatedImages[]?.image | "csv.relatedImages " + .' "$work/csv.json"
    jq -r '.metadata.annotations.containerImage // empty | "annotation:containerImage " + .' "$work/csv.json"
    jq -r '.spec.install.spec.deployments[]?.spec.template.spec
           | ((.containers // []) + (.initContainers // []))[]
           | ("container:" + .name + " " + .image),
             (.env[]? | select(.name | test("^RELATED_IMAGE_|_IMAGE$")) | select(.value != null)
              | "env:" + .name + " " + .value)' "$work/csv.json"
  } | LC_ALL=C sort -u >"$work/images.txt"
  while read -r src img; do
    if [[ ! $img =~ $digest_re ]]; then
      bad="${bad} ${src}=${img}"
    elif [[ -n $EXP_REGISTRY && $img == "$EXP_REGISTRY/"* ]]; then
      case " ${PUSHED_IMAGE_REFS} " in
        *" ${img} "*) ;;
        *) notbuilt="${notbuilt} ${src}=${img}" ;;
      esac
    elif [[ $img =~ $EXTERNAL_REF_RE ]]; then
      case " ${ext} " in
        *" ${img} "*) ;;
        *) ext="${ext} ${img}" ;;
      esac
    else
      bad="${bad} ${src}=${img}"
    fi
  done <"$work/images.txt"
  for r in $PUSHED_IMAGE_REFS; do
    if ! grep -qF " ${r}" "$work/images.txt"; then missing="${missing} ${r}"; fi
  done
  if [[ -z $PUSHED_IMAGE_REFS || -z $EXP_REGISTRY ]]; then missing="${missing} (no pushed refs or registry given)"; fi
  for e in $EXP_EXTERNAL; do
    cnt=0
    for r in $ext; do
      if [[ $r == "quay.io/jetstack/${e}@sha256:"* ]]; then cnt=$((cnt + 1)); fi
    done
    if [[ $cnt != 1 ]]; then extmiss="${extmiss} quay.io/jetstack/${e} (${cnt} digests)"; fi
  done
  n=$(wc -l <"$work/images.txt" | tr -d ' ')
  for r in $ext; do contract "EXTERNAL ${r}"; done
  if [[ -n $extmiss ]]; then
    check images-by-digest FAIL "external missing or ambiguous:${extmiss}; not by digest or not allowed:${bad:- none}; not pushed by this run:${notbuilt:- none}; pushed but not referenced:${missing:- none}"
  elif [[ -z $bad && -z $notbuilt && -z $missing ]]; then
    check images-by-digest PASS "${n} refs, all @sha256; ${EXP_REGISTRY}/ refs are this run's digests ($(for r in $PUSHED_IMAGE_REFS; do printf '%s ' "${r##*/}"; done | sed -e 's/@sha256:\([0-9a-f]\{12\}\)[0-9a-f]*/@\1/g' -e 's/ $//')); EXTERNAL:$(for r in $ext; do printf ' %s' "${r#quay.io/jetstack/}"; done | sed 's/@sha256:\([0-9a-f]\{12\}\)[0-9a-f]*/@\1/g')"
  else
    check images-by-digest FAIL "not by digest or not allowed:${bad:- none}; not pushed by this run:${notbuilt:- none}; pushed but not referenced:${missing:- none}"
  fi
}

check_no_redhat_registry() {  # <work> <root>: the CSV, every bundle object, the bundle files and labels
  local work=$1 root=$2 hits= n
  n=$(jq -c . "$work/csv.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
  if [[ -n $n ]]; then hits="${hits}CSV: ${n}; "; fi
  if [[ -f $work/objects.json ]]; then
    n=$(jq -c . "$work/objects.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
    if [[ -n $n ]]; then hits="${hits}bundle objects: ${n}; "; fi
  fi
  if [[ -d $root/manifests ]]; then
    n=$(grep -rliE "$REDHAT_REGISTRY_RE" "$root" | sed "s|^${root}/||" | paste -sd ' ' - || true)
    if [[ -n $n ]]; then hits="${hits}bundle files: ${n}; "; fi
  else
    hits="${hits}bundle image not extracted; "
  fi
  if [[ -f $work/config.json ]]; then
    n=$(jq -c '.config.Labels // {}' "$work/config.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
    if [[ -n $n ]]; then hits="${hits}bundle labels: ${n}; "; fi
  elif [[ $LAPTOP == 0 ]]; then
    hits="${hits}no image config read; "
  fi
  if [[ -z $hits ]]; then
    check no-redhat-registry PASS "no registry.redhat.io, registry-proxy.engineering.redhat.com or brew.registry in the CSV$([[ -f $work/objects.json ]] && echo ', the rendered bundle objects'), the bundle files$([[ -f $work/config.json ]] && echo ' or the image labels')"
  else
    check no-redhat-registry FAIL "${hits}"
  fi
}

check_install_modes() {  # <work>: AllNamespaces required (the homelab OperatorGroup is spec: {})
  local modes all
  modes=$(jq -r '[.spec.installModes[]? | "\(.type)=\(.supported)"] | join(" ")' "$1/csv.json")
  all=$(jq -r '[.spec.installModes[]? | select(.type == "AllNamespaces") | .supported] | first // false' "$1/csv.json")
  if [[ $all == true ]]; then
    check install-modes PASS "${modes}"
  else
    check install-modes FAIL "${modes}; AllNamespaces must be supported (the homelab OperatorGroup is spec: {})"
  fi
}

# machineconfig-permission (INFO, recorded): the 1.21 operator may create MachineConfigs (HTTP01Proxy,
# alpha, off by default; a MachineConfig is a node reroll). Review Focus 1 of the plan.
check_machineconfig_permission() {  # <work>
  local mc
  mc=$(jq -r '[.spec.install.spec.clusterPermissions[]? | .serviceAccountName as $sa | .rules[]?
      | select((.resources // []) | index("machineconfigs"))
      | "\($sa): \((.apiGroups // []) | join(",")) machineconfigs verbs=\((.verbs // []) | join(","))"] | join("; ")' "$1/csv.json")
  check machineconfig-permission INFO "${mc:-no clusterPermission on machineconfigs}"
}

# operator-sdk bundle validate on the bundle's files (no image builder needed); default validators.
check_operator_sdk() {  # <work> <root>
  local work=$1 root=$2 out rc=0 passed nwarn nerr first
  if ! command -v operator-sdk >/dev/null; then
    if [[ $LAPTOP == 1 ]]; then
      check operator-sdk-validate SKIP "operator-sdk not on PATH (laptop)"
    else
      check operator-sdk-validate FAIL "operator-sdk not on PATH"
    fi
    return 0
  fi
  if [[ ! -d $root/manifests ]]; then
    check operator-sdk-validate FAIL "bundle image not extracted"
    return 0
  fi
  out=$(operator-sdk bundle validate "$root" -o json-alpha1 2>"$work/operator-sdk.err") || rc=$?
  echo "$out" >"$work/operator-sdk.json"
  passed=$(jq -r 'if has("passed") then (.passed | tostring) else "unknown" end' <<<"$out" 2>/dev/null || echo unknown)
  nwarn=$(jq '[.outputs[]? | select(.type == "warning")] | length' <<<"$out" 2>/dev/null || echo "?")
  nerr=$(jq '[.outputs[]? | select(.type == "error")] | length' <<<"$out" 2>/dev/null || echo "?")
  jq -r '.outputs[]? | "INFO operator-sdk " + .type + ": " + .message' <<<"$out" 2>/dev/null | cut -c1-300 || true
  if [[ $rc == 0 && $passed == true ]]; then
    check operator-sdk-validate PASS "operator-sdk $(first_line operator-sdk version | sed -n 's/.*operator-sdk version: "\([^"]*\)".*/\1/p') bundle validate: passed, ${nwarn} warnings, ${nerr} errors"
  else
    first=$(jq -r '[.outputs[]? | select(.type == "error") | .message] | first // empty' <<<"$out" 2>/dev/null || true)
    check operator-sdk-validate FAIL "exit ${rc}, passed ${passed}, ${nerr} errors: ${first:-$(tail -n 2 "$work/operator-sdk.err" | one_line)}"
  fi
}

run_bundle_checks() {  # <work> <root>
  local work=$1 root=$2
  echo "INFO bundle checks: version ${EXP_VERSION}, registry ${EXP_REGISTRY:-none}, min-kube ${EXP_MIN_KUBE}, $(printf '%s\n' $EXP_OBJECTS | wc -l | tr -d ' ') objects besides the CSV"
  check_bundle_objects "$work"
  if [[ $(jq -r 'type' "$work/csv.json") == object ]]; then
    check_csv_name "$work" "$root"
    check_skiprange "$work"
    check_min_kube "$work"
    check_no_max_openshift "$work" "$root"
    check_version_env "$work"
    check_images_by_digest "$work"
    check_no_redhat_registry "$work" "$root"
    check_install_modes "$work"
    check_machineconfig_permission "$work"
  else
    check csv-name FAIL "no ClusterServiceVersion in the bundle"
  fi
  check_operator_sdk "$work" "$root"
}

verify() {  # verify <array name>
  local -n arr=$1
  local name ref repo digest dir
  step_start verify
  for name in "${BUNDLE_VARS[@]}"; do
    ref=${arr[$name]}
    repo=${ref%:*}
    digest=${DIGEST[$repo]}
    dir=$RUN/verify/$name
    BUNDLE_REF="${repo}@${digest}"   # what opm render lists as the olm.bundle's own image
    mkdir -p "$dir"
    opm render "${repo}@${digest}" -o json >"$dir/render.json"
    echo "INFO verify ${repo}@${digest} $(jq -rs 'map(select(.schema == "olm.bundle")) | first | .name // "no olm.bundle"' "$dir/render.json")"
    if ! bundle_extract "${repo}@${digest}" "$dir"; then
      echo "ERROR could not extract ${repo}@${digest}; the file-level parts of the checks fail"
      rm -rf "$dir/fs"
    fi
    bundle_prepare "$dir" "$dir/fs"
    run_bundle_checks "$dir" "$dir/fs"
  done
  step_end
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "verify: ${VERIFY_FAILS} checks failed"
  fi
}

# ---------------------------------------------------------------------------------------
# modes

# Start of MODE=full: always prune. The PVC still holds layers of earlier runs and nothing on it
# needs keeping. After the prune the base layers are pulled again, so
# peak = max(DISK) of the run approximates a fresh hosted runner.
# `podman system prune -af` cannot be scoped to some images, and does not need to be.
prune() {
  step_start prune
  disk
  run_bg podman system prune -af
  disk
  step_end
}

mode_full() {
  local name repo link_op link_cm
  prune

  step_start clone
  clone_pipeline
  load_vars "$BASE_REGISTRY" V
  if [[ ${V[REGISTRY]:-} != "${BASE_REGISTRY}/${OP_DIR}" ]]; then
    finish FAIL "${OP_DIR}/build.sh REGISTRY is '${V[REGISTRY]:-}', want ${BASE_REGISTRY}/${OP_DIR}"
  fi
  if [[ "${V[MAJOR]:-}.${V[MINOR]:-}" != "$EXPECT_RELEASE" || ${V[OCP_DATE]:-} != "${EXPECT_RELEASE}.0-${DATE}" ]]; then
    finish FAIL "${OP_DIR}/build.sh builds ${V[MAJOR]:-?}.${V[MINOR]:-?} (OCP_DATE ${V[OCP_DATE]:-?}), want ${EXPECT_RELEASE} (${EXPECT_RELEASE}.0-${DATE})"
  fi
  guard_images V "${V[REGISTRY]}"
  split_vars V
  if ! check_gitmodules_branch "$PIPE" "${V[OCP_SHORT]:-}"; then
    finish FAIL "gitmodules-branch: ${PIPELINE_BRANCH} does not declare the ${V[OCP_SHORT]:-?} branches"
  fi
  # The pins before anything is built; operator-commit and cert-manager-commit prove the tree after init.
  link_op=$(gitlink "$OPERATOR_SUB")
  link_cm=$(gitlink "$CERT_MANAGER_SUB")
  if [[ $link_op != "$OPERATOR_COMMIT" || $link_cm != "$CERT_MANAGER_COMMIT" ]]; then
    finish FAIL "pins: ${PIPELINE_BRANCH} records ${OPERATOR_SUB}=${link_op:-none} ${CERT_MANAGER_SUB}=${link_cm:-none}, want ${OPERATOR_COMMIT} ${CERT_MANAGER_COMMIT}"
  fi
  EXP_VERSION=${V[OCP_DATE]}
  EXP_REGISTRY=${V[REGISTRY]}
  step_end

  # A run never re-pushes a tag: every image and the bundle.
  step_start tag-check
  for name in "${IMAGE_VARS[@]}" "${BUNDLE_VARS[@]}"; do
    tag_check "${V[$name]}"
  done
  step_end

  pipeline_step "$BASE_REGISTRY" init
  # The tree init checked out and patched, before the build reads it and before build_bundle edits it.
  step_start source-checks
  operator_commit
  cert_manager_commit
  patch_applied
  feature_defaults
  step_end
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "source checks: ${VERIFY_FAILS} failed"
  fi
  pipeline_step "$BASE_REGISTRY" build_containers
  pipeline_step "$BASE_REGISTRY" push_containers
  report_pushed V "${IMAGE_VARS[@]}"
  for name in "${IMAGE_VARS[@]}"; do
    repo=$(ref_repo "${V[$name]}")
    PUSHED_IMAGE_REFS="${PUSHED_IMAGE_REFS:+${PUSHED_IMAGE_REFS} }${repo}@${DIGEST[$repo]}"
  done
  pipeline_step "$BASE_REGISTRY" build_bundle
  report_pushed V "${BUNDLE_VARS[@]}"
  pipeline_step "$BASE_REGISTRY" deinit
  verify V
}

ref_repo() {  # repository of a ref with a digest and/or a tag
  local r=${1%@*}
  if [[ ${r##*/} == *:* ]]; then r=${r%:*}; fi
  echo "$r"
}

mode_catalog() {
  local n rc=0
  local -A C=([IMG_CATALOG]="${BASE_REGISTRY}/cert-manager-catalog:${DATE}")
  guard_registry "${C[IMG_CATALOG]%:*}"
  rm -rf "$RUN"
  mkdir -p "$RUN"

  step_start tag-check
  tag_check "${C[IMG_CATALOG]}"
  step_end

  export RUN_DIR=$RUN CATALOG_IMAGE=${C[IMG_CATALOG]}
  step_start catalog-edit
  # run_bg without its errexit: the CHECK lines are copied whatever the script's exit status.
  env -C "$RUN" bash -c 'set -o pipefail; bash /scripts/catalog-edit.sh 2>&1 | tee "$RUN_DIR/catalog-edit.log"' &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=
  step_end
  # catalog-edit.sh prints its CHECK lines to stdout; copy them into the contract file too
  grep '^CHECK ' "$RUN/catalog-edit.log" >>"$CONTRACT" || true
  # A pushed catalog image is reported even if a later check failed, so it can be deleted.
  if [[ -f $RUN/catalog-image.pushed ]]; then
    report_pushed C IMG_CATALOG
  fi
  n=$(grep -c '^CHECK [^ ]* FAIL' "$RUN/catalog-edit.log" || true)
  if [[ $n != 0 ]]; then
    finish FAIL "catalog: ${n} checks failed"
  fi
  if [[ $rc != 0 ]]; then
    finish FAIL "catalog-edit.sh exit ${rc}"
  fi
  if [[ ! -f $RUN/catalog-image.pushed ]]; then
    finish FAIL "catalog: no catalog image pushed"
  fi
}

main() {
  declare -gA V=()       # variables sourced from cert-manager/build.sh
  declare -gA DIGEST=()  # repository -> digest this run pushed
  trap on_exit EXIT
  trap on_term TERM INT
  validate        # fails to the pod log only: the log files are named after MODE and DATE
  setup_env
  open_logs
  take_lock       # before anything touches /work/run, the caches or the podman graph root
  make_dirs
  print_inputs

  step_start tools
  install_tools
  step_end

  step_start podman-setup
  configure_podman
  step_end

  case $MODE in
    full) mode_full ;;
    catalog) mode_catalog ;;
  esac
  finish PASS "${MODE} ${DATE}"
}

# ---------------------------------------------------------------------------------------
# laptop commands (README "Bundle checks on the laptop"); bash 3.2, jq, yq v4, skopeo

laptop_extract_bundle() {  # extract-bundle <ref> <dir>
  if [[ $# != 2 ]]; then echo "usage: build.sh extract-bundle <bundle ref> <dir>" >&2; exit 2; fi
  mkdir -p "$2"
  bundle_extract "$1" "$2"
}

# Expectations: CHECK_MAJOR (1), CHECK_MINOR (21), CHECK_DATE (required) -> EXP_VERSION;
# CHECK_OBJECTS (Kind/name list besides the CSV, default the 1.21 list); CHECK_REGISTRY and
# CHECK_PUSHED (space-separated repo@digest) for images-by-digest; CHECK_MIN_KUBE (1.31.0);
# CHECK_EXTERNAL (required quay.io/jetstack repos, default 'trust-manager cert-manager-approver-policy';
# 1.20 has trust-manager only); CHECK_BUNDLE_REF (the bundle's repo@digest, dropped from opm's relatedImages).
# <work> defaults to a new temporary directory; a render.json from `opm render` placed there is used.
laptop_check_bundle() {  # check-bundle <bundle root> [<work dir>]
  local root=${1:-} work=${2:-}
  if [[ -z $root || ! -d $root/manifests || -z ${CHECK_DATE:-} ]]; then
    echo "usage: CHECK_DATE=<YYYY-MM-DD-HHMMSS> [CHECK_MINOR=21 CHECK_OBJECTS=... CHECK_REGISTRY=... CHECK_PUSHED=...] build.sh check-bundle <dir with manifests/> [<work dir>]" >&2
    exit 2
  fi
  LAPTOP=1
  EXP_VERSION="${CHECK_MAJOR:-1}.${CHECK_MINOR:-21}.0-${CHECK_DATE}"
  EXP_OBJECTS=${CHECK_OBJECTS:-$BUNDLE_OBJECTS_121}
  EXP_REGISTRY=${CHECK_REGISTRY:-}
  EXP_MIN_KUBE=${CHECK_MIN_KUBE:-$MIN_KUBE}
  PUSHED_IMAGE_REFS=${CHECK_PUSHED:-}
  BUNDLE_REF=${CHECK_BUNDLE_REF:-}
  EXP_EXTERNAL=${CHECK_EXTERNAL-$EXP_EXTERNAL}
  if [[ -z $work ]]; then work=$(mktemp -d "${TMPDIR:-/tmp}/cm-bundle-check.XXXXXX"); fi
  mkdir -p "$work"
  echo "INFO bundle root ${root}, work ${work}"
  bundle_prepare "$work" "$root"
  run_bundle_checks "$work" "$root"
  if [[ $VERIFY_FAILS == 0 ]]; then
    echo "RESULT PASS check-bundle ${EXP_VERSION}"
  else
    echo "RESULT FAIL check-bundle: ${VERIFY_FAILS} checks failed"
    exit 1
  fi
}

case ${1:-} in
  extract-bundle) shift; laptop_extract_bundle "$@" ;;
  check-bundle) shift; laptop_check_bundle "$@" ;;
  *) main "$@" ;;
esac
