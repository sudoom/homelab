#!/bin/bash
# Entry point of the okderators-oadp-build Job (see README.md in this directory). Adapted from
# tests/okderators-nmstate-build/build.sh: same contract lines, tool pins, log persistence, lock,
# prune and push guards, plus the bundle-only `check` mode of tests/okderators-logging-build/. It runs
# the pipeline's oadp/build.sh and checks the OADP 1.6 bundle and the eight images new in 1.6.
#
# Runs as root in a privileged podman pod in namespace okd-build, with the PVC build-storage mounted
# at /var/lib/containers (subPath containers) and /work (subPath work).
#
# Inputs (env, set by job-template.yaml):
#   MODE              full | check | catalog
#   PIPELINE_REPO     okd-operator-pipeline clone URL
#   PIPELINE_BRANCH   MODE=full and check: oadp-1.6-4.22 or oadp-1.6
#   OKD_VERSION       optional; only selects the payload `cli` image must-gather copies. Empty = the
#                     branch's common.sh default. oadp/build.sh sets MAJOR=1 MINOR=6 itself, so this
#                     never changes the CSV version or the image tags.
#   DATE              YYYY-MM-DD-HHMMSS, new per run; the suffix of the image tags, the catalog tag
#                     and the log file names. A run refuses a DATE whose log file already exists.
#   REUSE_DATE        MODE=check only: the DATE of the full run whose images the bundle references
#   PRUNE             MODE=full only: true (default) prunes the podman graph root first, false keeps the
#                     layers of an earlier run (a retry after a failed round); logs INFO when it skips
#   BASE_REGISTRY     must be zot.apps.okd.sudops.pl/okd-test or a path under it
#   CATALOG_BRANCHES  MODE=catalog only, passed through to catalog-edit.sh
#   BUNDLES           MODE=catalog only, passed through to catalog-edit.sh
#                     (<catalog-branch>=<bundle ref@digest>, space-separated)
#   IMAGE_BRANCH      MODE=catalog only, passed through to catalog-edit.sh (default release-4.22)
# MODE=catalog pushes one image, ${BASE_REGISTRY}/oadp-catalog:${DATE}, chosen and guarded here.
#
# Machine-greppable output (everything else is free-form):
#   STEP <name> START|END <epoch seconds>
#   DISK <bytes>                     du of /var/lib/containers + /work, after every step (and twice
#                                    around the prune that starts MODE=full)
#   PUSHED <ref>@<digest> <bytes>    bytes = config + layer sizes in the registry manifest
#   CHECK <name> PASS|FAIL <detail>
#   RESULT PASS|FAIL <reason>
# The contract lines are also appended to /work/logs/oadp-build-<MODE>-<DATE>.contract, and the
# whole output is copied to /work/logs/oadp-build-<MODE>-<DATE>.log, so both survive a deleted pod
# or a rotated container log. A lock on /work/.lock keeps a second run off the same PVC.
#
# Written for bash 3.2 as well (no associative arrays, namerefs or mapfile), like catalog-edit.sh, so
# the checks run on the Mac against fixtures. Sourcing this file does not run main.
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # bash 4.4+: the pod has it, the Mac's 3.2 does not

