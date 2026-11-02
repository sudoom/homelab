#!/bin/bash
# Entry point of the okderators-descheduler-build Job (see README.md in this directory). Same contract
# lines, tool pins, log persistence, lock and push guards as tests/okderators-nmstate-build/build.sh;
# PRUNE and the image smoke tests come from tests/okderators-oadp-build/build.sh. It runs the
# pipeline's kube-descheduler/build.sh and checks the two images and the 5.4 bundle.
#
# Runs as root in a privileged podman pod in namespace okd-build, with the PVC build-storage mounted
# at /var/lib/containers (subPath containers) and /work (subPath work).
#
# Inputs (env, set by job-template.yaml):
#   MODE              full | catalog
#   PIPELINE_REPO     okd-operator-pipeline clone URL
#   PIPELINE_BRANCH   MODE=full: descheduler-5.4-4.22 or descheduler-5.4, a row of BRANCHES below
#   DATE              YYYY-MM-DD-HHMMSS, new per run; the suffix of the image tags, the catalog tag
#                     and the log file names. A run refuses a DATE whose log file already exists.
#   PRUNE             MODE=full only: true (default) prunes the podman graph root first, false keeps the
#                     layers of an earlier run (a retry after a failed round); logs INFO when it skips
#   BASE_REGISTRY     must be zot.apps.okd.sudops.pl/okd-test or a path under it
#   CATALOG_BRANCHES  MODE=catalog only, passed through to catalog-edit.sh
#   BUNDLES           MODE=catalog only, passed through to catalog-edit.sh
#                     (<catalog-branch>=<bundle ref@digest>, space-separated)
#   IMAGE_BRANCH      MODE=catalog only, passed through to catalog-edit.sh (default release-4.22)
# MODE=catalog pushes one image, ${BASE_REGISTRY}/descheduler-catalog:${DATE}, chosen and guarded here.
#
# Machine-greppable output (everything else is free-form):
#   STEP <name> START|END <epoch seconds>
#   DISK <bytes>                     du of /var/lib/containers + /work, after every step (and twice
#                                    around the prune that starts MODE=full)
#   PUSHED <ref>@<digest> <bytes>    bytes = config + layer sizes in the registry manifest
#   CHECK <name> PASS|FAIL <detail>
#   RESULT PASS|FAIL <reason>
# The contract lines are also appended to /work/logs/descheduler-build-<MODE>-<DATE>.contract, and the
# whole output is copied to /work/logs/descheduler-build-<MODE>-<DATE>.log, so both survive a deleted
# pod or a rotated container log. A lock on /work/.lock keeps a second run off the same PVC.
#
# Written for bash 3.2 as well (no associative arrays, namerefs or mapfile), like catalog-edit.sh, so
# the checks run on the Mac against fixtures. Sourcing this file does not run main.
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # bash 4.4+: the pod has it, the Mac's 3.2 does not

