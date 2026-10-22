#!/bin/bash
# MODE=catalog of the okderators-gitops-build Job (README.md, "MODE=catalog"). build.sh runs it
# as /scripts/catalog-edit.sh in an empty RUN_DIR and copies its CHECK lines into the contract.
#
# First, once: BUNDLES must be one bundle of package gitops-operator whose version is 1.22.0-<DATE>
# and whose CSV name is gitops-operator.v<version>, or the run stops before any edit
#                                                              CHECK bundle-version
# Then for each okderators-catalog-index branch in CATALOG_BRANCHES:
#   1. clone it; the package must have exactly one head in channel alpha, and it must be
#      OLD_HEAD (gitops-operator.v1.19.0-2026-02-07-151505, what the homelab runs)
#   2. add the bundle with the branch's own hack/add-bundle.sh   CHECK bundles-<branch>
#   3. append one entry to the channel: name <bundle CSV>, replaces OLD_HEAD,
#      skipRange '>=1.19.0-0 <<bundle version>'                  CHECK edit-<branch>
#   4. opm validate catalog                                      CHECK opm-validate-<branch>
#   5. graph walk (catalog-walk.py): every alpha entry reaches the single head, and the first hops
#      are 1.13 -> 1.16, 1.16 -> 1.19.0 and 1.19.0 -> the head   CHECK walk-<branch>
#   6. negative control: a copy where the bundle file is in the catalog but the channel has no
#      entry for it must fail opm validate                       CHECK negative-control-<branch>
#   7. second control: a copy whose new entry has skipRange '>=1.0.0 <version' still passes opm
#      validate, and the walker must FAIL it (1.13 would jump straight to the head)
#                                                      CHECK negative-control-skiprange-<branch>
# Then, only if every check passed: the test catalog image from the edited IMAGE_BRANCH tree,
# package gitops-operator only, built from that branch's own catalog.Containerfile with the opm
# base image pinned, pushed to CATALOG_IMAGE, rendered back and walked   CHECK catalog-image
#
# Env:
#   CATALOG_BRANCHES  okderators-catalog-index branches, e.g. "release-4.21 release-4.22"
#   BUNDLES           the one bundle image ref (gitops-operator)
#   RUN_DIR           empty working directory (build.sh: /work/run)
#   CATALOG_IMAGE     push target, set and guarded by build.sh: ${BASE_REGISTRY}/gitops-catalog:${DATE}
#   CATALOG_REPO      optional, default the upstream GitHub repository
# Test mode, for a laptop: CATALOG_EDIT_TEST_BUNDLES=<directory of olm.bundle YAML files>
#   replaces the add-bundle step (no image pulls), BUNDLES is ignored and CATALOG_IMAGE must be
#   empty; the image context is still assembled and validated, but nothing is built or pushed.
#
# Output: CHECK <name> PASS|FAIL <detail>, INFO and ERROR lines. Exit 0 when every check passed,
# 1 otherwise (a hard error exits 1 too, possibly before any CHECK line). Written for bash 3.2
# as well (no associative arrays, namerefs or mapfile), so the same file runs on the Mac.
set -euo pipefail