MODE=${MODE:-}
PIPELINE_REPO=${PIPELINE_REPO:-https://github.com/sudoom/okd-operator-pipeline.git}
PIPELINE_BRANCH=${PIPELINE_BRANCH:-}
DATE=${DATE:-}
REUSE_DATE=${REUSE_DATE:-}
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

# The one IMG_* variable of oadp/build.sh that is not built here: the OKD release payload's cli, by
# digest, which must-gather copies. It is never pushed. Anything else outside ${REGISTRY}/ is a failure.
EXTERNAL_VAR_RE='^IMG_CLI$'
EXTERNAL_REF_RE='^quay\.io/okd/scos-content@sha256:[0-9a-f]{64}$'

# What the bundle must be (README.md, "Verify").
OP_DIR=oadp                          # the operator's directory in okd-operator-pipeline
PKG=oadp-operator
RELEASE=1.6                          # oadp/build.sh MAJOR.MINOR
WANT_IMAGES=19                       # the 18 RELATED_IMAGE_* plus the operator
CRDS_OADP=10                         # *.oadp.openshift.io
CRDS_VELERO=13                       # *.velero.io
OPERATOR_SUB=oadp/operator
VELERO_VERSION=v1.18.4-OADP          # pins.md v1.18.4, with the suffix the Containerfile adds
REDHAT_REGISTRY_RE='registry\.redhat\.io|registry-proxy\.engineering\.redhat\.com|brew\.registry'
KONVEYOR=quay.io/konveyor

# The 19 submodules at their oadp-1.6 heads of 2026-11-02 (pins.md). A bump changes this table and
# the branch together: pipeline-gitlinks stops the run within seconds if they disagree.
PINS='oadp/operator 483de5e05055352af7500c46bf40f5b9b447ddb8
oadp/velero 6ec33ac9e956d7b0c40d31e8b0f488e3d8f195ed
oadp/non-admin 2367e0fd45af64340ae6ccf9178431f23c8cbec7
oadp/microsoft-azure-plugin a86e14da028620ca75ee1f871cdd3e30e5be9e96
oadp/openshift-plugin 20bdc74f99d2b51f90ae9adecf95b2dd26ba1379
oadp/hypershift-plugin 72eda2d96f9ea1d2ac52c7b1ba1dddfe117ad7b5
oadp/aws-plugin 56b4e23f49da3c553068172554a0bbba9d7f92fc
oadp/gcp-plugin 2b5d9c2ea53f1108dbfb31799270822ff5780efb
oadp/kubevirt-plugin e645e0ee0dff181c0054d648e78bbbda2aca1aa6
oadp/aws-legacy-plugin 987244c299d11f15ad9e71d09af4490d7b375bc4
oadp/kopia f83e62070a5dc7db7b75aa0f571f29bf369012dc
oadp/restic e808d4d5a3b2033a4163cf7b9b97717fc61c0c2a
oadp/must-gather 0064b510b36d738a084ebd8a9b71f6716d544f7c
oadp/vm-file-restore adb1fb33567403870c54442b8b01c726a74a7bde
oadp/filebrowser 4cc1e14b67c93dc2c09b4dcf653c40bdbfec1cfa
oadp/oadp-cli d6d9554acb6d3bcca06d0a4bedeaf63e71ef281c
oadp/oadp-vmdp 9bd14fca9b7ec78e2bba3cf95cf5677c6860ed92
oadp/kubevirt-datamover-controller 80e27eca886d28ba84f8a14aa91909b511b59c41
oadp/kubevirt-datamover-plugin 4f21f4d3f59ae48791964d27d4fdd65a5f2bd26e'

# Submodules that carry one commit on top of the pin, from patches/<name>.patch: path|subject.
PATCHED='oadp/operator|OKDify
oadp/vm-file-restore|Read the access and sidecar images from the environment'

# Which IMG_* variable each RELATED_IMAGE_* of the operator's manager.yaml must point at. The same
# mapping as build_bundle(): a swap passes a set comparison, so it is checked by name.
RELATED_ENV='RELATED_IMAGE_VELERO IMG_VELERO
RELATED_IMAGE_OPENSHIFT_VELERO_PLUGIN IMG_OPENSHIFT_PLUGIN
RELATED_IMAGE_VELERO_PLUGIN_FOR_AWS IMG_AWS_PLUGIN
RELATED_IMAGE_VELERO_PLUGIN_FOR_LEGACY_AWS IMG_AWS_LEGACY_PLUGIN
RELATED_IMAGE_VELERO_PLUGIN_FOR_MICROSOFT_AZURE IMG_AZURE_PLUGIN
RELATED_IMAGE_VELERO_PLUGIN_FOR_GCP IMG_GCP_PLUGIN
RELATED_IMAGE_KUBEVIRT_VELERO_PLUGIN IMG_KUBEVIRT_PLUGIN
RELATED_IMAGE_HYPERSHIFT_VELERO_PLUGIN IMG_HYPERSHIFT_PLUGIN
RELATED_IMAGE_MUSTGATHER IMG_MUST_GATHER
RELATED_IMAGE_NON_ADMIN_CONTROLLER IMG_NON_ADMIN
RELATED_IMAGE_VM_FILE_RESTORE_CONTROLLER IMG_VM_FILE_RESTORE
RELATED_IMAGE_VM_FILE_RESTORE_ACCESS IMG_VMFR_ACCESS
RELATED_IMAGE_VM_FILE_RESTORE_SSH IMG_VMFR_SSHD
RELATED_IMAGE_VM_FILE_RESTORE_BROWSER IMG_VMFR_FILEBROWSER
RELATED_IMAGE_CONSOLE_CLI_DOWNLOAD IMG_CLI_BINARIES
RELATED_IMAGE_VMDP_CLI_DOWNLOAD IMG_VMDP_BINARIES
RELATED_IMAGE_KUBEVIRT_DATAMOVER_CONTROLLER IMG_KUBEVIRT_DATAMOVER_CONTROLLER
RELATED_IMAGE_KUBEVIRT_DATAMOVER_PLUGIN IMG_KUBEVIRT_DATAMOVER_PLUGIN'

# Every program detect-and-mount.sh and entrypoint.sh of oadp-vmfr-access call, read at the
# vm-file-restore pin. A virtual libguestfs-tools could install without guestmount.
VMFR_ACCESS_TOOLS='guestmount guestunmount fusermount qemu-img python3 mountpoint mount grep awk sed basename mkdir date sleep tail'
VMFR_ENV_NAMES='VMFR_ACCESS_IMAGE VMFR_SSH_IMAGE VMFR_BROWSER_IMAGE'

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

# A container the smoke test starts must end by itself; this is what "hung" means (first pull in
# MODE=check included). The download servers have their own, shorter limits.
SMOKE_TIMEOUT=600

SCRIPTS=/scripts
WORK=/work
RUN=$WORK/run              # wiped at the start of every run
PIPE=$RUN/pipeline
TOOLS=$WORK/tools
CACHE=$WORK/cache          # kept between runs: downloads, dnf metadata, Go caches
VARS=$RUN/vars.env         # the variables read from oadp/build.sh, KEY=VALUE
DIGESTS=$RUN/digests.tsv   # <repository> <digest> this run pushed or copied

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
  local base="$LOGS/oadp-build-${MODE}-${DATE}"
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
# file is the one the logging, GitOps and NMState Jobs take, so none of them overlaps another.
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
  # Free space on the PVC, for reading a build as it goes: 19 images come close to its 100 Gi (README).
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

validate() {
  local date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$'
  case $MODE in
    full | check | catalog) ;;
    *) finish FAIL "MODE '${MODE}' is not full, check or catalog" ;;
  esac
  if [[ ! $DATE =~ $date_re ]]; then
    finish FAIL "DATE '${DATE}' is not YYYY-MM-DD-HHMMSS"
  fi
  if [[ $PRUNE != true && $PRUNE != false ]]; then
    finish FAIL "PRUNE must be true or false, got '${PRUNE}'"
  fi
  guard_registry "$BASE_REGISTRY"
  if [[ $MODE != catalog && (-z $PIPELINE_REPO || -z $PIPELINE_BRANCH) ]]; then
    finish FAIL "PIPELINE_REPO and PIPELINE_BRANCH are required"
  fi
  if [[ $MODE == check ]]; then
    if [[ ! $REUSE_DATE =~ $date_re ]]; then
      finish FAIL "MODE=check needs REUSE_DATE, the DATE of a full run; got '${REUSE_DATE}'"
    fi
    if [[ $REUSE_DATE == "$DATE" ]]; then
      finish FAIL "DATE must be new: it equals REUSE_DATE ${REUSE_DATE}"
    fi
  elif [[ -n $REUSE_DATE ]]; then
    finish FAIL "REUSE_DATE is only for MODE=check, this is MODE=${MODE}"
  fi
  if [[ $MODE == catalog && (! -f $SCRIPTS/catalog-edit.sh || ! -f $SCRIPTS/catalog-branches.tsv) ]]; then
    finish FAIL "catalog-edit.sh or catalog-branches.tsv not present"
  fi
}

print_inputs() {
  echo "INFO PRUNE=${PRUNE}"
  echo "INFO MODE=${MODE} DATE=${DATE} REUSE_DATE=${REUSE_DATE} BASE_REGISTRY=${BASE_REGISTRY}"
  echo "INFO PIPELINE_REPO=${PIPELINE_REPO} PIPELINE_BRANCH=${PIPELINE_BRANCH}"
  echo "INFO CATALOG_BRANCHES=${CATALOG_BRANCHES} BUNDLES=${BUNDLES} IMAGE_BRANCH=${IMAGE_BRANCH}"
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

var() {  # var <name>: a variable load_vars read from oadp/build.sh; empty if it has none
  awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2); exit}' "$VARS"
}