MODE=${MODE:-}
PIPELINE_REPO=${PIPELINE_REPO:-https://github.com/sudoom/okd-operator-pipeline.git}
PIPELINE_BRANCH=${PIPELINE_BRANCH:-}
DATE=${DATE:-}
PRUNE=${PRUNE:-true}
BASE_REGISTRY=${BASE_REGISTRY:-zot.apps.okd.sudops.pl/okd-test}
CATALOG_BRANCHES=${CATALOG_BRANCHES:-}
BUNDLES=${BUNDLES:-}
IMAGE_BRANCH=${IMAGE_BRANCH:-release-4.22}

# zot mirrors quay.io, docker.io, ghcr.io and registry.k8s.io for the whole cluster under
# one namespace: a push outside okd-test/ could shadow a real upstream image.
REGISTRY_RE='^zot\.apps\.okd\.sudops\.pl/okd-test(/[a-z0-9]+([._-][a-z0-9]+)*)*$'

# skopeo errors that mean "this tag or repository does not exist"; anything else fails closed.
# zot answers NAME_UNKNOWN for a repository nobody has pushed yet, which skopeo prints as
# "repository name not known to registry" (the first full run, 2026-10-20). 404 must stand
# alone: every error quotes the ref, and a DATE like ...-140412 contains the digits 404.
ABSENT_RE='manifest unknown|name unknown|repository name not known|not found|(^|[^0-9])404([^0-9]|$)'

# What the bundle must be (README.md, "Verify").
OP_DIR=kube-descheduler              # the operator's directory in okd-operator-pipeline
PKG=cluster-kube-descheduler-operator
CSV_PREFIX=clusterkubedescheduleroperator
CRD_NAME=kubedeschedulers.operator.openshift.io
RELEASE=5.4                          # kube-descheduler/build.sh MAJOR.MINOR
WANT_IMAGES=2                        # IMG_OPERATOR and IMG_DESCHEDULER
OPERATOR_SUB=kube-descheduler/operator
OPERAND_SUB=kube-descheduler/descheduler
FORBIDDEN_REGISTRY_RE='registry\.redhat\.io|registry-proxy|brew\.registry|quay\.io/openshift'

# One row per pipeline branch this Job builds: the OKD release its common.sh targets, the operator
# and descheduler pins (the heads of release-4.22 and release-5.0 on 2026-11-02), the version the
# descheduler's Makefile stamps at its pin (GO_LD_EXTRAFLAGS), the CSV's olm.maxOpenShiftVersion, and
# its minKubeVersion ("-": recorded, no required value). A bump changes this table and the branch
# together: submodule-pins stops the run before the build if they disagree.
BRANCHES='descheduler-5.4-4.22 4.22 1eb4d75fac7d2999e06792c3856bdccb272b1de3 076d0fc5c3e74b76885c07a393f4085a6495da16 v20260219-v0.35.0 4.23 1.35.0
descheduler-5.4 5.0 5c0659fc46ba82ea3f3ab36acd95b19d3847a77e ca28d9e98897d401d38d0886a4341620fe838c4e v20260520-v0.36.0 5.1 -'

# Which IMG_* variable each RELATED_IMAGE_* of the CSV must point at, the same mapping as
# build_bundle(): the set comparison would pass a swap, so it is also checked by name.
RELATED_ENV='RELATED_IMAGE_OPERAND_IMAGE IMG_DESCHEDULER
RELATED_IMAGE_SOFTTAINTER_IMAGE IMG_OPERATOR'

# Pinned tools. Every sha256 is the one the project publishes (GitHub release checksums files,
# mirror.openshift.com sha256sum.txt).
OPERATOR_SDK_VERSION=v1.36.1
OPERATOR_SDK_SHA256=25872268c422fb63a350d85741a1f26052c953c7e9654167b0e8dbd6dbfb6c1d
OPM_VERSION=v1.74.0
OPM_SHA256=cf1bd699be72e0a4511208afdf45444fc47d21eb2ffed0c204520ff50b5a4691
YQ_VERSION=v4.54.1
YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
OC_VERSION=4.21.36
OC_SHA256=f38cbe69694ebca49f067b9e3830f62c62c27bbe29dd00ad29c11c45509fde42

# A container the smoke test starts must end by itself. The images are local by then, and a help
# text or a version takes no time, so this is what "hung" means.
SMOKE_TIMEOUT=120

SCRIPTS=/scripts
WORK=/work
RUN=$WORK/run              # wiped at the start of every run
PIPE=$RUN/pipeline
TOOLS=$WORK/tools
CACHE=$WORK/cache          # kept between runs: downloads, dnf metadata
VARS=$RUN/vars.env         # the variables read from kube-descheduler/build.sh, KEY=VALUE
DIGESTS=$RUN/digests.tsv   # <repository> <digest> this run pushed

LOGS=$WORK/logs
LOCK=$WORK/.lock

STEP_NAME=validate
RESULT_DONE=0
CHILD=
CONTRACT=                  # set by open_logs; empty until then (stdout only)
TEE_PID=
VERIFY_FAILS=0
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
  local base="$LOGS/descheduler-build-${MODE}-${DATE}"
  mkdir -p "$LOGS"
  if [[ -e ${base}.contract || -e ${base}.log ]]; then
    finish FAIL "DATE ${DATE} was already used for MODE=${MODE}: ${base}.* exist, a run needs a new DATE"
  fi
  exec > >(tee -a "${base}.log") 2>&1
  TEE_PID=${!:-}
  CONTRACT="${base}.contract"
  : >"$CONTRACT"
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

# No code path prints RESULT PASS while a CHECK failed: this counts the failures in memory and, in
# case a check ran in a subshell or catalog-edit.sh printed it, in the contract file too.
finish() {  # finish PASS|FAIL <reason...>
  local n=0
  RESULT_DONE=1
  if [[ $1 == PASS ]]; then
    if [[ -n $CONTRACT && -f $CONTRACT ]]; then
      n=$(grep -c '^CHECK [^ ]* FAIL' "$CONTRACT" || true)
    fi
    if [[ $VERIFY_FAILS != 0 || $n != 0 ]]; then
      contract "RESULT FAIL ${VERIFY_FAILS} checks failed in this run, ${n} FAIL lines in the contract (finish ${*:2})"
      exit 1
    fi
  fi
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
# RWO only keeps pods on other nodes away. flock is released when this process dies. The lock
# file is the one the logging, GitOps, NMState and OADP Jobs take, so none of them overlaps another.
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
  local bytes free
  bytes=$(du -sx --block-size=1 /var/lib/containers "$WORK" 2>/dev/null | awk '{s += $1} END {printf "%d\n", s}') || true
  contract "DISK ${bytes:-0}"
  # Free space on the shared PVC, for reading a build as it goes.
  free=$(df -Pk "$WORK" 2>/dev/null | awk 'NR == 2 {printf "%d\n", $4 * 1024}') || true
  echo "INFO free ${free:-unknown} bytes on ${WORK}"
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

branch_field() {  # branch_field <column>: this PIPELINE_BRANCH's BRANCHES value; empty without a row
  awk -v b="$PIPELINE_BRANCH" -v c="$1" '$1 == b {print $c}' <<<"$BRANCHES"
}

validate() {
  local date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$'
  case $MODE in
    full | catalog) ;;
    *) finish FAIL "MODE '${MODE}' is not full or catalog" ;;
  esac
  if [[ ! $DATE =~ $date_re ]]; then
    finish FAIL "DATE '${DATE}' is not YYYY-MM-DD-HHMMSS"
  fi
  if [[ $PRUNE != true && $PRUNE != false ]]; then
    finish FAIL "PRUNE must be true or false, got '${PRUNE}'"
  fi
  guard_registry "$BASE_REGISTRY"
  if [[ $MODE == full ]]; then
    if [[ -z $PIPELINE_REPO || -z $PIPELINE_BRANCH ]]; then
      finish FAIL "PIPELINE_REPO and PIPELINE_BRANCH are required"
    fi
    if [[ -z $(branch_field 2) ]]; then
      finish FAIL "PIPELINE_BRANCH '${PIPELINE_BRANCH}' has no row in the BRANCHES table of build.sh"
    fi
  fi
  if [[ $MODE == catalog && (! -f $SCRIPTS/catalog-edit.sh || ! -f $SCRIPTS/catalog-branches.tsv) ]]; then
    finish FAIL "catalog-edit.sh or catalog-branches.tsv not present"
  fi
}

