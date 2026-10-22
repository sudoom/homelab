#!/bin/bash
# Entry point of the okderators-gitops-build Job (see README.md in this directory). Adapted from
# tests/okderators-logging-build/build.sh: same contract lines, tool pins, log persistence and
# push guards; it runs the pipeline's gitops/build.sh instead of cluster-logging/build.sh.
#
# Runs as root in a privileged quay.io/podman/stable pod in namespace okd-build, with the
# PVC build-storage mounted at /var/lib/containers (subPath containers) and /work (subPath work).
#
# Inputs (env, set by job-template.yaml):
#   MODE              full | check | catalog
#   PIPELINE_REPO     okd-operator-pipeline clone URL
#   PIPELINE_BRANCH   branch to build
#   DATE              YYYY-MM-DD-HHMMSS, new per full run; becomes the image tags' suffix
#   BASE_REGISTRY     must be zot.apps.okd.sudops.pl/okd-test or a path under it
#   CATALOG_BRANCHES  MODE=catalog only, passed through to catalog-edit.sh
#   BUNDLES           MODE=catalog only, passed through to catalog-edit.sh (one bundle ref)
#   OKD_VERSION       optional; OKD release whose payload supplies the haproxy-router and must-gather
#                     images. Empty = the pipeline's own default. Inherited by gitops/build.sh.
# MODE=catalog pushes one image, ${BASE_REGISTRY}/gitops-catalog:${DATE}, chosen and guarded here.
#
# Machine-greppable output (everything else is free-form):
#   STEP <name> START|END <epoch seconds>
#   DISK <bytes>                     du of /var/lib/containers + /work, after every step (and twice
#                                    around the prune that starts MODE=full)
#   ARGOCD_VERSION <version>         MODE=full: read from the built argocd image
#   PUSHED <ref>@<digest> <bytes>    bytes = config + layer sizes in the registry manifest
#   CHECK <name> PASS|FAIL <detail>
#   RESULT PASS|FAIL <reason>
# The contract lines are also appended to /work/logs/gitops-build-<MODE>-<DATE>.contract, and the
# whole output is copied to /work/logs/gitops-build-<MODE>-<DATE>.log, so both survive a deleted pod
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

# IMG_* variables of gitops/build.sh that are not built here: the OKD release payload's
# kube-rbac-proxy and haproxy-router (by digest) and the redis image. They are never pushed.
# Anything else outside ${REGISTRY}/ is a failure. Both forms are accepted, digest or tag.
EXTERNAL_VAR_RE='^IMG_(KUBE_RBAC_PROXY|HAPROXY_ROUTER|REDIS)$'
EXTERNAL_REF_RE='^quay\.io/(okd/scos-content|sclorg/redis-[0-9a-z-]+)(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$'

# The Argo CD image, whose client version MODE=full reports (ARGOCD_VERSION line) and must equal
# EXPECTED_ARGOCD_VERSION, the version the pins file (Task 1) fixes for this build.
ARGOCD_VAR=IMG_ARGOCD
EXPECTED_ARGOCD_VERSION=v3.5.5

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
declare -A V=()            # variables sourced from gitops/build.sh (target registry)
declare -A SRC=()          # MODE=check: the same, for the registry the full run pushed to
declare -A DIGEST=()       # repository -> digest this run pushed or copied
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
  local base="$LOGS/gitops-build-${MODE}-${DATE}"
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

# ---------------------------------------------------------------------------------------
# inputs and environment

guard_registry() {
  if [[ ! $1 =~ $REGISTRY_RE ]]; then
    finish FAIL "registry $1 is outside zot.apps.okd.sudops.pl/okd-test"
  fi
}