pin_of() {  # pin_of <submodule path>: its pinned commit; empty if it is not in the table
  awk -v p="$1" '$1 == p {print $2}' <<<"$PINS"
}

patched_subject() {  # patched_subject <submodule path>: the patch commit's subject; empty if none
  awk -F'|' -v p="$1" '$1 == p {print $2}' <<<"$PATCHED"
}

# Source oadp/build.sh (main() does not run when sourced) and read back its variables, so the image
# list always comes from the cloned pipeline, never from here. OKD_VERSION (if set) is inherited from
# the Job's environment, as in every pipeline_step.
load_vars() {
  if ! env -C "$PIPE/$OP_DIR" BASE_REGISTRY="$BASE_REGISTRY" DATE="$DATE" bash -c '
      source ./build.sh
      set +x
      printf "%s=%s\n" MAJOR "$MAJOR" MINOR "$MINOR" OCP_SHORT "$OCP_SHORT" OCP_DATE "$OCP_DATE" \
        REGISTRY "$REGISTRY" OKD_VERSION "$OKD_VERSION"
      for v in $(compgen -v IMG_); do printf "%s=%s\n" "$v" "${!v}"; done
    ' >"$VARS" 2>"${VARS}.log"; then
    echo "ERROR sourcing ${OP_DIR}/build.sh with BASE_REGISTRY=${BASE_REGISTRY} failed:"
    tail -n 20 "${VARS}.log"
    return 1
  fi
  sort "$VARS" | sed 's/^/INFO var /'
}