print_inputs() {
  echo "INFO PRUNE=${PRUNE}"
  echo "INFO MODE=${MODE} DATE=${DATE} BASE_REGISTRY=${BASE_REGISTRY}"
  echo "INFO PIPELINE_REPO=${PIPELINE_REPO} PIPELINE_BRANCH=${PIPELINE_BRANCH}"
  echo "INFO CATALOG_BRANCHES=${CATALOG_BRANCHES} BUNDLES=${BUNDLES} IMAGE_BRANCH=${IMAGE_BRANCH}"
  echo "INFO node=${NODE_NAME:-unknown} nproc=$(nproc)"
}

setup_env() {
  # Everything big or cached goes to the PVC, not to the container's root fs (node disk).
  export HOME=$WORK/home
  export TMPDIR=$WORK/tmp
  export PATH=$TOOLS/bin:$PATH
  export BUILDAH_ISOLATION=chroot
}

make_dirs() {  # after take_lock
  mkdir -p "$HOME" "$TMPDIR" "$TOOLS/bin" "$CACHE/dl"
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

# The compilers run inside the Containerfiles (go-toolset), and kube-descheduler/build.sh edits the
# committed manifests with yq, so the pod needs neither Go, kustomize nor make.
install_tools() {
  local -a rpms=(git jq skopeo tar gzip gawk findutils diffutils)
  # The Fedora base ships curl (or curl-minimal); asking for "curl" next to curl-minimal conflicts.
  if ! command -v curl >/dev/null; then rpms+=(curl); fi
  # catalog-edit.sh and catalog-walk.py (MODE=catalog), standard library only
  if ! command -v python3 >/dev/null; then rpms+=(python3); fi
  dnf -y -q --setopt=install_weak_deps=False --setopt=system_cachedir="$CACHE/dnf" install "${rpms[@]}"

  fetch "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_linux_amd64" \
    "$OPERATOR_SDK_SHA256" "operator-sdk-${OPERATOR_SDK_VERSION}"
  install -m 0755 "$CACHE/dl/operator-sdk-${OPERATOR_SDK_VERSION}" "$TOOLS/bin/operator-sdk"

  fetch "https://github.com/operator-framework/operator-registry/releases/download/${OPM_VERSION}/linux-amd64-opm" \
    "$OPM_SHA256" "opm-${OPM_VERSION}"
  install -m 0755 "$CACHE/dl/opm-${OPM_VERSION}" "$TOOLS/bin/opm"

  fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    "$YQ_SHA256" "yq-${YQ_VERSION}"
  install -m 0755 "$CACHE/dl/yq-${YQ_VERSION}" "$TOOLS/bin/yq"

  fetch "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}/openshift-client-linux-${OC_VERSION}.tar.gz" \
    "$OC_SHA256" "openshift-client-linux-${OC_VERSION}.tar.gz"
  tar -C "$TOOLS/bin" -xzf "$CACHE/dl/openshift-client-linux-${OC_VERSION}.tar.gz" oc

  echo "INFO tool $(first_line operator-sdk version)"
  echo "INFO tool opm $(first_line opm version)"
  echo "INFO tool $(first_line yq --version)"
  echo "INFO tool oc $(first_line oc version --client)"
  echo "INFO tool $(first_line podman --version)"
  echo "INFO tool $(first_line skopeo --version)"
  echo "INFO tool $(first_line git --version)"
  echo "INFO tool $(first_line jq --version)"
  echo "INFO tool $(first_line python3 --version)"
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
  rm -rf "${RUN:?}"
  mkdir -p "$RUN"
  git clone --quiet --depth 1 --branch "$PIPELINE_BRANCH" "$PIPELINE_REPO" "$PIPE"
  echo "INFO pipeline ${PIPELINE_REPO} ${PIPELINE_BRANCH} $(git -C "$PIPE" rev-parse HEAD)"
}

var() {  # var <name>: a variable load_vars read from kube-descheduler/build.sh; empty if it has none
  awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2); exit}' "$VARS"
}

pins() {  # one "<submodule path> <commit>" line per submodule of this PIPELINE_BRANCH
  echo "${OPERATOR_SUB} $(branch_field 3)"
  echo "${OPERAND_SUB} $(branch_field 4)"
}

pin_of() {  # pin_of <submodule path>: its pinned commit; empty if it is not pinned
  pins | awk -v p="$1" '$1 == p {print $2}'
}

# Source kube-descheduler/build.sh (main() does not run when sourced) and read back its variables, so
# the image list always comes from the cloned pipeline, never from here. OKD_VERSION is the branch's
# common.sh default: it names the OKD release, MAJOR and MINOR are the operator's own 5.4.
load_vars() {
  if ! env -C "$PIPE/$OP_DIR" BASE_REGISTRY="$BASE_REGISTRY" DATE="$DATE" bash -c '
      source ./build.sh
      set +x
      printf "%s=%s\n" MAJOR "$MAJOR" MINOR "$MINOR" OCP_SHORT "$OCP_SHORT" OCP_DATE "$OCP_DATE" \
        REGISTRY "$REGISTRY" OKD_VERSION "$OKD_VERSION" OCP_RELEASE "$OCP_RELEASE" OCP_NEXT "$OCP_NEXT"
      for v in $(compgen -v IMG_); do printf "%s=%s\n" "$v" "${!v}"; done
    ' >"$VARS" 2>"${VARS}.log"; then
    echo "ERROR sourcing ${OP_DIR}/build.sh with BASE_REGISTRY=${BASE_REGISTRY} failed:"
    tail -n 20 "${VARS}.log"
    return 1
  fi
  sort "$VARS" | sed 's/^/INFO var /'
}

guard_images() {  # every IMG_* must be under ${REGISTRY}/
  local reg k v
  reg=$(var REGISTRY)
  while IFS='=' read -r k v; do
    if [[ $k != IMG_* ]]; then continue; fi
    if [[ $v != "$reg/"* ]]; then
      finish FAIL "${k}=${v} is outside ${reg}"
    fi
  done <"$VARS"
}

