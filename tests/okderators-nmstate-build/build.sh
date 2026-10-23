#!/bin/bash
# Entry point of the okderators-nmstate-build Job (see README.md in this directory). Adapted from
# tests/okderators-gitops-build/build.sh: same contract lines, tool pins, log persistence, lock,
# prune and push guards; it runs the pipeline's nmstate/build.sh and checks the NMState bundle.
#
# Runs as root in a privileged quay.io/podman/stable pod in namespace okd-build, with the
# PVC build-storage mounted at /var/lib/containers (subPath containers) and /work (subPath work).
#
# Inputs (env, set by job-template.yaml):
#   MODE              full | catalog
#   PIPELINE_REPO     okd-operator-pipeline clone URL
#   PIPELINE_BRANCH   MODE=full: the branch to build
#   DATE              YYYY-MM-DD-HHMMSS, new per run; in MODE=full the image tags' suffix
#   BASE_REGISTRY     must be zot.apps.okd.sudops.pl/okd-test or a path under it
#   CATALOG_BRANCHES  MODE=catalog only, passed through to catalog-edit.sh
#   BUNDLES           MODE=catalog only, passed through to catalog-edit.sh
#                     (<catalog-branch>=<bundle ref@digest>, space-separated)
#   OKD_VERSION       optional; the OKD release whose payload supplies kube-rbac-proxy and whose
#                     MAJOR.MINOR names the CSV, the image tags and the scos base image. Empty = the
#                     branch's own common.sh default. Inherited by nmstate/build.sh. An override must
#                     keep the branch's release: gitmodules-branch stops the run before any build
#                     when release-<MAJOR>.<MINOR> is not what .gitmodules declares.
# MODE=catalog pushes one image, ${BASE_REGISTRY}/nmstate-catalog:${DATE}, chosen and guarded here.
#
# Machine-greppable output (everything else is free-form):
#   STEP <name> START|END <epoch seconds>
#   DISK <bytes>                     du of /var/lib/containers + /work, after every step (and twice
#                                    around the prune that starts MODE=full)
#   PUSHED <ref>@<digest> <bytes>    bytes = config + layer sizes in the registry manifest
#   CHECK <name> PASS|FAIL <detail>
#   RESULT PASS|FAIL <reason>
# The contract lines are also appended to /work/logs/nmstate-build-<MODE>-<DATE>.contract, and the
# whole output is copied to /work/logs/nmstate-build-<MODE>-<DATE>.log, so both survive a deleted pod
# or a rotated container log. A lock on /work/.lock keeps a second run off the same PVC.
set -euo pipefail
shopt -s inherit_errexit

MODE=${MODE:-}
PIPELINE_REPO=${PIPELINE_REPO:-https://github.com/sudoom/okd-operator-pipeline.git}
PIPELINE_BRANCH=${PIPELINE_BRANCH:-}
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

# The one IMG_* variable of nmstate/build.sh that is not built here: the OKD release payload's
# kube-rbac-proxy, by digest. It is never pushed. Anything else outside ${REGISTRY}/ is a failure.
EXTERNAL_VAR_RE='^IMG_KUBE_RBAC_PROXY$'
EXTERNAL_REF_RE='^quay\.io/okd/scos-content@sha256:[0-9a-f]{64}$'

# What the bundle must be (README.md, "Verify").
OP_DIR=nmstate                       # the operator's directory in okd-operator-pipeline
PKG=kubernetes-nmstate-operator
CRD_NAME=nmstates.nmstate.io
OPERATOR_SUB=nmstate/operator        # submodule paths in the pipeline repository
PLUGIN_SUB=nmstate/console-plugin
# The release whose code may lack AllNamespaces (the install-modes check only records it there).
NO_ALLNS_RELEASE=4.20
REDHAT_REGISTRY_RE='registry\.redhat\.io|registry-proxy\.engineering\.redhat\.com|brew\.registry'
IMAGESTREAM_RE="kind\"?[[:space:]]*:[[:space:]]*['\"]?ImageStream(['\"]|[[:space:]]|,|$)"
# A label key in the operator Containerfile that would carry the build commit (none today), e.g.
# vcs-ref=, io.openshift.build.commit.id=, org.opencontainers.image.revision=.
COMMIT_LABEL_RE='(vcs-ref|commit|revision)[A-Za-z0-9._-]*='

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
declare -A V=()            # variables sourced from nmstate/build.sh
declare -A DIGEST=()       # repository -> digest this run pushed
IMAGE_VARS=()
BUNDLE_VARS=()

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
  local base="$LOGS/nmstate-build-${MODE}-${DATE}"
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

trap on_exit EXIT
trap on_term TERM INT

# One run at a time on the PVC: both would wipe /work/run and share one podman graph root.
# RWO only keeps pods on other nodes away. flock is released when this process dies. The lock
# file is the one the logging and GitOps Jobs take, so none of the three overlaps another.
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
  if [[ $MODE == catalog && (! -f /scripts/catalog-edit.sh || ! -f /scripts/catalog-branches.tsv) ]]; then
    finish FAIL "catalog-edit.sh or catalog-branches.tsv not present"
  fi
}