guard_images() {  # every IMG_* must be under ${REGISTRY}/, except the EXTERNAL one
  local reg k v
  reg=$(var REGISTRY)
  if [[ ! $(var IMG_CLI) =~ $EXTERNAL_REF_RE ]]; then
    finish FAIL "IMG_CLI='$(var IMG_CLI)' is not the payload's cli image by digest"
  fi
  while IFS='=' read -r k v; do
    if [[ $k != IMG_* || $k =~ $EXTERNAL_VAR_RE ]]; then continue; fi
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
    elif [[ ! $k =~ $EXTERNAL_VAR_RE ]]; then
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
# checks: the gates before anything slow

check() {  # check <name> PASS|FAIL <detail...>
  contract "CHECK $1 $2 ${*:3}"
  if [[ $2 == FAIL ]]; then VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

gate() {  # gate <where>: stop here if a check failed so far
  if [[ $VERIFY_FAILS != 0 ]]; then
    finish FAIL "$1: ${VERIFY_FAILS} checks failed"
  fi
}

# pipeline-gitlinks: right after the clone. A wrong PIPELINE_BRANCH ends here in seconds. The gitlink
# is what gets built, not .gitmodules (CLAUDE.md; submodule_reset ignores the branch argument).
check_pipeline_gitlinks() {  # <pipeline dir>; returns 1 on FAIL
  local pipe=$1 got=$RUN/gitlinks.got want=$RUN/gitlinks.want n
  git -C "$pipe" ls-tree HEAD "${OP_DIR}/" | awk '$2 == "commit" {print $4, $3}' | LC_ALL=C sort >"$got"
  LC_ALL=C sort <<<"$PINS" >"$want"
  n=$(wc -l <"$got" | tr -d ' ')
  if cmp -s "$got" "$want"; then
    check pipeline-gitlinks PASS "${n} ${OP_DIR}/ gitlinks are the pins"
  else
    check pipeline-gitlinks FAIL "${n} gitlinks, differences (< branch, > pins): $(diff "$got" "$want" | grep '^[<>]' | head -n 6 | one_line)"
    return 1
  fi
}

# gitmodules-branch: informational. Every submodule should declare oadp-<OCP_SHORT>, but .gitmodules is
# not what gets built (the check above is), so a mismatch prints INFO and is neither a CHECK line nor
# a required check. It is the only place the branch name is recorded for the next `update`.
check_gitmodules_branch() {  # <pipeline dir> <OCP_SHORT>; always returns 0
  local pipe=$1 want="oadp-$2" path got n=0
  local -a bad=()
  while read -r path _; do
    got=$(git config -f "${pipe}/.gitmodules" "submodule.${path}.branch" 2>/dev/null || echo none)
    n=$((n + 1))
    if [[ $got != "$want" ]]; then bad+=("${path}=${got}"); fi
  done <<<"$PINS"
  if [[ ${#bad[@]} == 0 ]]; then
    echo "INFO gitmodules-branch ${n} submodules declare ${want}"
  else
    echo "INFO gitmodules-branch ${bad[*]} in .gitmodules, want ${want} (not what gets built, no check)"
  fi
}

prepare_pipeline() {
  clone_pipeline
  load_vars
  if [[ $(var REGISTRY) != "${BASE_REGISTRY}/${OP_DIR}" ]]; then
    finish FAIL "${OP_DIR}/build.sh REGISTRY is '$(var REGISTRY)', want ${BASE_REGISTRY}/${OP_DIR}"
  fi
  if [[ $(var OCP_SHORT) != "$RELEASE" ]]; then
    finish FAIL "${OP_DIR}/build.sh builds $(var OCP_SHORT), want ${RELEASE}: is ${PIPELINE_BRANCH} the 1.6 branch?"
  fi
  guard_images
  split_vars
  check_pipeline_gitlinks "$PIPE" || true
  check_gitmodules_branch "$PIPE" "$RELEASE" || true
  gate "${PIPELINE_BRANCH} is not the pinned 1.6 tree"
}

submodule_status() {  # what init left: git's own view, one line per submodule
  git -C "$PIPE" submodule status -- "${OP_DIR}/"
}

# submodule-pins, right after init: the submodules without a patch are exactly at their pins. Read
# from `git submodule status`, because a submodule's .git is a file, so its binaries stamp no
# vcs.revision. The first column matters: "-" prints the recorded commit although nothing is checked
# out, and submodule_initialize hides a failed update with `|| true`, so a bare SHA comparison would
# pass with the submodule missing. A patched one must show "+"; operator-commit reads it further.
check_submodule_pins() {
  local out=$RUN/submodule-status.txt line flag rest sha path want n=0
  local -a bad=()
  local seen=" "
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
    path=${rest%% *}
    want=$(pin_of "$path")
    n=$((n + 1))
    seen="${seen}${path} "
    if [[ -z $want ]]; then
      bad+=("${path}: not in the pins")
    elif [[ $flag == - ]]; then
      bad+=("${path}: not initialised")
    elif [[ -n $(patched_subject "$path") ]]; then
      if [[ $flag != + ]]; then bad+=("${path}: flag '${flag}', want a patch commit on top of the pin"); fi
    elif [[ $flag != " " || $sha != "$want" ]]; then
      bad+=("${path}: flag '${flag}' HEAD ${sha}, pin ${want}")
    fi
  done <"$out"
  while read -r path _; do
    if [[ $seen != *" ${path} "* ]]; then bad+=("${path}: missing from git submodule status"); fi
  done <<<"$PINS"
  if [[ ${#bad[@]} == 0 ]]; then
    check submodule-pins PASS "${n} submodules initialised; every one without a patch has HEAD = pin"
  else
    check submodule-pins FAIL "${#bad[@]} of ${WANT_IMAGES}: $(printf '%s; ' "${bad[@]}" | cut -c1-600)"
  fi
}

# operator-commit, right after init: git am adds one commit in each patched submodule, so "HEAD ==
# gitlink" would lie either way. HEAD~1 is the pin, HEAD is the patch, the tree is clean.
check_operator_commit() {
  local sub subject want_subject parent got_subject dirty pin
  local -a bad=() good=()
  while IFS='|' read -r sub want_subject; do
    pin=$(pin_of "$sub")
    parent=$(git -C "$PIPE/$sub" rev-parse 'HEAD~1' 2>/dev/null) || parent=none
    got_subject=$(git -C "$PIPE/$sub" log -1 --format=%s HEAD 2>/dev/null) || got_subject=none
    dirty=$(git -C "$PIPE/$sub" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty=unknown
    if [[ $parent == "$pin" && $got_subject == "$want_subject" && $dirty == 0 ]]; then
      good+=("${sub} HEAD~1=${pin:0:12} '${got_subject}'")
    else
      bad+=("${sub}: HEAD~1 ${parent} (pin ${pin}), subject '${got_subject}' (want '${want_subject}'), ${dirty} changed paths")
    fi
  done <<<"$PATCHED"
  if [[ ${#bad[@]} == 0 ]]; then
    check operator-commit PASS "$(printf '%s; ' "${good[@]}")clean trees"
  else
    check operator-commit FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-600)"
  fi
}

pins_gate() {
  step_start pins
  check_submodule_pins
  check_operator_commit
  step_end
  gate "init did not leave the pinned tree"
}

# ---------------------------------------------------------------------------------------
# base images

base_refs() {  # the FROM refs of the pipeline's Containerfiles; $IMG_CLI is in the vars already
  awk '$1 == "FROM" {print $2}' "$PIPE/$OP_DIR"/*.Containerfile | grep -v '\$' | LC_ALL=C sort -u
}

# Before the build: a base that cannot be resolved would fail one Containerfile hours in. The digests
# go in the log because `:latest` UBI bases and `go-toolset:1.26` move.
check_base_images() {
  local ref digest n=0
  local -a bad=()
  step_start base-images
  for ref in $(base_refs); do
    n=$((n + 1))
    if digest=$(skopeo inspect --no-tags --retry-times 3 --override-os linux --override-arch amd64 \
        --format '{{.Digest}}' "docker://${ref}" 2>&1); then
      echo "INFO base ${ref} ${digest} (registry, before the build)"
    else
      bad+=("${ref}: ${digest##*$'\n'}")
    fi
  done
  if [[ ${#bad[@]} == 0 && $n != 0 ]]; then
    check base-images PASS "${n} FROM refs resolve (INFO base lines)"
  else
    check base-images FAIL "${n} refs; $(printf '%s; ' ${bad[@]+"${bad[@]}"} | cut -c1-500)"
  fi
  step_end
  gate "a base image cannot be resolved"
}

record_bases() {  # after the build: the digest each FROM ref really was
  local ref digest
  for ref in $(base_refs); do
    digest=$(podman image inspect --format '{{.Digest}}' "$ref" 2>/dev/null) || digest=unknown
    echo "INFO base ${ref} ${digest} (used by this build)"
  done
}

# ---------------------------------------------------------------------------------------
# checks: the images, before they are pushed. zot's budget is about two full builds and a deleted
# failed round frees nothing until the next 24 h GC pass, so a broken image stops here. Every image
# is run even after a failure: one round shows all of them.

SMOKE_DIR=
SMOKE_FAILED=

podman_run() {  # podman_run <output file> <podman run arguments...>; $? is the container's
  local out=$1
  shift
  timeout -k 10 "$SMOKE_TIMEOUT" podman run --rm "$@" >"$out" 2>&1
}

smoke_result() {  # smoke_result <image> PASS|FAIL <detail...>
  if [[ $2 == FAIL ]]; then SMOKE_FAILED="${SMOKE_FAILED} $1"; fi
  check "image-smoke/$1" "$2" "${*:3}"
}

tail_of() {  # tail_of <file>: its last lines as one line, for a FAIL detail
  tail -n 3 "$1" 2>/dev/null | one_line
}

smoke_controller() {  # <image name> <ref>: /manager --help prints its flags and exits 0
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.help rc=0
  podman_run "$out" "$ref" --help || rc=$?
  if [[ $rc == 0 ]] && grep -q 'metrics-bind-address' "$out"; then
    smoke_result "$name" PASS "--help exit 0, lists -metrics-bind-address"
  else
    smoke_result "$name" FAIL "--help exit ${rc}: $(tail_of "$out")"
  fi
}

smoke_datamover_controller() {  # <image name> <ref>: also the qemu-img the base was chosen for
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.help qemu=$SMOKE_DIR/$1.qemu rc=0 rcq=0
  podman_run "$out" "$ref" --help || rc=$?
  podman_run "$qemu" --entrypoint qemu-img "$ref" --version || rcq=$?
  if [[ $rc == 0 && $rcq == 0 ]] && grep -q 'metrics-bind-address' "$out" && grep -q 'qemu-img version' "$qemu"; then
    smoke_result "$name" PASS "--help exit 0, $(head -n 1 "$qemu")"
  else
    smoke_result "$name" FAIL "--help exit ${rc}: $(tail_of "$out"); qemu-img --version exit ${rcq}: $(tail_of "$qemu")"
  fi
}

smoke_plugin() {  # <image name> <ref>: the plugin binary its init container copies
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.ls rc=0
  podman_run "$out" --entrypoint ls "$ref" /plugins || rc=$?
  if [[ $rc == 0 ]] && grep -qx 'kubevirt-datamover-plugin' "$out"; then
    smoke_result "$name" PASS "/plugins holds kubevirt-datamover-plugin"
  else
    smoke_result "$name" FAIL "ls /plugins exit ${rc}: $(tail_of "$out")"
  fi
}

# The download servers parse no flags, so --help would block. A run is good when both lines were
# logged and the server was still up when `timeout` ended it (124, or 137 if it took a KILL):
# log.Fatal after a failed bind would have logged both lines too. One longer try, because these nodes
# run at minimum frequency and a podman start can eat 10 s; the output goes to a file so nothing can
# hold a pipe open.
smoke_server() {  # <image name> <ref>
  local name=$1 ref=$2 ls_out=$SMOKE_DIR/$1.ls out=$SMOKE_DIR/$1.run ctr rc=0 limit
  local ok= tried=
  podman_run "$ls_out" --entrypoint ls "$ref" /archives || rc=$?
  if [[ $rc != 0 || ! -s $ls_out ]]; then
    smoke_result "$name" FAIL "ls /archives exit ${rc}, $(wc -l <"$ls_out" | tr -d ' ') entries: $(tail_of "$ls_out")"
    return 0
  fi
  ctr=oadp-smoke-${name}
  for limit in 10 30; do
    rc=0
    timeout -k 5 "$limit" podman run --rm --name "$ctr" "$ref" >"$out" 2>&1 || rc=$?
    podman rm -f "$ctr" >/dev/null 2>&1 || true
    tried="${tried} ${limit}s=exit${rc}"
    if [[ $rc == 124 || $rc == 137 ]] && grep -qE 'Found [1-9][0-9]* binaries' "$out" && grep -q 'Starting server' "$out"; then
      ok=$limit
      break
    fi
  done
  if [[ -n $ok ]]; then
    smoke_result "$name" PASS "/archives has $(wc -l <"$ls_out" | tr -d ' ') entries; $(grep -oE 'Found [0-9]+ binaries' "$out"), still serving at ${ok}s"
  else
    smoke_result "$name" FAIL "tries${tried}; want it still serving (exit 124) after 'Found N binaries' and 'Starting server': $(tail_of "$out")"
  fi
}

# vmfr-sshd: the ForceCommand wrapper denies an empty command with exit 1; sftp-server is there; and
# the chroot works, because the library copies in the Containerfile are masked with `|| true`.
smoke_sshd() {  # <image name> <ref>
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.sshd sftp=$SMOKE_DIR/$1.sftp rsync=$SMOKE_DIR/$1.rsync
  local rc=0 rcs=0 rcr=0
  local -a bad=()
  podman_run "$out" --entrypoint /oadp/bin/oadp-sshd "$ref" || rc=$?
  if [[ $rc != 1 ]] || ! grep -q 'Interactive shell access is disabled' "$out"; then
    bad+=("oadp-sshd exit ${rc}, want 1 and 'Interactive shell access is disabled': $(tail_of "$out")")
  fi
  podman_run "$sftp" --entrypoint /bin/bash "$ref" -c 'test -x /oadp/usr/libexec/openssh/sftp-server' || rcs=$?
  if [[ $rcs != 0 ]]; then
    bad+=("/oadp/usr/libexec/openssh/sftp-server missing (exit ${rcs}): $(tail_of "$sftp")")
  fi
  podman_run "$rsync" --entrypoint /bin/bash "$ref" -c "chroot /oadp /bin/bash -c 'rsync --version'" || rcr=$?
  if [[ $rcr != 0 ]] || ! grep -qE '^rsync +version' "$rsync"; then
    bad+=("rsync in the chroot exit ${rcr}: $(tail_of "$rsync")")
  fi
  if [[ ${#bad[@]} == 0 ]]; then
    smoke_result "$name" PASS "oadp-sshd denies a shell (exit 1), sftp-server present, chroot runs $(head -n 1 "$rsync" | one_line)"
  else
    smoke_result "$name" FAIL "$(printf '%s; ' "${bad[@]}")"
  fi
}

# vmfr-filebrowser: the way the controller starts it, /bin/bash -c and the hard-coded path. Both are a
# contract: a konflux-style image would pass a bare `version` and fail at `config init` on KubeVirt.
smoke_filebrowser() {  # <image name> <ref>
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.version rc=0
  podman_run "$out" --entrypoint /bin/bash "$ref" -c '/usr/local/bin/filebrowser version' || rc=$?
  if [[ $rc == 0 ]] && grep -q "^File Browser v${RELEASE}\.0-" "$out"; then
    smoke_result "$name" PASS "$(head -n 1 "$out")"
  else
    smoke_result "$name" FAIL "filebrowser version exit ${rc}, want 'File Browser v${RELEASE}.0-...': $(tail_of "$out")"
  fi
}

smoke_access() {  # <image name> <ref>: every program its two scripts call, and the scripts
  local name=$1 ref=$2 out=$SMOKE_DIR/$1.tools rc=0
  # shellcheck disable=SC2016  # expanded by the bash in the container
  podman_run "$out" --entrypoint /bin/bash "$ref" -c '
      missing=
      for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
      for s in /usr/local/bin/detect-and-mount.sh /usr/local/bin/entrypoint.sh; do
        [ -x "$s" ] || missing="$missing $s"
      done
      if [ -n "$missing" ]; then echo "MISSING:$missing"; exit 1; fi
      echo "ALL PRESENT"
    ' _ $VMFR_ACCESS_TOOLS || rc=$?
  if [[ $rc == 0 ]] && grep -qx 'ALL PRESENT' "$out"; then
    smoke_result "$name" PASS "command -v finds ${VMFR_ACCESS_TOOLS}; both scripts executable"
  else
    smoke_result "$name" FAIL "exit ${rc}: $(tail_of "$out")"
  fi
}

# velero-version: the binary reports what the Containerfile's -X stamped, against pins.md.
check_velero_version() {
  local ref out got rc=0
  ref=$(var IMG_VELERO)
  out=$SMOKE_DIR/velero.version
  podman_run "$out" "$ref" version --client-only || rc=$?
  got=$(awk '$1 == "Version:" {print $2; exit}' "$out")
  if [[ $rc == 0 && $got == "$VELERO_VERSION" ]]; then
    check velero-version PASS "${got} from ${ref}"
  else
    check velero-version FAIL "velero version --client-only exit ${rc}, version '${got}', want ${VELERO_VERSION}: $(tail_of "$out")"
  fi
}

# vm-file-restore-env: the patch reached the binary. The runtime is distroless, so no shell: the
# binary is copied out of a created container and searched. Go keeps the three string constants,
# which is what the unpatched binary does not have.
check_vm_file_restore_env() {
  local ref cid bin=$SMOKE_DIR/vm-file-restore.manager err=$SMOKE_DIR/vm-file-restore.err name
  local -a missing=()
  ref=$(var IMG_VM_FILE_RESTORE)
  rm -f "$bin"
  if ! cid=$(podman create "$ref" 2>"$err"); then
    check vm-file-restore-env FAIL "podman create ${ref}: $(tail_of "$err")"
    return 0
  fi
  if ! podman cp "${cid}:/manager" "$bin" 2>"$err"; then
    check vm-file-restore-env FAIL "podman cp ${cid}:/manager: $(tail_of "$err")"
    podman rm -f "$cid" >/dev/null 2>&1 || true
    return 0
  fi
  podman rm -f "$cid" >/dev/null 2>&1 || true
  if [[ ! -s $bin ]]; then
    check vm-file-restore-env FAIL "/manager copied out of ${ref} is empty"
    return 0
  fi
  for name in $VMFR_ENV_NAMES; do
    if ! LC_ALL=C grep -aqF "$name" "$bin"; then missing+=("$name"); fi
  done
  if [[ ${#missing[@]} == 0 ]]; then
    check vm-file-restore-env PASS "/manager contains ${VMFR_ENV_NAMES}"
  else
    check vm-file-restore-env FAIL "/manager lacks ${missing[*]}: patches/vm-file-restore.patch did not reach the binary"
  fi
}

image_checks() {
  local name
  step_start image-smoke
  SMOKE_DIR=$RUN/smoke
  SMOKE_FAILED=
  mkdir -p "$SMOKE_DIR"
  smoke_controller vm-file-restore "$(var IMG_VM_FILE_RESTORE)"
  smoke_datamover_controller kubevirt-datamover-controller "$(var IMG_KUBEVIRT_DATAMOVER_CONTROLLER)"
  smoke_plugin kubevirt-datamover-plugin "$(var IMG_KUBEVIRT_DATAMOVER_PLUGIN)"
  smoke_server cli-binaries "$(var IMG_CLI_BINARIES)"
  smoke_server vmdp-binaries "$(var IMG_VMDP_BINARIES)"
  smoke_sshd vmfr-sshd "$(var IMG_VMFR_SSHD)"
  smoke_filebrowser vmfr-filebrowser "$(var IMG_VMFR_FILEBROWSER)"
  smoke_access vmfr-access "$(var IMG_VMFR_ACCESS)"
  if [[ -z $SMOKE_FAILED ]]; then
    check image-smoke PASS "8 images: each ran its own binary"
  else
    check image-smoke FAIL "failed:${SMOKE_FAILED}"
  fi
  check_velero_version
  check_vm_file_restore_env
  step_end
}

# ---------------------------------------------------------------------------------------
# checks: the bundle

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
  echo "INFO bundle files: $(cd "$dir/fs" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | paste -sd ' ' -)"
}

# What the operator pin's own bundle/manifests holds: the CRDs, the CSV and 26 RBAC and Service
# manifests. From git objects, because `make bundle` rewrites the working tree. <dir>/pin-manifests.
pin_manifests() {  # pin_manifests <dir>
  local dir=$1 pin
  pin=$(pin_of "$OPERATOR_SUB")
  rm -rf "$dir/pin"
  mkdir -p "$dir/pin"
  git -C "$PIPE/$OPERATOR_SUB" archive "$pin" bundle/manifests | tar -xf - -C "$dir/pin"
  mv "$dir/pin/bundle/manifests" "$dir/pin-manifests"
}

object_set() {  # the file's or objects' identity: Kind/name, one CSV whatever its name
  sed -E 's|^ClusterServiceVersion/.*|ClusterServiceVersion/*|' | LC_ALL=C sort
}

# bundle-objects: exactly what the pin's bundle/manifests lists (Global Constraints: the CRDs, the CSV
# and "whatever else make bundle emits that Red Hat's bundle has"; the 26 others are that), in the
# image's files and in what opm renders. Anything outside FAILs, and so does anything missing: a
# dropped CRD or Role is a broken install.
check_bundle_objects() {  # <dir>
  local dir=$1
  local f extra missing n_oadp n_velero n_csv roots
  local got_files=$dir/files.got want_files=$dir/files.want got_objs=$dir/objects.got want_objs=$dir/objects.want
  local -a bad=()
  if [[ ! -d $dir/fs/manifests ]]; then
    check bundle-objects FAIL "bundle image not extracted"
    return 0
  fi
  if [[ ! -d $dir/pin-manifests ]]; then
    check bundle-objects FAIL "the operator pin's bundle/manifests could not be read"
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

  n_oadp=$(jq '[.[] | select(.kind == "CustomResourceDefinition" and (.metadata.name | endswith(".oadp.openshift.io")))] | length' "$dir/objects.json")
  n_velero=$(jq '[.[] | select(.kind == "CustomResourceDefinition" and (.metadata.name | endswith(".velero.io")))] | length' "$dir/objects.json")
  n_csv=$(jq '[.[] | select(.kind == "ClusterServiceVersion")] | length' "$dir/objects.json")
  if [[ $n_oadp != "$CRDS_OADP" || $n_velero != "$CRDS_VELERO" || $n_csv != 1 ]]; then
    bad+=("${n_oadp} oadp.openshift.io CRDs, ${n_velero} velero.io CRDs, ${n_csv} CSVs; want ${CRDS_OADP}, ${CRDS_VELERO}, 1")
  fi

  roots=$(cd "$dir/fs" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort | paste -sd ' ' -)
  if [[ $roots != "manifests metadata tests" && $roots != "manifests metadata" ]]; then
    bad+=("image top level '${roots}', want manifests metadata tests")
  fi

  if [[ ${#bad[@]} == 0 ]]; then
    check bundle-objects PASS "$(wc -l <"$got_files" | tr -d ' ') files, the pin's list exactly: ${n_oadp} oadp.openshift.io and ${n_velero} velero.io CRDs, the CSV, $(($(wc -l <"$got_files") - n_oadp - n_velero - 1)) RBAC and Service manifests"
  else
    check bundle-objects FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-700)"
  fi
}

# no-redhat-registry scans the bundle, not the binaries: must-gather's usage text names
# registry.redhat.io in a help string nothing pulls.
check_no_redhat_registry() {  # <dir>: the CSV, every bundle object, the bundle files and labels
  local dir=$1 n
  local -a hits=()
  n=$( { jq -c . "$dir/csv.json" | grep -oiE "$REDHAT_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
  if [[ -n $n ]]; then hits+=("CSV: ${n}"); fi
  n=$( { jq -c . "$dir/objects.json" | grep -oiE "$REDHAT_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
  if [[ -n $n ]]; then hits+=("bundle objects: ${n}"); fi
  if [[ -d $dir/fs ]]; then
    n=$( { grep -rliE "$REDHAT_REGISTRY_RE" "$dir/fs" || true; } | sed "s|^${dir}/fs/||" | paste -sd ' ' -)
    if [[ -n $n ]]; then hits+=("bundle files: ${n}"); fi
    n=$( { jq -c '.config.Labels // {}' "$dir/config.json" | grep -oiE "$REDHAT_REGISTRY_RE" || true; } | sort -u | paste -sd ' ' -)
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

check_csv_name() {  # <dir>: oadp-operator.v1.6.0-<DATE>; the release is oadp/build.sh's, not OKD's
  local dir=$1 want_version="${RELEASE}.0-${DATE}" want_name pkg pv n
  want_name="${PKG}.v${want_version}"
  pkg=$(jq -r '.package // "none"' "$dir/bundle.json")
  pv=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "$dir/bundle.json")
  n=$(jq -r '[.metadata.name, .spec.version] | join(" ")' "$dir/csv.json")
  if [[ $pkg == "$PKG" && $n == "${want_name} ${want_version}" && $pv == "$want_version" \
    && $(var OCP_DATE) == "$want_version" ]]; then
    check csv-name PASS "${n}"
  else
    check csv-name FAIL "package ${pkg}, CSV '${n}', olm.package version ${pv}, OCP_DATE $(var OCP_DATE); want ${PKG} '${want_name} ${want_version}'"
  fi
  # The CSV's own edges do not match our graph; catalog-edit.sh sets the real ones in the channel entry.
  echo "INFO csv replaces=$(jq -r '.spec.replaces // "none"' "$dir/csv.json") olm.skipRange=$(jq -r '.metadata.annotations["olm.skipRange"] // "none"' "$dir/csv.json") minKubeVersion=$(jq -r '.spec.minKubeVersion // "none"' "$dir/csv.json")"
}

check_install_modes() {  # <dir>: OwnNamespace only, which is what the homelab OperatorGroup offers
  local dir=$1 modes
  modes=$(jq -r '[.spec.installModes[]? | "\(.type)=\(.supported)"] | sort | join(" ")' "$dir/csv.json")
  if [[ $modes == "AllNamespaces=false MultiNamespace=false OwnNamespace=true SingleNamespace=false" ]]; then
    check install-modes PASS "${modes}"
  else
    check install-modes FAIL "${modes:-none}; want OwnNamespace only"
  fi
}

# images-by-digest, as a set: relatedImages (CSV, and what opm renders minus the bundle itself) are
# exactly the 18 RELATED_IMAGE_* plus the manager, each ${REGISTRY}/<name>@<digest this run recorded>.
# operator-sdk lists some twice under two names, so sets, not lists. Then by name, because a swap
# would pass as a set: each RELATED_IMAGE_* env, the manager container, the two image annotations.
check_images_by_digest() {  # <dir>; needs <dir>/built.tsv: <IMG var> <repo> <digest>
  local dir=$1
  local want=$dir/images.want
  local list extra missing bundle_ref name var_name wanted got n operator_ref must_gather_ref
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
        | select(.name | startswith("RELATED_IMAGE_"))] | length' "$dir/csv.json")
  if [[ $n != "$(wc -l <<<"$RELATED_ENV" | tr -d ' ')" ]]; then
    bad+=("${n} RELATED_IMAGE_* env entries, want $(wc -l <<<"$RELATED_ENV" | tr -d ' ')")
  fi

  operator_ref=$(awk '$1 == "IMG_OPERATOR" {print $2 "@" $3}' "$dir/built.tsv")
  must_gather_ref=$(awk '$1 == "IMG_MUST_GATHER" {print $2 "@" $3}' "$dir/built.tsv")
  got=$(jq -r '[.spec.install.spec.deployments[]?.spec.template.spec | ((.containers // []) + (.initContainers // []))[] | .image] | join(" ")' "$dir/csv.json")
  if [[ $got != "$operator_ref" ]]; then bad+=("deployment images '${got}', want only ${operator_ref}"); fi
  got=$(jq -r '.metadata.annotations.containerImage // ""' "$dir/csv.json")
  if [[ $got != "$operator_ref" ]]; then bad+=("containerImage annotation '${got}', want ${operator_ref}"); fi
  got=$(jq -r '.metadata.annotations["operators.openshift.io/must-gather-image"] // ""' "$dir/csv.json")
  if [[ $got != "$must_gather_ref" ]]; then bad+=("must-gather-image annotation '${got}', want ${must_gather_ref}"); fi

  if [[ ${#bad[@]} == 0 ]]; then
    check images-by-digest PASS "$(wc -l <"$want" | tr -d ' ') refs (18 RELATED_IMAGE_* + manager), all by digest under $(var REGISTRY)/ and recorded by this run; env, manager and annotations match by name"
  else
    check images-by-digest FAIL "$(printf '%s; ' "${bad[@]}" | cut -c1-900)"
  fi
}

# no-konveyor: the CSV's only lines naming quay.io/konveyor at the pin are the ones build_bundle()
# rewrites, so nothing may be left: relatedImages, the operator's env, and anywhere else in the bundle.
check_no_konveyor() {  # <dir>
  local dir=$1 rel env_hits rest files
  local -a hits=()
  rel=$( { jq -r '.relatedImages[]?.image' "$dir/bundle.json"; jq -r '.spec.relatedImages[]?.image' "$dir/csv.json"; } \
    | { grep -F "$KONVEYOR" || true; } | LC_ALL=C sort -u | paste -sd ' ' -)
  if [[ -n $rel ]]; then hits+=("relatedImages: ${rel}"); fi
  env_hits=$(jq -r '.spec.install.spec.deployments[]?.spec.template.spec | ((.containers // []) + (.initContainers // []))[]
      | (.env[]? | select(.value != null) | .name + "=" + .value), ("image=" + .image)' "$dir/csv.json" \
    | { grep -F "$KONVEYOR" || true; } | paste -sd ' ' -)
  if [[ -n $env_hits ]]; then hits+=("operator env: ${env_hits}"); fi
  rest=$( { jq -c . "$dir/objects.json" | grep -oF "$KONVEYOR" || true; } | wc -l | tr -d ' ')
  if [[ $rest != 0 ]]; then hits+=("${rest} hits in the bundle objects"); fi
  if [[ -d $dir/fs ]]; then
    files=$( { grep -rlF "$KONVEYOR" "$dir/fs" || true; } | sed "s|^${dir}/fs/||" | paste -sd ' ' -)
    if [[ -n $files ]]; then hits+=("bundle files: ${files}"); fi
  fi
  if [[ ${#hits[@]} == 0 ]]; then
    check no-konveyor PASS "no ${KONVEYOR} in relatedImages, the operator's env or elsewhere in the bundle"
  else
    check no-konveyor FAIL "$(printf '%s; ' "${hits[@]}" | cut -c1-700)"
  fi
}

# okd-strings: the OKDify patch reached the CSV. No valid-subscription anywhere, keys or values.
check_okd_strings() {  # <dir>
  local dir=$1 got n
  local -a bad=()
  got=$(jq -r '.spec.provider.name // "missing"' "$dir/csv.json")
  if [[ $got != "OKD Community" ]]; then bad+=("provider.name '${got}'"); fi
  got=$(jq -r '.metadata.annotations.support // "missing"' "$dir/csv.json")
  if [[ $got != "OKD Community" ]]; then bad+=("support annotation '${got}'"); fi
  got=$(jq -r '[.spec.maintainers[]?.name] | join(",")' "$dir/csv.json")
  if [[ $got != "OKD Community" ]]; then bad+=("maintainers '${got}'"); fi
  got=$(jq -r '.metadata.annotations.description // ""' "$dir/csv.json")
  if [[ $got != *"OKD API for Data Protection"* ]]; then bad+=("description annotation '${got:0:60}...'"); fi
  n=$( { jq -c . "$dir/csv.json" | grep -oF 'valid-subscription' || true; } | wc -l | tr -d ' ')
  if [[ $n != 0 ]]; then bad+=("${n}x valid-subscription"); fi
  if [[ ${#bad[@]} == 0 ]]; then
    check okd-strings PASS "provider, support and maintainers OKD Community, description OKD, no valid-subscription"
  else
    check okd-strings FAIL "$(printf '%s; ' "${bad[@]}")"
  fi
}

# operator-sdk bundle validate on the extracted bundle directory (no image builder needed); the
# default validators. make bundle has run its own v1.35.0 on the working tree already; this one is the
# pinned tool on what the image holds.
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
    check_install_modes "$dir"
    check_images_by_digest "$dir"
    check_no_konveyor "$dir"
    check_okd_strings "$dir"
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
    rm -rf "$dir/fs"
  fi
  pin_manifests "$dir" || echo "ERROR could not read bundle/manifests of the operator pin"
  verify_dir "$dir"
  step_end
  gate "verify"
}

# No RESULT PASS unless every check of the mode really ran: a skipped branch of the flow must not
# read as a green run. Names as printed, one per word; the contract file is the record.
REQUIRED_COMMON='pipeline-gitlinks submodule-pins operator-commit image-smoke velero-version vm-file-restore-env bundle-objects no-redhat-registry csv-name install-modes images-by-digest no-konveyor okd-strings operator-sdk-validate'
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

# ---------------------------------------------------------------------------------------
# modes

# Start of MODE=full: prune unless PRUNE=false (nmstate README, "prune"). A retry after a failed round
# passes PRUNE=false so a package failure late in the build does not repeat hours of compile. The PVC still holds layers of earlier
# runs and nothing on it needs keeping. After the prune the base layers are pulled again, so
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
  check_base_images

  pipeline_step init
  pins_gate

  pipeline_step build_containers
  record_bases
  image_checks
  gate "the images are not pushed"

  pipeline_step push_containers
  report_pushed "${IMAGE_VARS[@]}"
  pipeline_step build_bundle
  report_pushed "${BUNDLE_VARS[@]}"
  verify
  pipeline_step deinit
  # shellcheck disable=SC2086  # a word list
  require_checks $REQUIRED_COMMON base-images
}

# MODE=check: build_bundle() only, against the images of the full run REUSE_DATE. They are copied to
# this run's own tag in the same repository: oadp/build.sh derives every IMG_* from DATE, and DATE is
# new per run because a tag is never pushed twice. zot holds no new blobs for that, and relatedImages
# stay under ${BASE_REGISTRY}/oadp/ by the same digests. The logging Job copied to a check-<branch>/
# registry instead, because it kept the full run's DATE; a new DATE makes that repository unnecessary.
copy_images() {
  local name dst src tag bad=
  tag="${RELEASE}.0-${REUSE_DATE}"
  step_start copy
  for name in "${IMAGE_VARS[@]}"; do
    dst=$(var "$name")
    src="$(ref_repo "$dst"):${tag}"
    run_bg skopeo copy --all --preserve-digests --quiet --retry-times 3 "docker://${src}" "docker://${dst}"
    if [[ $(ref_digest "$src") != "$(ref_digest "$dst")" ]]; then
      bad="${bad} ${name}"
    fi
  done
  if [[ -z $bad ]]; then
    check reuse-digests PASS "${#IMAGE_VARS[@]} images of ${REUSE_DATE} copied to ${RELEASE}.0-${DATE} with the same digests"
  else
    check reuse-digests FAIL "digest changed by the copy:${bad}"
  fi
  step_end
  gate "the copy changed an image"
}

mode_check() {
  step_start clone
  prepare_pipeline
  step_end

  tag_checks
  pipeline_step init
  pins_gate

  copy_images
  report_pushed "${IMAGE_VARS[@]}"
  image_checks
  gate "the reused images fail their checks"

  pipeline_step build_bundle
  report_pushed "${BUNDLE_VARS[@]}"
  verify
  pipeline_step deinit
  # shellcheck disable=SC2086  # a word list
  require_checks $REQUIRED_COMMON reuse-digests
}

mode_catalog() {
  local n rc=0 catalog_ref
  catalog_ref="${BASE_REGISTRY}/oadp-catalog:${DATE}"
  guard_registry "${catalog_ref%:*}"
  rm -rf "$RUN"
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
    check) mode_check ;;
    catalog) mode_catalog ;;
  esac
  finish PASS "${MODE} ${DATE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