split_vars() {  # fill IMAGE_VARS (built images, operator included) and BUNDLE_VARS
  local k
  IMAGE_VARS=()
  BUNDLE_VARS=()
  for k in $(awk -F= '/^IMG_/ {print $1}' "$VARS" | sort); do
    if [[ $k == IMG_BUNDLE* ]]; then
      BUNDLE_VARS+=("$k")
    else
      IMAGE_VARS+=("$k")
    fi
  done
  if [[ ${#IMAGE_VARS[@]} != "$WANT_IMAGES" || ${#BUNDLE_VARS[@]} != 1 ]]; then
    finish FAIL "${OP_DIR}/build.sh defines ${#IMAGE_VARS[@]} images and ${#BUNDLE_VARS[@]} bundles, want ${WANT_IMAGES} and 1"
  fi
}

pipeline_step() {  # pipeline_step <build.sh step>
  step_start "$1"
  run_bg env -C "$PIPE/$OP_DIR" BASE_REGISTRY="$BASE_REGISTRY" DATE="$DATE" bash ./build.sh "$1"
  step_end
}

prepare_pipeline() {
  clone_pipeline
  load_vars
  if [[ $(var REGISTRY) != "${BASE_REGISTRY}/${OP_DIR}" ]]; then
    finish FAIL "${OP_DIR}/build.sh REGISTRY is '$(var REGISTRY)', want ${BASE_REGISTRY}/${OP_DIR}"
  fi
  if [[ $(var OCP_SHORT) != "$RELEASE" ]]; then
    finish FAIL "${OP_DIR}/build.sh builds $(var OCP_SHORT), want ${RELEASE}"
  fi
  if [[ $(var OCP_RELEASE) != "$(branch_field 2)" ]]; then
    finish FAIL "${PIPELINE_BRANCH} targets OKD $(var OCP_RELEASE) (OKD_VERSION $(var OKD_VERSION)), the BRANCHES table says $(branch_field 2)"
  fi
  guard_images
  split_vars
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

ref_repo() {  # repository of a ref with a digest and/or a tag
  local r=${1%@*}
  if [[ ${r##*/} == *:* ]]; then r=${r%:*}; fi
  echo "$r"
}

digest_of() {  # digest_of <repo>: the digest this run recorded for it; empty if none
  if [[ -f $DIGESTS ]]; then awk -v r="$1" '$1 == r {d = $2} END {print d}' "$DIGESTS"; fi
}

report_pushed_ref() {  # report_pushed_ref <ref>
  local ref=$1 repo digest bytes
  repo=$(ref_repo "$ref")
  digest=$(ref_digest "$ref")
  echo "${repo} ${digest}" >>"$DIGESTS"
  bytes=$(ref_bytes "$repo" "$digest") || bytes=unknown
  contract "PUSHED ${ref}@${digest} ${bytes}"
}

report_pushed() {  # report_pushed <IMG_* names...>
  local name
  for name in "$@"; do
    report_pushed_ref "$(var "$name")"
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
# checks: the gate before anything slow

check() {  # check <name> PASS|FAIL <detail...>
  contract "CHECK $1 $2 ${*:3}"
  if [[ $2 == FAIL ]]; then VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

gate() {  # gate <where>: stop here if a check failed so far
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "$1: ${VERIFY_FAILS} checks failed"
  fi
}

submodule_status() {  # what init left: git's own view, one line per submodule
  git -C "$PIPE" submodule status -- "${OP_DIR}/"
}

# submodule-pins, right after init: both submodules are exactly at their pins with no patch on top
# (the pipeline has no kube-descheduler/patches). Read from `git submodule status`, because the gitlink
# is what gets built, not .gitmodules. The first column matters: "-" prints the recorded commit
# although nothing is checked out, and submodule_initialize hides a failed update with `|| true`, so a
# bare SHA comparison would pass with the submodule missing.
check_submodule_pins() {
  local out=$RUN/submodule-status.txt line flag rest sha sub want n=0 seen=" "
  local -a bad=()
  if ! submodule_status >"$out" 2>"${out}.err"; then
    check submodule-pins FAIL "git submodule status failed: $(head -n 2 "${out}.err" | one_line)"
    return 0
  fi
  while IFS= read -r line; do
    if [[ -z $line ]]; then continue; fi
    flag=${line:0:1}
    rest=${line:1}
    sha=${rest%% *}
    rest=${rest#* }
    sub=${rest%% *}
    want=$(pin_of "$sub")
    n=$((n + 1))
    seen="${seen}${sub} "
    if [[ -z $want ]]; then
      bad+=("${sub}: not in the pins")
    elif [[ $flag == - ]]; then
      bad+=("${sub}: not initialised")
    elif [[ $flag != " " || $sha != "$want" ]]; then
      bad+=("${sub}: flag '${flag}' HEAD ${sha}, pin ${want}")
    fi
  done <"$out"
  for sub in "$OPERATOR_SUB" "$OPERAND_SUB"; do
    if [[ $seen != *" ${sub} "* ]]; then bad+=("${sub}: missing from git submodule status"); fi
  done
  if [[ ${#bad[@]} == 0 ]]; then
    check submodule-pins PASS "${n} submodules initialised, each HEAD = pin: $(pins | awk '{printf "%s %s ", $1, substr($2, 1, 12)}' | sed 's/ $//')"
  else
    check submodule-pins FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-600)"
  fi
}

pins_gate() {
  step_start pins
  check_submodule_pins
  step_end
  gate "init did not leave the pinned tree"
}

# ---------------------------------------------------------------------------------------
# checks: the images, before they are pushed: a broken image stops here and takes no space in zot.
# Both images run even after a failure, so one round shows all of it.

SMOKE_DIR=
SMOKE_FAILED=

podman_run() {  # podman_run <output file> <podman run arguments...>; $? is the container's
  local out=$1
  shift
  timeout -k 10 "$SMOKE_TIMEOUT" podman run --rm "$@" >"$out" 2>&1
}

tail_of() {  # tail_of <file>: its last lines as one line, for a FAIL detail
  tail -n 3 "$1" 2>/dev/null | one_line
}

smoke_help() {  # smoke_help <image name> <ref> <binary> <text its --help prints>
  local name=$1 ref=$2 binary=$3 text=$4 out=$SMOKE_DIR/$1.help rc=0
  podman_run "$out" --entrypoint "$binary" "$ref" --help || rc=$?
  if [[ $rc == 0 ]] && grep -qF "$text" "$out"; then
    check "image-smoke/${name}" PASS "${binary} --help exit 0, prints '${text}'"
  else
    SMOKE_FAILED="${SMOKE_FAILED} ${name}"
    check "image-smoke/${name}" FAIL "${binary} --help exit ${rc}, want 0 and '${text}': $(tail_of "$out")"
  fi
}

# operand-version: the binary reports what the Makefile's GO_LD_EXTRAFLAGS stamped at the pin. A
# binary with no stamp prints an empty GitVersion.
check_operand_version() {
  local ref out got want rc=0
  want=$(branch_field 5)
  ref=$(var IMG_DESCHEDULER)
  out=$SMOKE_DIR/descheduler.version
  podman_run "$out" --entrypoint /usr/bin/descheduler "$ref" version || rc=$?
  got=$(sed -nE 's/.*GitVersion:([^ }]*).*/\1/p' "$out" | head -n 1)
  if [[ $rc == 0 && -n $want && $got == "$want" ]]; then
    check operand-version PASS "${got} from ${ref}"
  else
    check operand-version FAIL "descheduler version exit ${rc}, GitVersion '${got}', want ${want:-no row}: $(tail_of "$out")"
  fi
}

image_checks() {
  step_start image-smoke
  SMOKE_DIR=$RUN/smoke
  SMOKE_FAILED=
  mkdir -p "$SMOKE_DIR"
  smoke_help operator "$(var IMG_OPERATOR)" /usr/bin/cluster-kube-descheduler-operator 'Start the Cluster kube-descheduler Operator'
  smoke_help descheduler "$(var IMG_DESCHEDULER)" /usr/bin/descheduler 'The descheduler evicts pods'
  if [[ -z $SMOKE_FAILED ]]; then
    check image-smoke PASS "2 images: each ran its own binary"
  else
    check image-smoke FAIL "failed:${SMOKE_FAILED}"
  fi
  check_operand_version
  step_end
}

# ---------------------------------------------------------------------------------------
# checks: the bundle

# The bundle image's files as zot serves them: skopeo copies the manifest and layers to a dir:
# layout (blobs named by their hex digest), and each layer is unpacked into <dir>/fs in order.
bundle_extract() {  # bundle_extract <repo@digest> <dir>
  local ref=$1 dir=$2 hex blob
  rm -rf "${dir:?}/image" "${dir:?}/fs"
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

# What the operator pin's own manifests/ holds. From git objects, because build_bundle() edits the
# CSV in the working tree. <dir>/pin-manifests.
pin_manifests() {  # pin_manifests <dir>
  local dir=$1 pin
  pin=$(pin_of "$OPERATOR_SUB")
  rm -rf "${dir:?}/pin" "${dir:?}/pin-manifests"
  mkdir -p "$dir/pin"
  git -C "$PIPE/$OPERATOR_SUB" archive "$pin" manifests | tar -xf - -C "$dir/pin"
  mv "$dir/pin/manifests" "$dir/pin-manifests"
}

object_set() {  # the file's or objects' identity: Kind/name, one CSV whatever its name
  sed -E 's|^ClusterServiceVersion/.*|ClusterServiceVersion/*|' | LC_ALL=C sort
}

# bundle-objects: exactly what the pin's manifests/ lists, in the image's files and in what opm
# renders. Anything outside FAILs, and so does anything missing: a dropped manifest is a broken install.
# Both pins list only the CSV and the CRD, so the operator's RBAC is not a manifest: it is the CSV's
# install.spec.clusterPermissions and, on release-5.0, install.spec.permissions, the networkpolicies
# rule among them. build_bundle() leaves both alone, so they must equal the pin's: names alone would
# pass a bundle without that rule, and it would only show when the operator runs.
check_bundle_objects() {  # <dir>
  local dir=$1
  local f extra missing n_crd n_csv roots pin_csv rbac_diff
  local got_files=$dir/files.got want_files=$dir/files.want got_objs=$dir/objects.got want_objs=$dir/objects.want
  local got_rbac=$dir/rbac.got want_rbac=$dir/rbac.want rbac_filter='.spec.install.spec | {clusterPermissions, permissions}'
  local -a bad=()
  if [[ ! -d $dir/fs/manifests ]]; then
    check bundle-objects FAIL "bundle image not extracted"
    return 0
  fi
  if [[ ! -d $dir/pin-manifests ]]; then
    check bundle-objects FAIL "the operator pin's manifests/ could not be read"
    return 0
  fi
  (cd "$dir/fs/manifests" && find . -type f | sed 's|^\./||') | LC_ALL=C sort >"$got_files"
  (cd "$dir/pin-manifests" && find . -type f | sed 's|^\./||') | LC_ALL=C sort >"$want_files"
  extra=$(LC_ALL=C comm -23 "$got_files" "$want_files" | paste -sd ' ' -)
  missing=$(LC_ALL=C comm -13 "$got_files" "$want_files" | paste -sd ' ' -)
  if [[ -n $extra ]]; then bad+=("files not in the pin's list: ${extra}"); fi
  if [[ -n $missing ]]; then bad+=("files missing: ${missing}"); fi

  for f in "$dir/pin-manifests"/*; do
    yq e '.kind + "/" + .metadata.name' "$f"
  done | object_set >"$want_objs"
  jq -r '.[] | .kind + "/" + (.metadata.name // "-")' "$dir/objects.json" | object_set >"$got_objs"
  extra=$(LC_ALL=C comm -23 "$got_objs" "$want_objs" | paste -sd ' ' -)
  missing=$(LC_ALL=C comm -13 "$got_objs" "$want_objs" | paste -sd ' ' -)
  if [[ -n $extra ]]; then bad+=("objects not in the pin's list: ${extra}"); fi
  if [[ -n $missing ]]; then bad+=("objects missing: ${missing}"); fi

  n_crd=$(jq --arg n "$CRD_NAME" '[.[] | select(.kind == "CustomResourceDefinition" and .metadata.name == $n)] | length' "$dir/objects.json")
  n_csv=$(jq '[.[] | select(.kind == "ClusterServiceVersion")] | length' "$dir/objects.json")
  if [[ $n_crd != 1 || $n_csv != 1 ]]; then
    bad+=("${n_crd} CRDs ${CRD_NAME}, ${n_csv} CSVs; want 1 and 1")
  fi

  roots=$(cd "$dir/fs" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort | paste -sd ' ' -)
  if [[ $roots != "manifests metadata" ]]; then
    bad+=("image top level '${roots}', want manifests metadata")
  fi

  pin_csv=
  for f in "$dir/pin-manifests"/*; do
    if [[ $(yq e '.kind' "$f") == ClusterServiceVersion ]]; then pin_csv=$f; fi
  done
  if [[ -z $pin_csv ]]; then
    bad+=("no ClusterServiceVersion among the pin's manifests")
  else
    yq -o=json e '.' "$pin_csv" | jq -S "$rbac_filter" >"$want_rbac"
    jq -S "$rbac_filter" "$dir/csv.json" >"$got_rbac"
    if ! cmp -s "$got_rbac" "$want_rbac"; then
      rbac_diff=$( { diff "$want_rbac" "$got_rbac" || true; } | grep '^[<>]' | head -n 6 | one_line || true)
      bad+=("the CSV's clusterPermissions and permissions differ from the pin's (< pin, > bundle): ${rbac_diff}")
    fi
  fi

  if [[ ${#bad[@]} == 0 ]]; then
    check bundle-objects PASS "the pin's list exactly: $(paste -sd ' ' "$got_files"); RBAC as the pin's: $(jq '[.clusterPermissions[]?.rules[]?] | length' "$got_rbac") clusterPermissions rules, $(jq '[.permissions[]?.rules[]?] | length' "$got_rbac") permissions rules"
  else
    check bundle-objects FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-700)"
  fi
}

check_no_redhat_registry() {  # <dir>: the CSV, every bundle object, the bundle files and labels
  local dir=$1 n
  local -a hits=()
  n=$( { jq -c . "$dir/csv.json" | grep -oiE "$FORBIDDEN_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
  if [[ -n $n ]]; then hits+=("CSV: ${n}"); fi
  n=$( { jq -c . "$dir/objects.json" | grep -oiE "$FORBIDDEN_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
  if [[ -n $n ]]; then hits+=("bundle objects: ${n}"); fi
  if [[ -d $dir/fs ]]; then
    n=$( { grep -rliE "$FORBIDDEN_REGISTRY_RE" "$dir/fs" || true; } | sed "s|^${dir}/fs/||" | paste -sd ' ' -)
    if [[ -n $n ]]; then hits+=("bundle files: ${n}"); fi
    n=$( { jq -c '.config.Labels // {}' "$dir/config.json" | grep -oiE "$FORBIDDEN_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
    if [[ -n $n ]]; then hits+=("bundle labels: ${n}"); fi
  else
    hits+=("bundle image not extracted")
  fi
  if [[ ${#hits[@]} == 0 ]]; then
    check no-redhat-registry PASS "no registry.redhat.io, registry-proxy, brew.registry or quay.io/openshift in the CSV, the bundle objects, the bundle files or labels"
  else
    check no-redhat-registry FAIL "$(printf '%s; ' "${hits[@]}")"
  fi
}

check_csv_name() {  # <dir>: clusterkubedescheduleroperator.v5.4.0-<DATE>; the release is build.sh's own
  local dir=$1 want_version="${RELEASE}.0-${DATE}" want_name pkg pv n
  want_name="${CSV_PREFIX}.v${want_version}"
  pkg=$(jq -r '.package // "none"' "$dir/bundle.json")
  pv=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "$dir/bundle.json")
  n=$(jq -r '[.metadata.name, .spec.version] | join(" ")' "$dir/csv.json")
  if [[ $pkg == "$PKG" && $n == "${want_name} ${want_version}" && $pv == "$want_version" \
    && $(var OCP_DATE) == "$want_version" ]]; then
    check csv-name PASS "${n}"
  else
    check csv-name FAIL "package ${pkg}, CSV '${n}', olm.package version ${pv}, OCP_DATE $(var OCP_DATE); want ${PKG} '${want_name} ${want_version}'"
  fi
  # build_bundle() deletes the CSV's replaces; catalog-edit.sh sets the real edges in the channel entry.
  echo "INFO csv replaces=$(jq -r '.spec.replaces // "none"' "$dir/csv.json") olm.skipRange=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json")"
}

# images-by-digest, as a set: relatedImages (CSV, and what opm renders minus the bundle itself) are
# exactly the built images, each ${REGISTRY}/<name>@<digest this run recorded>. Then by name, because
# a swap would pass as a set: each RELATED_IMAGE_* env, the deployment's containers and init
# containers, and the containerImage annotation.
check_images_by_digest() {  # <dir>; needs <dir>/built.tsv: <IMG var> <repo> <digest>
  local dir=$1
  local want=$dir/images.want
  local list extra missing bundle_ref name var_name wanted got n operator_ref want_n
  local -a bad=()
  bundle_ref=$(jq -r '.image // ""' "$dir/bundle.json")
  awk '{print $2 "@" $3}' "$dir/built.tsv" | LC_ALL=C sort -u >"$want"
  jq -r '.spec.relatedImages[]?.image' "$dir/csv.json" | LC_ALL=C sort -u >"$dir/images.csv"
  jq -r --arg b "$bundle_ref" '.relatedImages[]?.image | select(. != $b)' "$dir/bundle.json" | LC_ALL=C sort -u >"$dir/images.rendered"
  for list in csv rendered; do
    extra=$(LC_ALL=C comm -13 "$want" "$dir/images.${list}" | paste -sd ' ' -)
    missing=$(LC_ALL=C comm -23 "$want" "$dir/images.${list}" | paste -sd ' ' -)
    if [[ -n $extra ]]; then bad+=("${list} relatedImages not a digest this run recorded: ${extra}"); fi
    if [[ -n $missing ]]; then bad+=("${list} relatedImages missing: ${missing}"); fi
  done

  while read -r name var_name; do
    wanted=$(awk -v k="$var_name" '$1 == k {print $2 "@" $3}' "$dir/built.tsv")
    got=$(jq -r --arg n "$name" '[.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.env[]?
          | select(.name == $n) | .value] | first // ""' "$dir/csv.json")
    if [[ -z $wanted || $got != "$wanted" ]]; then bad+=("${name}=${got:-unset}, want ${wanted:-no ${var_name}}"); fi
  done <<<"$RELATED_ENV"
  n=$(jq '[.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.env[]?
        | select(.name | test("^RELATED_IMAGE_|_IMAGE$"))] | length' "$dir/csv.json")
  want_n=$(wc -l <<<"$RELATED_ENV" | tr -d ' ')
  if [[ $n != "$want_n" ]]; then
    bad+=("${n} RELATED_IMAGE_* and *_IMAGE env entries, want ${want_n}")
  fi

  operator_ref=$(awk '$1 == "IMG_OPERATOR" {print $2 "@" $3}' "$dir/built.tsv")
  got=$(jq -r '[.spec.install.spec.deployments[]?.spec.template.spec | ((.containers // []) + (.initContainers // []))[] | .image] | join(" ")' "$dir/csv.json")
  if [[ $got != "$operator_ref" ]]; then bad+=("deployment images '${got}', want only ${operator_ref}"); fi
  got=$(jq -r '.metadata.annotations.containerImage // ""' "$dir/csv.json")
  if [[ $got != "$operator_ref" ]]; then bad+=("containerImage annotation '${got}', want ${operator_ref}"); fi

  if [[ ${#bad[@]} == 0 ]]; then
    check images-by-digest PASS "$(wc -l <"$want" | tr -d ' ') refs, all by digest under $(var REGISTRY)/ and recorded by this run: $(paste -sd ' ' "$want"); env, container and annotation match by name"
  else
    check images-by-digest FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-900)"
  fi
}

# max-ocp: the cap OLM reads, in the CSV annotation build_bundle() writes and in what opm renders from
# it. The expected value comes from the BRANCHES table, not from the pipeline's own OCP_NEXT: a bundle
# built under the wrong OKD_VERSION carries a wrong cap and would agree with that variable.
check_max_ocp() {  # <dir>
  local dir=$1 want annotation rendered
  want=$(branch_field 6)
  annotation=$(jq -r '.metadata.annotations["olm.properties"] // "[]" | fromjson
    | [.[] | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | join(" ")' "$dir/csv.json" 2>/dev/null) || annotation=unparsable
  rendered=$(jq -r '[.properties[]? | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | join(" ")' "$dir/bundle.json")
  if [[ -n $want && $annotation == "$want" && $rendered == "$want" ]]; then
    check max-ocp PASS "olm.maxOpenShiftVersion ${want} on ${PIPELINE_BRANCH}, in the CSV annotation and in opm render"
  else
    check max-ocp FAIL "CSV annotation '${annotation}', opm render '${rendered}', want ${want:-no row} on ${PIPELINE_BRANCH}"
  fi
}

check_min_kube() {  # <dir>: recorded; the value is required where the BRANCHES table names one
  local dir=$1 want got
  want=$(branch_field 7)
  got=$(jq -r '.spec.minKubeVersion // ""' "$dir/csv.json")
  if [[ -z $got ]]; then
    check min-kube FAIL "the CSV has no spec.minKubeVersion"
  elif [[ $want == - ]]; then
    check min-kube PASS "${got} (recorded on ${PIPELINE_BRANCH})"
  elif [[ $got == "$want" ]]; then
    check min-kube PASS "${got} on ${PIPELINE_BRANCH}"
  else
    check min-kube FAIL "${got}, want ${want:-no row} on ${PIPELINE_BRANCH}"
  fi
}

# operator-sdk bundle validate on the extracted bundle directory (no image builder needed); the
# default validators.
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

# Every bundle check, on the prepared directory: render.json-derived bundle.json, objects.json and
# csv.json, config.json and fs/ from the image, pin-manifests/ and built.tsv.
verify_dir() {  # <dir>
  local dir=$1
  check_bundle_objects "$dir"
  check_no_redhat_registry "$dir"
  if [[ $(jq -r 'type' "$dir/csv.json") == object ]]; then
    check_csv_name "$dir"
    check_images_by_digest "$dir"
    check_max_ocp "$dir"
    check_min_kube "$dir"
  else
    check csv-name FAIL "no ClusterServiceVersion in the rendered bundle"
  fi
  check_operator_sdk "$dir"
}

verify() {
  local ref repo digest dir name
  step_start verify
  ref=$(var "${BUNDLE_VARS[0]}")
  repo=$(ref_repo "$ref")
  digest=$(digest_of "$repo")
  dir=$RUN/verify
  mkdir -p "$dir"
  opm render "${repo}@${digest}" -o json >"$dir/render.json"
  jq -s 'map(select(.schema == "olm.bundle")) | first' "$dir/render.json" >"$dir/bundle.json"
  jq '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson]' \
    "$dir/bundle.json" >"$dir/objects.json"
  jq '[.[] | select(.kind == "ClusterServiceVersion")] | first' "$dir/objects.json" >"$dir/csv.json"
  echo "INFO verify ${repo}@${digest} $(jq -r '.name // "no olm.bundle"' "$dir/bundle.json")"
  for name in "${IMAGE_VARS[@]}"; do
    repo=$(ref_repo "$(var "$name")")
    echo "${name} ${repo} $(digest_of "$repo")"
  done >"$dir/built.tsv"
  repo=$(ref_repo "$ref")
  if ! bundle_extract "${repo}@${digest}" "$dir"; then
    echo "ERROR could not extract ${repo}@${digest}; the file-level parts of the checks fail"
    rm -rf "${dir:?}/fs"
  fi
  pin_manifests "$dir" || echo "ERROR could not read manifests/ of the operator pin"
  verify_dir "$dir"
  step_end
  gate "verify"
}

# No RESULT PASS unless every check of the mode really ran: a skipped branch of the flow must not
# read as a green run. Names as printed, one per word; the contract file is the record.
REQUIRED_FULL='submodule-pins image-smoke operand-version bundle-objects no-redhat-registry csv-name images-by-digest max-ocp min-kube operator-sdk-validate'
require_checks() {  # require_checks <names...>
  local name
  local -a absent=()
  for name in "$@"; do
    if ! grep -q "^CHECK ${name} PASS" "$CONTRACT"; then absent+=("$name"); fi
  done
  if [[ ${#absent[@]} != 0 ]]; then
    finish FAIL "${MODE}: no PASS line for ${absent[*]}"
  fi
}

# What MODE=catalog must have shown for one branch: a fresh package has no old head to strand, so
# fresh-head stands in for the two negative controls.
catalog_required() {  # catalog_required <branch>: check names, one per line
  local b=$1 replaces
  replaces=$(awk -F '\t' -v b="$b" '$0 !~ /^#/ && $1 == b {print $2}' "$SCRIPTS/catalog-branches.tsv")
  printf '%s\n' "branch-data-${b}" "bundle-${b}" "bundles-${b}" "edit-${b}" "opm-validate-${b}" "walk-${b}"
  if [[ $replaces == NONE ]]; then
    echo "fresh-head-${b}"
  else
    printf '%s\n' "negative-control-no-edge-${b}" "negative-control-replaces-only-${b}"
  fi
}

# ---------------------------------------------------------------------------------------
# modes

# Start of MODE=full: prune unless PRUNE=false. A retry after a failed round passes PRUNE=false so a
# failure late in the build does not repeat the compile. The PVC still holds layers of earlier runs
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

tag_checks() {  # a run never re-pushes a tag: every image and the bundle
  local name
  step_start tag-check
  for name in "${IMAGE_VARS[@]}" "${BUNDLE_VARS[@]}"; do
    tag_check "$(var "$name")"
  done
  step_end
}

mode_full() {
  if [[ $PRUNE == true ]]; then
    prune
  else
    echo "INFO prune skipped, PRUNE=false: layers of an earlier run stay on the PVC, so the peak DISK is not a fresh-runner figure"
  fi

  step_start clone
  prepare_pipeline
  step_end

  tag_checks

  pipeline_step init
  pins_gate

  pipeline_step build_containers
  image_checks
  gate "the images are not pushed"

  pipeline_step push_containers
  report_pushed "${IMAGE_VARS[@]}"
  pipeline_step build_bundle
  report_pushed "${BUNDLE_VARS[@]}"
  verify
  pipeline_step deinit
  # shellcheck disable=SC2086  # a word list
  require_checks $REQUIRED_FULL
}

mode_catalog() {
  local n rc=0 catalog_ref b
  catalog_ref="${BASE_REGISTRY}/descheduler-catalog:${DATE}"
  guard_registry "${catalog_ref%:*}"
  rm -rf "${RUN:?}"
  mkdir -p "$RUN"

  step_start tag-check
  tag_check "$catalog_ref"
  step_end

  export RUN_DIR=$RUN CATALOG_IMAGE=$catalog_ref CATALOG_BRANCHES BUNDLES IMAGE_BRANCH
  step_start catalog-edit
  # run_bg without its errexit: the CHECK lines are copied whatever the script's exit status.
  env -C "$RUN" SCRIPTS="$SCRIPTS" bash -c 'set -o pipefail; bash "$SCRIPTS/catalog-edit.sh" 2>&1 | tee "$RUN_DIR/catalog-edit.log"' &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=
  step_end
  # catalog-edit.sh prints its CHECK lines to stdout; copy them into the contract file too
  grep '^CHECK ' "$RUN/catalog-edit.log" >>"$CONTRACT" || true
  # A pushed catalog image is reported even if a later check failed, so it can be deleted.
  if [[ -f $RUN/catalog-image.pushed ]]; then
    report_pushed_ref "$catalog_ref"
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
  require_checks catalog-image
  for b in $CATALOG_BRANCHES; do
    # shellcheck disable=SC2046  # a word list
    require_checks $(catalog_required "$b")
  done
}

main() {
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