print_inputs() {
  echo "INFO MODE=${MODE} DATE=${DATE} BASE_REGISTRY=${BASE_REGISTRY}"
  echo "INFO PIPELINE_REPO=${PIPELINE_REPO} PIPELINE_BRANCH=${PIPELINE_BRANCH}"
  echo "INFO CATALOG_BRANCHES=${CATALOG_BRANCHES} BUNDLES=${BUNDLES}"
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
  # git am (patches/*.patch in init) needs a committer identity and the pod has none. git am
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

# Source nmstate/build.sh (main() does not run when sourced) and read back its variables, so
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

guard_images() {  # every IMG_* in array $1 must be under registry $2, except the EXTERNAL one
  local -n arr=$1
  local k
  for k in "${!arr[@]}"; do
    if [[ $k == IMG_* ]]; then
      if [[ $k =~ $EXTERNAL_VAR_RE ]]; then
        if [[ ! ${arr[$k]} =~ $EXTERNAL_REF_RE ]]; then
          finish FAIL "${k}=${arr[$k]} is not a known external image"
        fi
      elif [[ ${arr[$k]} != "$2/"* ]]; then
        finish FAIL "${k}=${arr[$k]} is outside $2"
      fi
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
    elif [[ $k == IMG_* && ! $k =~ $EXTERNAL_VAR_RE ]]; then
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
# checks

check() {  # check <name> PASS|FAIL <detail...>
  contract "CHECK $1 $2 ${*:3}"
  if [[ $2 == FAIL ]]; then VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

ref_repo() {  # repository of a ref with a digest and/or a tag
  local r=${1%@*}
  if [[ ${r##*/} == *:* ]]; then r=${r%:*}; fi
  echo "$r"
}

# operator-commit (Ruling N5). nmstate/images/operator.Containerfile sets no commit label, and the
# operator repository's .dockerignore drops .git (release-4.21 and release-4.22 sources, read
# 2026-10-23), so the binary has no VCS stamp either: the image itself cannot say which commit it
# was built from. What can be checked is the tree it was built from: right after
# build_containers, the operator submodule's HEAD (checked out by the pipeline's
# own init: submodule_reset, then `git submodule update --init` to the recorded hash) must be the
# gitlink the branch records, with no local change and no patch applied. If the Containerfile ever
# gains a commit label, the check fails until it is taught to compare that label instead.
operator_commit() {
  local gitlink head dirty branch label patch=none
  step_start operator-commit
  gitlink=$(git -C "$PIPE" ls-tree HEAD "$OPERATOR_SUB" | awk '$2 == "commit" {print $3}')
  head=$(git -C "$PIPE/$OPERATOR_SUB" rev-parse HEAD 2>/dev/null) || head=none
  dirty=$(git -C "$PIPE/$OPERATOR_SUB" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty=unknown
  branch=$(git -C "$PIPE" config -f .gitmodules "submodule.${OPERATOR_SUB}.branch" 2>/dev/null) || branch=none
  if [[ -f $PIPE/$OP_DIR/patches/operator.patch ]]; then patch=patches/operator.patch; fi
  local cf=$PIPE/$OP_DIR/images/operator.Containerfile
  if [[ -f $cf ]]; then
    label=$(grep -cE "$COMMIT_LABEL_RE" "$cf" || true)
  else
    label=missing
  fi
  echo "INFO ${PLUGIN_SUB} HEAD $(git -C "$PIPE/$PLUGIN_SUB" rev-parse HEAD 2>/dev/null || echo none)" \
    "gitlink $(git -C "$PIPE" ls-tree HEAD "$PLUGIN_SUB" | awk '$2 == "commit" {print $3}')" \
    ".gitmodules branch $(git -C "$PIPE" config -f .gitmodules "submodule.${PLUGIN_SUB}.branch" 2>/dev/null || echo none)"
  if [[ $label == missing ]]; then
    check operator-commit FAIL "${OP_DIR}/images/operator.Containerfile is missing"
  elif [[ $label != 0 ]]; then
    check operator-commit FAIL "${OP_DIR}/images/operator.Containerfile now has ${label} commit-like label line(s): compare that label instead of the gitlink"
  elif [[ $gitlink =~ ^[0-9a-f]{40}$ && $head == "$gitlink" && $dirty == 0 && $patch == none ]]; then
    check operator-commit PASS "${OPERATOR_SUB} built from ${head} = the recorded gitlink (.gitmodules branch ${branch}), clean tree, no patch; the Containerfile sets no commit label"
  else
    check operator-commit FAIL "${OPERATOR_SUB} HEAD ${head}, recorded gitlink ${gitlink:-none} (.gitmodules branch ${branch}), ${dirty} changed paths, patch ${patch}"
  fi
  step_end
}

# gitmodules-branch: the release the build targets (OCP_SHORT, from the OKD_VERSION in effect) must be
# the release both nmstate submodules declare in .gitmodules (main: OCP_SHORT 5.0, release-5.0).
# .gitmodules is not what gets built, the gitlink is (operator-commit, csv-code-release); a mismatch
# means the OKD_VERSION in effect and the branch disagree, so mode_full stops before building.
check_gitmodules_branch() {  # <pipeline dir> <OCP_SHORT>; returns 1 on FAIL
  local pipe=$1 want="release-$2" sub got
  local -a seen=() bad=()
  for sub in "$OPERATOR_SUB" "$PLUGIN_SUB"; do
    got=$(git config -f "${pipe}/.gitmodules" "submodule.${sub}.branch" 2>/dev/null || echo none)
    seen+=("${sub}=${got}")
    if [[ $got != "$want" ]]; then bad+=("${sub}=${got}"); fi
  done
  if [[ ${#bad[@]} == 0 ]]; then
    check gitmodules-branch PASS "${seen[*]}, the release of OCP_SHORT $2"
  else
    check gitmodules-branch FAIL "${bad[*]} in .gitmodules, want ${want} (OCP_SHORT $2 from the OKD_VERSION in effect)"
    return 1
  fi
}

# nmstate-rpm: the nmstate package the handler image installed (dnf in its Containerfile), recorded.
nmstate_rpm() {  # nmstate_rpm <array name>
  local -n arr=$1
  local img=${arr[IMG_HANDLER]:-} out ver rc=0
  step_start nmstate-rpm
  if [[ -z $img ]]; then
    check nmstate-rpm FAIL "IMG_HANDLER is not defined by ${OP_DIR}/build.sh"
  else
    out=$(podman run --rm --entrypoint rpm "$img" -q nmstate 2>&1) || rc=$?
    ver=$(grep -m 1 -E '^nmstate-[0-9]' <<<"$out" || true)
    if [[ $rc == 0 && -n $ver ]]; then
      check nmstate-rpm PASS "${ver} in ${img}"
    else
      check nmstate-rpm FAIL "rpm -q nmstate in ${img} (exit ${rc}): $(echo "$out" | head -n 2 | one_line)"
    fi
  fi
  step_end
}

# The bundle image's files as zot serves them: skopeo copies the manifest and layers to a dir:
# layout (blobs named by their hex digest), and each layer is unpacked into <dir>/fs in order.
bundle_extract() {  # bundle_extract <repo@digest> <dir>
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
  echo "INFO bundle files: $(cd "$dir/fs" && find . -type f | sed 's|^\./||' | sort | paste -sd ' ' -)"
}

check_bundle_objects() {  # <dir>: exactly the CRD nmstates.nmstate.io and one CSV, in objects and files
  local dir=$1 kinds crd objs files nfiles=unknown
  kinds=$(jq -r '[.[].kind] | sort | join(" ")' "$dir/objects.json")
  crd=$(jq -r '[.[] | select(.kind == "CustomResourceDefinition") | .metadata.name] | join(" ")' "$dir/objects.json")
  objs=$(jq -r '[.[] | "\(.kind)/\(.metadata.name // "-")"] | join(" ")' "$dir/objects.json")
  if [[ -d $dir/fs/manifests ]]; then
    files=$(cd "$dir/fs/manifests" && find . -type f | sed 's|^\./||' | sort | paste -sd ' ' -)
    nfiles=$(echo "$files" | wc -w | tr -d ' ')
  fi
  if [[ $kinds == "ClusterServiceVersion CustomResourceDefinition" && $crd == "$CRD_NAME" && $nfiles == 2 ]]; then
    check bundle-objects PASS "objects ${objs}; manifests/ ${files}"
  else
    check bundle-objects FAIL "objects ${objs:-none}; manifests/ ${files:-not extracted} (want CustomResourceDefinition/${CRD_NAME} and one ClusterServiceVersion, two files)"
  fi
}

check_no_imagestream() {  # <dir>: no ImageStream object (opm render) and no ImageStream file
  local dir=$1 nobj files=not-extracted refs=
  nobj=$(jq '[.[] | select(.kind == "ImageStream")] | length' "$dir/objects.json")
  if [[ -d $dir/fs ]]; then
    files=$(grep -rlE "$IMAGESTREAM_RE" "$dir/fs" | sed "s|^${dir}/fs/||" | paste -sd ' ' - || true)
    refs=$(cd "$dir/fs" && find . -name image-references | sed 's|^\./||' | paste -sd ' ' -)
  fi
  if [[ $nobj == 0 && -z $files && -z $refs ]]; then
    check no-imagestream PASS "no ImageStream object in opm render, no ImageStream in the bundle image's files, no image-references file"
  else
    check no-imagestream FAIL "${nobj} ImageStream object(s); files with kind ImageStream: ${files:-none}; image-references: ${refs:-none}"
  fi
}

check_no_redhat_registry() {  # <dir>: the CSV, every bundle object, the bundle files and labels
  local dir=$1 hits=() n
  n=$(jq -c . "$dir/csv.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
  if [[ -n $n ]]; then hits+=("CSV: ${n}"); fi
  n=$(jq -c . "$dir/objects.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
  if [[ -n $n ]]; then hits+=("bundle objects: ${n}"); fi
  if [[ -d $dir/fs ]]; then
    n=$(grep -rliE "$REDHAT_REGISTRY_RE" "$dir/fs" | sed "s|^${dir}/fs/||" | paste -sd ' ' - || true)
    if [[ -n $n ]]; then hits+=("bundle files: ${n}"); fi
    n=$(jq -c '.config.Labels // {}' "$dir/config.json" | grep -oiE "$REDHAT_REGISTRY_RE" | sort -u | paste -sd ' ' - || true)
    if [[ -n $n ]]; then hits+=("bundle labels: ${n}"); fi
  else
    hits+=("bundle image not extracted")
  fi
  if [[ ${#hits[@]} == 0 ]]; then
    check no-redhat-registry PASS "no registry.redhat.io, registry-proxy.engineering.redhat.com or brew.registry in the CSV, the bundle objects, the bundle files or labels"
  else
    check no-redhat-registry FAIL "$(printf '%s; ' "${hits[@]}")"
  fi
}

check_csv_name() {  # <dir> <array name>: kubernetes-nmstate-operator.v<MAJOR>.<MINOR>.0-<DATE>
  local dir=$1
  local -n arr=$2
  local want_version="${arr[MAJOR]:-}.${arr[MINOR]:-}.0-${DATE}" pkg pv n
  local want_name="${PKG}.v${want_version}"
  pkg=$(jq -r '.package // "none"' "$dir/bundle.json")
  pv=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "$dir/bundle.json")
  n=$(jq -r '[.metadata.name, .spec.version] | join(" ")' "$dir/csv.json")
  if [[ $pkg == "$PKG" && $n == "${want_name} ${want_version}" && $pv == "$want_version" \
    && ${arr[OCP_DATE]:-} == "$want_version" ]]; then
    check csv-name PASS "${n} (OKD_VERSION ${arr[OKD_VERSION]:-?})"
  else
    check csv-name FAIL "package ${pkg}, CSV '${n}', olm.package version ${pv}, OCP_DATE ${arr[OCP_DATE]:-?}; want ${PKG} '${want_name} ${want_version}' from OKD_VERSION ${arr[OKD_VERSION]:-?}"
  fi
  # What the CSV says about its own edges: catalog-edit.sh sets the real ones in the channel entry.
  echo "INFO csv replaces=$(jq -r '.spec.replaces // "none"' "$dir/csv.json") skips=$(jq -c '.spec.skips // "none"' "$dir/csv.json") olm.skipRange=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json") minKubeVersion=$(jq -r '.spec.minKubeVersion // "none"' "$dir/csv.json")"
}

# csv-code-release: which release the operator code itself is. kubernetes-nmstate's CSV base carries
# spec.labels.olm-status-descriptors kubernetes-nmstate-operator.v<X.Y>.0 and olm.skipRange
# '>=4.3.0 <X.Y.0' for its own release; the pipeline renames the CSV from OKD_VERSION but leaves both.
# So csv-name (name from OKD_VERSION) and this check (release from the code) together catch code of
# one release built under another's name: the 2026-05-05 4.21 catalog bundle is 4.20 code named
# v4.21.0 and carries v4.20.0 and '<4.20.0'.
check_csv_code_release() {  # <dir> <MAJOR> <MINOR>
  local dir=$1 rel="$2.$3.0" sd sr upper
  sd=$(jq -r '.spec.labels["olm-status-descriptors"] // "none"' "$dir/csv.json")
  sr=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json")
  upper=$(grep -oE '<[0-9][^[:space:]]*' <<<"$sr" | tail -n 1 || true)
  if [[ $sd == "${PKG}.v${rel}" && $upper == "<${rel}" ]]; then
    check csv-code-release PASS "release $2.$3 code: olm-status-descriptors ${sd}, olm.skipRange '${sr}'"
  else
    check csv-code-release FAIL "olm-status-descriptors ${sd} (want ${PKG}.v${rel}), olm.skipRange '${sr}' upper bound '${upper:-none}' (want <${rel})"
  fi
}

# images-by-digest: relatedImages (bundle and CSV), every deployment container and init container
# image, every RELATED_IMAGE_* / *_IMAGE env value and the containerImage annotation is @sha256:.
# Refs under <BASE_REGISTRY>/nmstate/ must be digests this run pushed, and every built image must be
# referenced; the only other ref allowed is IMG_KUBE_RBAC_PROXY, exactly.
check_images_by_digest() {  # <dir> <array name>
  local dir=$1
  local -n arr=$2
  local reg=${arr[REGISTRY]} ext=${arr[IMG_KUBE_RBAC_PROXY]:-} src img name repo n
  local -a bad=() notbuilt=() missing=()
  {
    jq -r '.relatedImages[]?.image | "relatedImages " + .' "$dir/bundle.json"
    jq -r '.spec.relatedImages[]?.image | "csv.relatedImages " + .' "$dir/csv.json"
    jq -r '.metadata.annotations.containerImage // empty | "annotation:containerImage " + .' "$dir/csv.json"
    jq -r '.spec.install.spec.deployments[]?.spec.template.spec
           | ((.containers // []) + (.initContainers // []))[]
           | ("container:" + .name + " " + .image),
             (.env[]? | select(.name | test("^RELATED_IMAGE_|_IMAGE$")) | select(.value != null)
              | "env:" + .name + " " + .value)' "$dir/csv.json"
  } | sort -u >"$dir/images.txt"
  while read -r src img; do
    if [[ ! $img =~ @sha256:[0-9a-f]{64}$ ]]; then
      bad+=("${src}=${img}")
    elif [[ $img == "$reg/"* ]]; then
      if [[ ${DIGEST[${img%@*}]:-} != "${img#*@}" ]]; then notbuilt+=("${src}=${img}"); fi
    elif [[ $img != "$ext" ]]; then
      bad+=("${src}=${img}")
    fi
  done <"$dir/images.txt"
  for name in "${IMAGE_VARS[@]}"; do
    repo=$(ref_repo "${arr[$name]}")
    if ! grep -qF " ${repo}@${DIGEST[$repo]:-none}" "$dir/images.txt"; then missing+=("${name}=${repo}"); fi
  done
  n=$(wc -l <"$dir/images.txt" | tr -d ' ')
  if [[ ${#bad[@]} == 0 && ${#notbuilt[@]} == 0 && ${#missing[@]} == 0 ]]; then
    check images-by-digest PASS "${n} refs, all @sha256; ${reg}/ refs are this run's digests ($(for name in "${IMAGE_VARS[@]}"; do printf '%s ' "${arr[$name]##*/}"; done | sed 's/ $//')); external ${ext}"
  else
    check images-by-digest FAIL "not by digest or not allowed: ${bad[*]:-none}; not pushed by this run: ${notbuilt[*]:-none}; built but not referenced: ${missing[*]:-none}"
  fi
}

check_install_modes() {  # <dir> <array name>: recorded; AllNamespaces required except on 4.20
  local dir=$1
  local -n arr=$2
  local modes all release="${arr[MAJOR]:-}.${arr[MINOR]:-}"
  modes=$(jq -r '[.spec.installModes[]? | "\(.type)=\(.supported)"] | join(" ")' "$dir/csv.json")
  all=$(jq -r '[.spec.installModes[]? | select(.type == "AllNamespaces") | .supported] | first // false' "$dir/csv.json")
  if [[ $all == true ]]; then
    check install-modes PASS "${modes}"
  elif [[ $release == "$NO_ALLNS_RELEASE" ]]; then
    check install-modes PASS "${modes} (release ${release}: recorded, AllNamespaces not required)"
  else
    check install-modes FAIL "${modes}; release ${release} must support AllNamespaces (the homelab OperatorGroup is spec: {})"
  fi
}

# operator-sdk bundle validate on the extracted bundle directory (no image builder needed); the
# default validators. A bundle with the ImageStream fails here too ("unsupported media type
# registry+v1 for bundle object", checked on the 4.21 catalog bundle 2026-10-23).
check_operator_sdk() {  # <dir>
  local dir=$1 out rc=0 passed nwarn nerr first
  if [[ ! -d $dir/fs/manifests ]]; then
    check operator-sdk-validate FAIL "bundle image not extracted"
    return 0
  fi
  out=$(operator-sdk bundle validate "$dir/fs" -o json-alpha1 2>"$dir/operator-sdk.err") || rc=$?
  echo "$out" >"$dir/operator-sdk.json"
  passed=$(jq -r 'if has("passed") then (.passed | tostring) else "unknown" end' <<<"$out" 2>/dev/null || echo unknown)
  nwarn=$(jq '[.outputs[]? | select(.type == "warning")] | length' <<<"$out" 2>/dev/null || echo "?")
  nerr=$(jq '[.outputs[]? | select(.type == "error")] | length' <<<"$out" 2>/dev/null || echo "?")
  jq -r '.outputs[]? | "INFO operator-sdk " + .type + ": " + .message' <<<"$out" 2>/dev/null | cut -c1-300 || true
  if [[ $rc == 0 && $passed == true ]]; then
    check operator-sdk-validate PASS "operator-sdk ${OPERATOR_SDK_VERSION} bundle validate: passed, ${nwarn} warnings, ${nerr} errors"
  else
    first=$(jq -r '[.outputs[]? | select(.type == "error") | .message] | first // empty' <<<"$out" 2>/dev/null || true)
    check operator-sdk-validate FAIL "exit ${rc}, passed ${passed}, ${nerr} errors: ${first:-$(tail -n 2 "$dir/operator-sdk.err" | one_line)}"
  fi
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
    mkdir -p "$dir"
    opm render "${repo}@${digest}" -o json >"$dir/render.json"
    jq -s 'map(select(.schema == "olm.bundle")) | first' "$dir/render.json" >"$dir/bundle.json"
    jq '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson]' \
      "$dir/bundle.json" >"$dir/objects.json"
    jq '[.[] | select(.kind == "ClusterServiceVersion")] | first' "$dir/objects.json" >"$dir/csv.json"
    echo "INFO verify ${repo}@${digest} $(jq -r '.name // "no olm.bundle"' "$dir/bundle.json")"
    if ! bundle_extract "${repo}@${digest}" "$dir"; then
      echo "ERROR could not extract ${repo}@${digest}; the file-level parts of the checks fail"
      rm -rf "$dir/fs"
    fi

    check_bundle_objects "$dir"
    check_no_imagestream "$dir"
    check_no_redhat_registry "$dir"
    if [[ $(jq -r 'type' "$dir/csv.json") == object ]]; then
      check_csv_name "$dir" "$1"
      check_csv_code_release "$dir" "${arr[MAJOR]:-}" "${arr[MINOR]:-}"
      check_images_by_digest "$dir" "$1"
      check_install_modes "$dir" "$1"
    else
      check csv-name FAIL "no ClusterServiceVersion in opm render ${repo}@${digest}"
    fi
    check_operator_sdk "$dir"
  done
  step_end
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "verify: ${VERIFY_FAILS} checks failed"
  fi
}

# ---------------------------------------------------------------------------------------
# modes

# Start of MODE=full: always prune (Ruling P2, amended). The PVC still holds layers of earlier runs
# and nothing on it needs keeping. After the prune the base layers are pulled again, so
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
  local name
  prune

  step_start clone
  clone_pipeline
  load_vars "$BASE_REGISTRY" V
  if [[ ${V[REGISTRY]:-} != "${BASE_REGISTRY}/${OP_DIR}" ]]; then
    finish FAIL "${OP_DIR}/build.sh REGISTRY is '${V[REGISTRY]:-}', want ${BASE_REGISTRY}/${OP_DIR}"
  fi
  guard_images V "${V[REGISTRY]}"
  split_vars V
  if ! check_gitmodules_branch "$PIPE" "${V[OCP_SHORT]:-}"; then
    finish FAIL "gitmodules-branch: OKD_VERSION ${V[OKD_VERSION]:-?} is not the release ${PIPELINE_BRANCH} pins"
  fi
  step_end

  # A run never re-pushes a tag: every image and the bundle.
  step_start tag-check
  for name in "${IMAGE_VARS[@]}" "${BUNDLE_VARS[@]}"; do
    tag_check "${V[$name]}"
  done
  step_end

  pipeline_step "$BASE_REGISTRY" init
  pipeline_step "$BASE_REGISTRY" build_containers
  operator_commit
  pipeline_step "$BASE_REGISTRY" push_containers
  report_pushed V "${IMAGE_VARS[@]}"
  nmstate_rpm V
  pipeline_step "$BASE_REGISTRY" build_bundle
  report_pushed V "${BUNDLE_VARS[@]}"
  pipeline_step "$BASE_REGISTRY" deinit
  verify V
}

mode_catalog() {
  local n rc=0
  local -A C=([IMG_CATALOG]="${BASE_REGISTRY}/nmstate-catalog:${DATE}")
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

main "$@"