validate() {
  case $MODE in
    full | check | catalog) ;;
    *) finish FAIL "MODE '${MODE}' is not full, check or catalog" ;;
  esac
  if [[ ! $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    finish FAIL "DATE '${DATE}' is not YYYY-MM-DD-HHMMSS"
  fi
  guard_registry "$BASE_REGISTRY"
  if [[ $MODE != catalog && (-z $PIPELINE_REPO || -z $PIPELINE_BRANCH) ]]; then
    finish FAIL "PIPELINE_REPO and PIPELINE_BRANCH are required"
  fi
  if [[ $MODE == catalog && ! -f /scripts/catalog-edit.sh ]]; then
    finish FAIL "catalog-edit.sh not present"
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
  # gettext: envsubst, which gitops/build.sh's build_bundle runs on env-override.yaml
  local -a rpms=(git make jq skopeo tar gzip gawk findutils diffutils which gettext)
  # The Fedora base ships curl (or curl-minimal); asking for "curl" next to curl-minimal conflicts.
  if ! command -v curl >/dev/null; then rpms+=(curl); fi
  # catalog-walk.py (MODE=catalog), standard library only
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

# Source gitops/build.sh (main() does not run when sourced) and read back its
# variables, so the image list always comes from the cloned pipeline, never from here.
load_vars() {  # load_vars <base registry> <associative array name>
  local base=$1 out="$RUN/vars-${2,,}.env" k v
  local -n arr=$2
  if ! env -C "$PIPE/gitops" BASE_REGISTRY="$base" DATE="$DATE" bash -c '
      source ./build.sh
      set +x
      printf "%s=%s\n" MAJOR "$MAJOR" MINOR "$MINOR" OCP_DATE "$OCP_DATE" REGISTRY "$REGISTRY"
      for v in $(compgen -v IMG_); do printf "%s=%s\n" "$v" "${!v}"; done
    ' >"$out" 2>"${out}.log"; then
    echo "ERROR sourcing gitops/build.sh with BASE_REGISTRY=${base} failed:"
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

guard_images() {  # every IMG_* in array $1 must be under registry $2, except the EXTERNAL ones
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
  if [[ ${#IMAGE_VARS[@]} == 0 || ${#BUNDLE_VARS[@]} == 0 ]]; then
    finish FAIL "gitops/build.sh defines no IMG_* or no IMG_BUNDLE* variables"
  fi
}

pipeline_step() {  # pipeline_step <registry> <build.sh step>
  step_start "$2"
  run_bg env -C "$PIPE/gitops" BASE_REGISTRY="$1" DATE="$DATE" bash ./build.sh "$2"
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

tag_check() {  # tag_check <ref>. P12: a run never re-pushes a tag
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
# verify

check() {  # check <name> PASS|FAIL <detail...>
  contract "CHECK $1 $2 ${*:3}"
  if [[ $2 == FAIL ]]; then VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

ref_repo() {  # repository of a ref with a digest and/or a tag
  local r=${1%@*}
  if [[ ${r##*/} == *:* ]]; then r=${r%:*}; fi
  echo "$r"
}

# Argo CD's own version, read from the argocd image this run built: its CLI, which the image
# ships at /usr/local/bin/argocd (BUILD_ALL_CLIS=false keeps the linux one). The first
# vX.Y.Z[...] in the output is the version; `--short` is tried first, then plain `--client`.
# The check passes only for EXACTLY EXPECTED_ARGOCD_VERSION.
argocd_version() {  # argocd_version <array name>
  local -n arr=$1
  local img=${arr[$ARGOCD_VAR]:-} out v= args
  step_start argocd-version
  if [[ -z $img ]]; then
    check argocd-version FAIL "${ARGOCD_VAR} is not defined by gitops/build.sh"
  else
    for args in "version --client --short" "version --client"; do
      out=$(podman run --rm --entrypoint argocd "$img" $args 2>&1) || true
      echo "INFO podman run --entrypoint argocd ${args}: $(echo "$out" | head -n 3 | tr '\n' ' ')"
      v=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*' <<<"$out" | head -n 1 || true)
      if [[ -n $v ]]; then break; fi
    done
    if [[ -n $v ]]; then
      contract "ARGOCD_VERSION ${v}"
      if [[ $v == "$EXPECTED_ARGOCD_VERSION" ]]; then
        check argocd-version PASS "${v} from ${img}"
      else
        check argocd-version FAIL "${v} from ${img}, want ${EXPECTED_ARGOCD_VERSION}"
      fi
    else
      check argocd-version FAIL "no version in the output of argocd ${args} in ${img}"
    fi
  fi
  step_end
}

# branding_check <csv.json> <pkg>. FAIL on any valid-subscription (keys or values) and on a
# support annotation that names Red Hat. "Red Hat" text elsewhere is reported, not failed:
# there is no accepted baseline for the gitops CSV yet (the first full run sets it).
branding_check() {
  local csv=$1 pkg=$2 vs support rh sample
  local -a problems=()
  vs=$( { jq -c . "$csv" | grep -oi 'valid-subscription' || true; } | wc -l | tr -d ' ')
  if [[ $vs != 0 ]]; then problems+=("${vs}x valid-subscription"); fi
  support=$(jq -r '.metadata.annotations.support // ""' "$csv")
  if grep -qiE 'red ?hat' <<<"$support"; then problems+=("support annotation '${support}'"); fi
  rh=$(jq -r '(.. | strings), ([paths | .[] | strings] | unique | .[])' "$csv" | grep -ci 'red hat' || true)
  sample=$(jq -r '(.. | strings)' "$csv" | grep -i 'red hat' | sed -n '1,3p' | cut -c1-100 | paste -sd '|' - || true)
  if [[ ${#problems[@]} == 0 ]]; then
    check "branding/${pkg}" PASS "no valid-subscription, support not Red Hat; ${rh} text lines mention Red Hat (reported, not failed): ${sample:-none}"
  else
    check "branding/${pkg}" FAIL "$(printf '%s; ' "${problems[@]}")${rh} Red Hat text lines"
  fi
}

verify() {  # verify <array name> <registry the bundles reference>
  local -n arr=$1
  local reg=$2 name ref repo digest dir pkg max n src img k v want_version want_name prov
  local re='^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$'   # what must follow "${reg}/"
  local ext_exact=" " ext_repos=" "
  local -a bad notbuilt ext_used
  # The external images gitops/build.sh names: a digest value is accepted exactly, a tag value
  # (redis) stands for its repository, where the bundle carries the digest it resolved to.
  for k in "${!arr[@]}"; do
    if [[ $k =~ $EXTERNAL_VAR_RE ]]; then
      v=${arr[$k]}
      if [[ $v == *@sha256:* ]]; then ext_exact+="${v} "; else ext_repos+="$(ref_repo "$v") "; fi
    fi
  done
  step_start verify
  for name in "${BUNDLE_VARS[@]}"; do
    ref=${arr[$name]}
    repo=${ref%:*}
    digest=${DIGEST[$repo]}
    dir=$RUN/verify/$name
    mkdir -p "$dir"
    opm render "${repo}@${digest}" -o json >"$dir/render.json"
    jq -s 'map(select(.schema == "olm.bundle")) | first' "$dir/render.json" >"$dir/bundle.json"
    pkg=$(jq -r '.package // "unknown"' "$dir/bundle.json")
    jq '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson
         | select(.kind == "ClusterServiceVersion")] | first' "$dir/bundle.json" >"$dir/csv.json"
    if [[ $(jq -r 'type' "$dir/csv.json") != object ]]; then
      check "csv/${pkg}" FAIL "no ClusterServiceVersion in opm render ${repo}@${digest}"
      continue
    fi
    echo "INFO verify ${pkg} ${repo}@${digest} $(jq -r '.metadata.name' "$dir/csv.json")"

    # The CSV is gitops-operator.v<MAJOR>.<MINOR>.0-<DATE>, the entry catalog-edit.sh adds.
    want_version=${arr[OCP_DATE]:-}
    want_name="gitops-operator.v${want_version}"
    n=$(jq -r '[.metadata.name, .spec.version] | join(" ")' "$dir/csv.json")
    if [[ -n $want_version && $pkg == gitops-operator && $n == "${want_name} ${want_version}" ]]; then
      check "csv/${pkg}" PASS "$n"
    else
      check "csv/${pkg}" FAIL "package ${pkg}, CSV '${n}', want gitops-operator '${want_name} ${want_version}'"
    fi
    # Global constraints on the whole rendered CSV, each a FAIL.
    n=$(jq -c . "$dir/csv.json" | grep -oiE 'registry\.redhat\.io|registry-proxy\.engineering\.redhat\.com|brew\.registry' | sort -u | paste -sd ' ' - || true)
    if [[ -z $n ]]; then
      check "no-redhat-registry/${pkg}" PASS "no registry.redhat.io, registry-proxy.engineering.redhat.com or brew.registry reference in the CSV"
    else
      check "no-redhat-registry/${pkg}" FAIL "CSV references: ${n}"
    fi
    n=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json")
    if [[ -n $want_version && $n == ">=1.0.0 <${want_version}" ]]; then
      check "skip-range/${pkg}" PASS "$n"
    else
      check "skip-range/${pkg}" FAIL "olm.skipRange '${n}', want '>=1.0.0 <${want_version}'"
    fi
    n=$(jq -r '.spec.replaces // "null"' "$dir/csv.json")
    if [[ $n == null ]]; then
      check "no-replaces/${pkg}" PASS "spec.replaces is not set"
    else
      check "no-replaces/${pkg}" FAIL "spec.replaces is '${n}', want none (the catalog entry carries replaces)"
    fi
    # What the CSV says about its own edges: catalog-edit.sh sets the real ones in the channel.
    echo "INFO csv ${pkg} replaces=$(jq -r '.spec.replaces // "none"' "$dir/csv.json") skips=$(jq -c '.spec.skips // "none"' "$dir/csv.json") olm.skipRange=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json")"

    max=$(jq -r '[.properties[]? | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | first // "none"' "$dir/bundle.json")
    check "max-openshift-version/${pkg}" PASS "${max} (reported: the pipeline does not set it for gitops; the 1.19 bundle in the catalog has none)"

    # relatedImages, plus every RELATED_IMAGE_* / *_IMAGE env value in the CSV's deployments
    {
      jq -r '.relatedImages[]?.image | "relatedImages " + .' "$dir/bundle.json"
      jq -r '.spec.install.spec.deployments[]?.spec.template.spec
             | ((.containers // []) + (.initContainers // []))[] | .env[]?
             | select(.name | test("^RELATED_IMAGE_|_IMAGE$")) | select(.value != null)
             | "env:" + .name + " " + .value' "$dir/csv.json"
    } | sort -u >"$dir/images.txt"
    bad=()
    notbuilt=()
    ext_used=()
    while read -r src img; do
      # The images the pipeline takes from outside BASE_REGISTRY on purpose (EXTERNAL_VAR_RE).
      if [[ $ext_exact == *" ${img} "* ]] \
        || [[ $ext_repos == *" $(ref_repo "$img") "* && $img =~ @sha256:[0-9a-f]{64}$ ]]; then
        ext_used+=("$img")
        continue
      fi
      if [[ $img == "$reg"/* && ${img#"$reg"/} =~ $re ]]; then
        if [[ ${DIGEST[${img%@*}]:-} != "${img#*@}" ]]; then notbuilt+=("${src}=${img}"); fi
      else
        bad+=("${src}=${img}")
      fi
    done <"$dir/images.txt"
    n=$(wc -l <"$dir/images.txt")
    if [[ ${#bad[@]} == 0 ]]; then
      check "images/${pkg}" PASS "${n} refs, all ${reg}/...@sha256 or an external image of gitops/build.sh"
    else
      check "images/${pkg}" FAIL "${bad[*]}"
    fi
    if [[ ${#notbuilt[@]} == 0 ]]; then
      check "images-built/${pkg}" PASS "every ${reg} ref is a digest this run pushed"
    else
      check "images-built/${pkg}" FAIL "not pushed by this run: ${notbuilt[*]}"
    fi
    if [[ ${#ext_used[@]} != 0 ]]; then
      check "external-images/${pkg}" PASS "$(printf '%s\n' "${ext_used[@]}" | sort -u | paste -sd ' ' -)"
    fi

    branding_check "$dir/csv.json" "$pkg"

    prov=$(jq -r '.spec.provider.name // "missing"' "$dir/csv.json")
    if [[ $prov == "OKD Community" ]]; then
      check "provider/${pkg}" PASS "$prov"
    else
      check "provider/${pkg}" FAIL "${prov}, want OKD Community"
    fi
  done
  step_end
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "verify: ${VERIFY_FAILS} checks failed"
  fi
}

# ---------------------------------------------------------------------------------------
# modes

# Start of MODE=full: always prune. The PVC still holds layers of earlier runs (the logging build
# left ~37 GB) and nothing on it needs keeping. After the prune the base layers are pulled again,
# so peak = max(DISK) of the run approximates a fresh hosted runner (stop rule: peak > 14 GB).
# `podman system prune -af` cannot be scoped to some images, and does not need to be.
prune() {
  step_start prune
  disk
  run_bg podman system prune -af
  disk
  step_end
}

mode_full() {
  local s name
  prune

  step_start clone
  clone_pipeline
  load_vars "$BASE_REGISTRY" V
  guard_images V "$BASE_REGISTRY"
  split_vars V
  step_end

  # P12: a run never re-pushes a tag. Every image and the bundle, not just the operator.
  step_start tag-check
  for name in "${IMAGE_VARS[@]}" "${BUNDLE_VARS[@]}"; do
    tag_check "${V[$name]}"
  done
  step_end

  for s in init build_containers push_containers; do
    pipeline_step "$BASE_REGISTRY" "$s"
  done
  argocd_version V
  report_pushed V "${IMAGE_VARS[@]}"
  pipeline_step "$BASE_REGISTRY" build_bundle
  report_pushed V "${BUNDLE_VARS[@]}"
  pipeline_step "$BASE_REGISTRY" deinit
  verify V "$BASE_REGISTRY"
}

mode_check() {
  local slug check_registry name
  slug=${PIPELINE_BRANCH,,}
  slug=${slug//[^a-z0-9._-]/-}
  check_registry="${BASE_REGISTRY}/check-${slug}"
  guard_registry "$check_registry"

  step_start clone
  clone_pipeline
  load_vars "$BASE_REGISTRY" SRC
  guard_images SRC "$BASE_REGISTRY"
  load_vars "$check_registry" V
  guard_images V "$check_registry"
  split_vars V
  step_end

  # P12: a run never re-pushes a tag. Every image and bundle tag this run pushes under
  # check-<slug>/ must be absent, before anything is pushed.
  step_start tag-check
  for name in "${IMAGE_VARS[@]}" "${BUNDLE_VARS[@]}"; do
    tag_check "${V[$name]}"
  done
  step_end

  # Reuse the images a full run pushed for this DATE; zot dedupes the blobs.
  step_start copy
  for name in "${IMAGE_VARS[@]}"; do
    run_bg skopeo copy --all --quiet --retry-times 3 "docker://${SRC[$name]}" "docker://${V[$name]}"
  done
  step_end
  report_pushed V "${IMAGE_VARS[@]}"

  pipeline_step "$check_registry" init
  pipeline_step "$check_registry" build_bundle
  report_pushed V "${BUNDLE_VARS[@]}"
  pipeline_step "$check_registry" deinit
  verify V "$check_registry"
}

mode_catalog() {
  local n rc=0
  local -A C=([IMG_CATALOG]="${BASE_REGISTRY}/gitops-catalog:${DATE}")
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
    check) mode_check ;;
    catalog) mode_catalog ;;
  esac
  finish PASS "${MODE} ${DATE}"
}

main "$@"