CATALOG_REPO=${CATALOG_REPO:-https://github.com/okd-project/okderators-catalog-index.git}
CATALOG_BRANCHES=${CATALOG_BRANCHES:-}
BUNDLES=${BUNDLES:-}
RUN_DIR=${RUN_DIR:-}
CATALOG_IMAGE=${CATALOG_IMAGE:-}
TEST_BUNDLES=${CATALOG_EDIT_TEST_BUNDLES:-}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=gitops-operator
CHANNEL=alpha
BUNDLE_MINOR=1.22
# The entries of the 4.21 / 4.22 catalogs today (read 2026-10-22), by their exact names. The
# walker fails when one is missing, so a catalog that moved on stops the run instead of passing.
OLD_HEAD=gitops-operator.v1.19.0-2026-02-07-151505
CSV_V113=gitops-operator.v1.13.0-2024-08-09-135916
CSV_V116=gitops-operator.v1.16.0-2025-06-04-121801
# skipRange of the new entry: from the installed 1.19.0 (a prerelease, hence -0) up to the new
# version, set in bundle_versions. It must not reach 1.13 or 1.16, or those jump to the head.
SKIP_FROM=">=1.19.0-0"
# CSVs a cluster may run that a channel may not list; the walker starts from them too. The
# homelab runs OLD_HEAD, which is a channel entry.
INSTALLED=("$OLD_HEAD")
IMAGE_BRANCH=release-4.21
# catalog.Containerfile builds FROM the mutable :latest; the test image pins it. v1.74.0 is the
# opm build.sh installs, and :latest pointed at this same index on 2026-10-20. Digest only:
# containers/image refuses a reference with both a tag and a digest.
UPSTREAM_OPM_FROM='FROM quay.io/operator-framework/opm:latest'
OPM_IMAGE=quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f
# Independent of build.sh's guard: never push anywhere but zot okd-test/.
PUSH_RE='^zot\.apps\.okd\.sudops\.pl/okd-test/[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*$'

FAILS=0
WANT_CSV=          # the bundle name bundle_versions read
WANT_VERSION=      # its version, 1.22.0-<DATE>
SKIP_RANGE=
NEW_CSV=           # per branch: the file add_bundles wrote
IMAGE_HEAD=        # the new CSV name on IMAGE_BRANCH

check() {  # check <name> PASS|FAIL <detail...>
  local name=$1 result=$2
  shift 2
  echo "CHECK ${name} ${result} $*"
  if [[ $result != PASS ]]; then FAILS=$((FAILS + 1)); fi
}

die() {
  echo "ERROR $*"
  exit 1
}

walker() {
  python3 -I "${HERE}/catalog-walk.py" "$@"
}

one_line() {  # squeeze multi-line tool output into one CHECK detail
  tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//' | cut -c1-400
}

bundle_field() {  # bundle_field <file> <yq path below the olm.bundle document>
  yq e "select(.schema == \"olm.bundle\") | ${2}" "$1"
}

# containers/image (opm render, podman) refuses "repo:tag@sha256:..."; keep the digest.
digest_ref() {
  if [[ $1 =~ ^([^@]+):([^/@:]+)@(sha256:[0-9a-f]{64})$ ]]; then
    echo "${BASH_REMATCH[1]}@${BASH_REMATCH[3]}"
  else
    echo "$1"
  fi
}

# ---------------------------------------------------------------------------------------
# inputs

validate_inputs() {
  local b n
  [[ $RUN_DIR == /* && -d $RUN_DIR ]] || die "RUN_DIR '${RUN_DIR}' is not an absolute directory"
  [[ -n $CATALOG_BRANCHES ]] || die "CATALOG_BRANCHES is empty"
  for b in $CATALOG_BRANCHES; do
    [[ $b =~ ^release-4\.[0-9]+$ ]] || die "catalog branch '${b}' is not release-4.N"
  done
  if [[ -n $TEST_BUNDLES ]]; then
    [[ -d $TEST_BUNDLES ]] || die "CATALOG_EDIT_TEST_BUNDLES '${TEST_BUNDLES}' is not a directory"
    [[ -z $CATALOG_IMAGE ]] || die "test mode builds no image: CATALOG_IMAGE must be empty"
    echo "INFO test mode: bundles from ${TEST_BUNDLES}, no image build"
  else
    n=$(echo $BUNDLES | wc -w | tr -d ' ')
    [[ $n == 1 ]] || die "BUNDLES has ${n} refs, want 1 (the gitops-operator bundle)"
    [[ $CATALOG_IMAGE =~ $PUSH_RE ]] || die "CATALOG_IMAGE '${CATALOG_IMAGE}' is not a zot okd-test/ tag"
  fi
  echo "INFO tool python3 $(python3 --version 2>&1)"
}

# Once, before any clone or edit: what the bundle is. A wrong paste (a 1.19 bundle, a bundle of
# another package) stops here instead of producing and pushing a catalog.
bundle_versions() {
  local dir=${RUN_DIR}/bundles ref f n=0 name pkg version
  mkdir -p "$dir"
  if [[ -n $TEST_BUNDLES ]]; then
    for f in "$TEST_BUNDLES"/*.yaml; do
      [[ -f $f ]] || continue
      n=$((n + 1))
      cp "$f" "${dir}/${n}.yaml"
    done
  else
    for ref in $BUNDLES; do
      n=$((n + 1))
      if ! opm render "$(digest_ref "$ref")" -o yaml >"${dir}/${n}.yaml"; then
        check bundle-version FAIL "opm render $(digest_ref "$ref") failed"
        return 1
      fi
    done
  fi
  if [[ $n != 1 ]]; then
    check bundle-version FAIL "${n} bundles, want exactly one"
    return 1
  fi
  f=${dir}/1.yaml
  name=$(bundle_field "$f" .name)
  pkg=$(bundle_field "$f" .package)
  version=$(bundle_field "$f" '.properties[] | select(.type == "olm.package") | .value.version')
  if [[ $pkg != "$PKG" ]]; then
    check bundle-version FAIL "${name}: package ${pkg}, want ${PKG}"
    return 1
  fi
  if [[ ! $version =~ ^${BUNDLE_MINOR//./\\.}\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    check bundle-version FAIL "${name} has version ${version}, want ${BUNDLE_MINOR}.0-<DATE>"
    return 1
  fi
  if [[ $name != "${PKG}.v${version}" ]]; then
    check bundle-version FAIL "bundle name ${name}, want ${PKG}.v${version}"
    return 1
  fi
  WANT_CSV=$name
  WANT_VERSION=$version
  SKIP_RANGE="${SKIP_FROM} <${version}"
  check bundle-version PASS "${name} ${version}"
}

# ---------------------------------------------------------------------------------------
# per branch

current_head() {  # current_head <branch> <tree>: the head must be OLD_HEAD, or FAIL and return 1
  local b=$1 tree=$2 render heads n max
  render=$RUN_DIR/render-${b}-before.json
  opm render "${tree}/catalog/${PKG}" -o json >"$render"
  if ! heads=$(walker heads "$render" "$PKG" "$CHANNEL"); then
    check "edit-${b}" FAIL "$(echo "$heads" | one_line)"
    return 1
  fi
  n=$(echo "$heads" | grep -c . || true)
  if [[ $n != 1 ]]; then
    check "edit-${b}" FAIL "${n} heads in ${CHANNEL} before the edit: $(echo "$heads" | one_line)"
    return 1
  fi
  if [[ $heads != "$OLD_HEAD" ]]; then
    check "edit-${b}" FAIL "head before the edit is ${heads}, want ${OLD_HEAD}"
    return 1
  fi
  max=$(jq -r --arg n "$heads" 'select(.schema == "olm.bundle" and .name == $n)
         | [.properties[]? | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | first // "none"' "$render")
  echo "INFO head before ${b} ${heads} olm.maxOpenShiftVersion=${max}"
}

# hack/add-bundle.sh writes `opm render <bundle> -o yaml` to catalog/<package>/<CSV name>.yaml.
# On release-4.2x it first runs `podman create` on the bundle to read the CSV name, which fails
# for a bundle built FROM scratch with no CMD (every bundle this pipeline builds;
# okderators-catalog-index PR #59 drops the podman step). If it fails, write the same file the
# same way, reading the name from the render as PR #59 does.
add_bundle_render() {  # add_bundle_render <tree> <ref>
  local tree=$1 ref=$2 rendered name pkg
  rendered=$(opm render "$ref" -o yaml)
  name=$(echo "$rendered" | yq e 'select(.schema == "olm.bundle") | .name' -)
  pkg=$(echo "$rendered" | yq e 'select(.schema == "olm.bundle") | .package' -)
  if [[ -z $name || $name == null || -z $pkg || $pkg == null ]]; then
    die "opm render ${ref}: no olm.bundle name/package"
  fi
  mkdir -p "${tree}/catalog/${pkg}"
  echo "$rendered" >"${tree}/catalog/${pkg}/${name}.yaml"
}

add_bundles() {  # add_bundles <tree>; records how the bundle was added in add-bundles.how
  local tree=$1 ref f name pkg how=none
  if [[ -n $TEST_BUNDLES ]]; then
    for f in "$TEST_BUNDLES"/*.yaml; do
      [[ -f $f ]] || continue
      name=$(bundle_field "$f" .name)
      pkg=$(bundle_field "$f" .package)
      mkdir -p "${tree}/catalog/${pkg}"
      cp "$f" "${tree}/catalog/${pkg}/${name}.yaml"
      how=test-file
    done
  else
    for ref in $BUNDLES; do
      ref=$(digest_ref "$ref")
      echo "INFO add-bundle ${ref}"
      if (cd "$tree" && bash ./hack/add-bundle.sh "$ref"); then
        how=hack/add-bundle.sh
      else
        echo "INFO hack/add-bundle.sh failed for ${ref}; rendering with opm directly"
        add_bundle_render "$tree" "$ref"
        how=opm-render
      fi
    done
  fi
  echo "$how" >"${RUN_DIR}/add-bundles.how"
}

new_bundles() {  # new_bundles <branch> <tree>: set NEW_CSV from the file add_bundles wrote
  local b=$1 tree=$2 line file name n=0
  NEW_CSV=
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line != '?? '* ]]; then
      check "bundles-${b}" FAIL "adding the bundle changed a tracked file (already in the catalog?): ${line}"
      return 1
    fi
    file=${line#'?? '}
    name=$(bundle_field "${tree}/${file}" .name)
    if [[ $file != "catalog/${PKG}/${name}.yaml" ]]; then
      check "bundles-${b}" FAIL "unexpected new file ${file} (bundle ${name})"
      return 1
    fi
    if [[ $name != "$WANT_CSV" ]]; then
      check "bundles-${b}" FAIL "added ${name}, but the bundle checked up front is ${WANT_CSV}"
      return 1
    fi
    NEW_CSV=$name
    n=$((n + 1))
  done <<<"$(git -C "$tree" status --porcelain --untracked-files=all)"
  if [[ $n != 1 ]]; then
    check "bundles-${b}" FAIL "${n} new bundle files, want one; already in the catalog?"
    return 1
  fi
  check "bundles-${b}" PASS "${NEW_CSV} ($(cat "${RUN_DIR}/add-bundles.how"))"
}

edit_package() {  # edit_package <branch> <tree>: append the new entry, or FAIL and return 1
  local b=$1 tree=$2 file orig want
  file=${tree}/catalog/${PKG}/${PKG}.yaml
  if NEW=$NEW_CSV CH=$CHANNEL yq e -e \
      'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW))' \
      "$file" >/dev/null 2>&1; then
    check "edit-${b}" FAIL "${NEW_CSV} is already in channel ${CHANNEL}: refusing to edit twice"
    return 1
  fi
  orig=${RUN_DIR}/${b}.yaml.orig
  want=${RUN_DIR}/${b}.yaml.want
  cp "$file" "$orig"
  NEW=$NEW_CSV OLD=$OLD_HEAD SR=$SKIP_RANGE CH=$CHANNEL yq -i \
    '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) += [{"name": strenv(NEW), "replaces": strenv(OLD), "skipRange": strenv(SR)}]' \
    "$file"
  # The edit must be exactly the appended entry (plus a final newline where the file had
  # none): yq re-emits the whole file, and nothing else in it may change.
  {
    cat "$orig"
    if [[ -n $(tail -c 1 "$orig") ]]; then echo; fi
    printf "  - name: %s\n    replaces: %s\n    skipRange: '%s'\n" "$NEW_CSV" "$OLD_HEAD" "$SKIP_RANGE"
  } >"$want"
  if ! cmp -s "$want" "$file"; then
    check "edit-${b}" FAIL "yq changed more than the appended entry: $(diff "$want" "$file" | head -n 6 | one_line)"
    return 1
  fi
  check "edit-${b}" PASS "${NEW_CSV} replaces ${OLD_HEAD}, skipRange '${SKIP_RANGE}' (+3 lines)"
}

validate_tree() {  # validate_tree <check name> <catalog dir>
  local out
  if out=$(opm validate "$2" 2>&1); then
    check "$1" PASS "opm validate ${2##*/}"
  else
    echo "$out" | tail -n 20
    check "$1" FAIL "$(echo "$out" | tail -n 3 | one_line)"
  fi
}

# catalog-walk.py walk, with the INSTALLED CSVs and the three first-hop assertions
walk_out() {  # walk_out <render json> <head>
  local csv args=()
  for csv in "${INSTALLED[@]}"; do
    args+=(--installed "$csv")
  done
  walker walk "$1" "$PKG" "$CHANNEL" "$2" "${args[@]}" \
    --hop "$CSV_V113" "$CSV_V116" --hop "$CSV_V116" "$OLD_HEAD" --hop "$OLD_HEAD" "$2"
}

walk_package() {  # walk_package <check name> <render json> <head>
  local name=$1 render=$2 head=$3 out rc=0 result
  out=$(walk_out "$render" "$head") || rc=$?
  echo "$out" | grep '^INFO ' || true
  result=$(echo "$out" | tail -n 1)
  if [[ $rc == 0 && $result == 'PASS '* ]]; then
    check "$name" PASS "${result#PASS }; hops ${CSV_V113##*.v} -> ${CSV_V116##*.v} -> ${OLD_HEAD##*.v} -> ${head##*.v}"
  else
    check "$name" FAIL "${result#FAIL }"
  fi
}

# The bundle file is in the catalog, the channel has no entry for it: opm validate must refuse.
negative_control() {  # negative_control <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative out
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  NEW=$NEW_CSV CH=$CHANNEL yq -i \
    '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) |= map(select(.name != strenv(NEW)))' \
    "${neg}/catalog/${PKG}/${PKG}.yaml"
  if out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-${b}" FAIL "opm validate passed with ${NEW_CSV} in the catalog but not in channel ${CHANNEL}"
    return 0
  fi
  echo "$out" | tail -n 5
  if echo "$out" | grep -qF "$NEW_CSV"; then
    check "negative-control-${b}" PASS "opm validate failed as expected without the channel entry: $(echo "$out" | tail -n 1 | cut -c1-300)"
  else
    check "negative-control-${b}" FAIL "opm validate failed, but its error does not name ${NEW_CSV}: $(echo "$out" | tail -n 2 | one_line)"
  fi
}

# The case the walker's hops exist for: with skipRange '>=1.0.0 <ver' opm validate still passes,
# and every old entry has an edge to the head, so 1.13 skips 1.16 and 1.19.0.
negative_control_skiprange() {  # negative_control_skiprange <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-skiprange render out rc=0 result
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  NEW=$NEW_CSV CH=$CHANNEL SR=">=1.0.0 <${WANT_VERSION}" yq -i \
    '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .skipRange) = strenv(SR)' \
    "${neg}/catalog/${PKG}/${PKG}.yaml"
  if ! out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-skiprange-${b}" FAIL "opm validate failed with the wide skipRange: $(echo "$out" | tail -n 2 | one_line)"
    return 0
  fi
  render=${neg}/render.json
  opm render "${neg}/catalog/${PKG}" -o json >"$render"
  out=$(walk_out "$render" "$NEW_CSV") || rc=$?
  result=$(echo "$out" | tail -n 1)
  if [[ $rc != 0 && $result == FAIL* && $result == *"hop from ${CSV_V113} goes to"* ]]; then
    check "negative-control-skiprange-${b}" PASS "with skipRange '>=1.0.0 <${WANT_VERSION}' opm validate passes and the walker fails: ${result#FAIL }"
  else
    check "negative-control-skiprange-${b}" FAIL "walker did not catch the wide skipRange (exit ${rc}): ${result}"
  fi
}

do_branch() {  # do_branch <branch>
  local b=$1 tree=${RUN_DIR}/${1} render
  [[ ! -e $tree ]] || die "${tree} exists: catalog-edit.sh runs once per RUN_DIR"
  git clone --quiet --depth 1 --branch "$b" "$CATALOG_REPO" "$tree"
  echo "INFO catalog ${b} $(git -C "$tree" rev-parse HEAD) from ${CATALOG_REPO}"
  [[ -z $(git -C "$tree" status --porcelain --untracked-files=all) ]] || die "fresh clone of ${b} is not clean"

  current_head "$b" "$tree" || return 0
  add_bundles "$tree"
  new_bundles "$b" "$tree" || return 0
  edit_package "$b" "$tree" || return 0

  validate_tree "opm-validate-${b}" "${tree}/catalog"

  render=${RUN_DIR}/render-${b}-after.json
  if ! opm render "${tree}/catalog/${PKG}" -o json >"$render" 2>"${render}.err"; then
    check "walk-${b}" FAIL "opm render: $(tail -n 2 "${render}.err" | one_line)"
  else
    walk_package "walk-${b}" "$render" "$NEW_CSV"
  fi

  negative_control "$b" "$tree"
  negative_control_skiprange "$b" "$tree"

  # The edit, for the log and for the catalog PRs later.
  git -C "$tree" add -A
  git -C "$tree" diff --cached >"${RUN_DIR}/${b}.diff"
  git -C "$tree" diff --cached --stat | sed "s|^|INFO diff ${b} |"
  git -C "$tree" diff --cached -- "catalog/${PKG}/${PKG}.yaml" | sed "s|^|INFO diff ${b} |"

  if [[ $b == "$IMAGE_BRANCH" ]]; then IMAGE_HEAD=$NEW_CSV; fi
}

# ---------------------------------------------------------------------------------------
# test catalog image

image_context() {  # assemble ${RUN_DIR}/catalog-image; FAIL and return 1 if it is not right
  local tree=${RUN_DIR}/${IMAGE_BRANCH} ctx=${RUN_DIR}/catalog-image from got
  mkdir -p "${ctx}/catalog"
  cp -R "${tree}/catalog/${PKG}" "${ctx}/catalog/"
  from=$(grep '^FROM ' "${tree}/catalog.Containerfile" || true)
  if [[ $from != "$UPSTREAM_OPM_FROM" ]]; then
    check catalog-image FAIL "${IMAGE_BRANCH} catalog.Containerfile FROM is '$(echo "$from" | one_line)', want '${UPSTREAM_OPM_FROM}'"
    return 1
  fi
  sed "s|^${UPSTREAM_OPM_FROM}\$|FROM ${OPM_IMAGE}|" "${tree}/catalog.Containerfile" >"${ctx}/catalog.Containerfile"
  sed 's|^|INFO Containerfile |' "${ctx}/catalog.Containerfile"
  validate_tree opm-validate-image "${ctx}/catalog"
  got=$(opm render "${ctx}/catalog" -o json | jq -r 'select(.schema == "olm.package") | .name' | sort | paste -sd ' ' -)
  if [[ $got != "$PKG" ]]; then
    check catalog-image FAIL "image context packages '${got}', want '${PKG}'"
    return 1
  fi
}

image_check() {  # image_check <render json of the image>: package and walk
  local render=$1 got out rc=0
  got=$(jq -r 'select(.schema == "olm.package") | .name' "$render" | sort | paste -sd ' ' -)
  out=$(walk_out "$render" "$IMAGE_HEAD") || rc=$?
  echo "$out" | grep '^INFO ' | sed 's|^INFO |INFO image |' || true
  if [[ $got == "$PKG" && $rc == 0 ]]; then
    check catalog-image PASS "${CATALOG_IMAGE}: package ${got}; head ${IMAGE_HEAD}; every entry and ${INSTALLED[*]} reach the head"
  else
    check catalog-image FAIL "${CATALOG_IMAGE}: packages '${got}', walk: $(echo "$out" | tail -n 1)"
  fi
}

do_image() {
  local ctx=${RUN_DIR}/catalog-image
  if [[ " ${CATALOG_BRANCHES} " != *" ${IMAGE_BRANCH} "* ]]; then
    check catalog-image FAIL "${IMAGE_BRANCH} (the test catalog's source) is not in CATALOG_BRANCHES"
    return 0
  fi
  if [[ $FAILS != 0 || -z $IMAGE_HEAD ]]; then
    check catalog-image FAIL "not built: ${FAILS} checks failed before it"
    return 0
  fi
  image_context || return 0
  if [[ $FAILS != 0 ]]; then
    check catalog-image FAIL "not built: the image context failed opm validate"
    return 0
  fi
  if [[ -n $TEST_BUNDLES ]]; then
    echo "INFO test mode: image context ${ctx} assembled and validated, not built"
    return 0
  fi
  if ! podman build --file "${ctx}/catalog.Containerfile" --tag "$CATALOG_IMAGE" "$ctx"; then
    check catalog-image FAIL "podman build failed"
    return 0
  fi
  if ! podman push "$CATALOG_IMAGE"; then
    check catalog-image FAIL "podman push ${CATALOG_IMAGE} failed"
    return 0
  fi
  echo "$CATALOG_IMAGE" >"${RUN_DIR}/catalog-image.pushed"   # build.sh prints PUSHED from this
  # What a CatalogSource will serve: render the pushed image back and walk it again.
  if ! opm render "$CATALOG_IMAGE" -o json >"${RUN_DIR}/render-image.json"; then
    check catalog-image FAIL "opm render ${CATALOG_IMAGE} failed"
    return 0
  fi
  image_check "${RUN_DIR}/render-image.json"
}

main() {
  local b
  validate_inputs
  if ! bundle_versions; then
    echo "INFO catalog-edit: stopped before any edit, ${FAILS} checks failed"
    exit 1
  fi
  for b in $CATALOG_BRANCHES; do
    do_branch "$b"
  done
  do_image
  echo "INFO catalog-edit: ${FAILS} checks failed"
  if [[ $FAILS != 0 ]]; then exit 1; fi
}

main "$@"
