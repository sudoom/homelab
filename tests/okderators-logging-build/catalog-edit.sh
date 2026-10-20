#!/bin/bash
# MODE=catalog of the okderators-logging-build Job (README.md, "MODE=catalog"). build.sh runs it
# as /scripts/catalog-edit.sh in an empty RUN_DIR and copies its CHECK lines into the contract.
#
# First, once: each bundle in BUNDLES must belong to one of PACKAGES and have a
# BUNDLE_MINOR.* version, or the run stops before any edit   CHECK bundle-version-<pkg>
# Then for each okderators-catalog-index branch in CATALOG_BRANCHES:
#   1. clone it; each package in PACKAGES must have exactly one head in channel CHANNEL
#   2. add the two bundles in BUNDLES with the branch's own hack/add-bundle.sh
#                                                              CHECK bundles-<branch>
#   3. append one entry per package to the channel: name <bundle CSV>, replaces <that head>,
#      skipRange SKIP_RANGE                                    CHECK edit-<branch>-<pkg>
#   4. opm validate catalog                                    CHECK opm-validate-<branch>
#   5. graph walk (catalog-walk.py) from every entry and from the CSVs in INSTALLED
#                                                              CHECK walk-<branch>-<pkg>
#   6. negative control: a copy with the new entries' replaces removed must fail opm validate
#      with "multiple channel heads"                           CHECK negative-control-<branch>
#   7. second control, where the homelab's CSVs (HOMELAB_CSVS) are absent from the channel: a
#      copy with the new entries' skipRange removed must still pass opm validate while the
#      walker strands those CSVs                      CHECK negative-control-skiprange-<branch>
# Then, only if every check passed: the test catalog image from the edited IMAGE_BRANCH tree,
# PACKAGES only, built from that branch's own catalog.Containerfile with the opm base image
# pinned, pushed to CATALOG_IMAGE, rendered back and walked    CHECK catalog-image
#
# Env:
#   CATALOG_BRANCHES  okderators-catalog-index branches, e.g. "release-4.20 release-4.21 release-4.22"
#   BUNDLES           the two bundle image refs (cluster-logging and loki-operator, any order)
#   RUN_DIR           empty working directory (build.sh: /work/run)
#   CATALOG_IMAGE     push target, set and guarded by build.sh: ${BASE_REGISTRY}/logging-catalog:${DATE}
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
PACKAGES=(cluster-logging loki-operator)
CHANNEL=alpha
# The release the bundles must be, and the skipRange of the new entries (brief: '>=6.2.0-0 <6.6.0').
BUNDLE_MINOR=6.6
SKIP_RANGE=">=6.2.0-0 <${BUNDLE_MINOR}.0"
# CSVs a cluster may run that a channel does not list; the walker starts from them too.
# HOMELAB_CSVS: what the homelab runs (installed from the 4.20 catalog), absent from the
# 4.21/4.22 catalogs, so only the new entry's skipRange reaches them.
# OLD_CSVS: entries of the catalogs' past, today named only in the 6.2.0-2025-05-26 entries' skips.
HOMELAB_CSVS=(cluster-logging.v6.5.0-2026-06-04-101319 loki-operator.v6.5.0-2026-06-04-101319)
OLD_CSVS=(cluster-logging.v6.2.0-2025-05-25-184240 loki-operator.v6.2.0-2025-05-25-184240)
INSTALLED=("${HOMELAB_CSVS[@]}" "${OLD_CSVS[@]}")
IMAGE_BRANCH=release-4.21
# catalog.Containerfile builds FROM the mutable :latest; the test image pins it. v1.74.0 is the
# opm build.sh installs, and :latest pointed at this same index on 2026-10-20. Digest only:
# containers/image refuses a reference with both a tag and a digest.
UPSTREAM_OPM_FROM='FROM quay.io/operator-framework/opm:latest'
OPM_IMAGE=quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f
# Independent of build.sh's guard: never push anywhere but zot okd-test/.
PUSH_RE='^zot\.apps\.okd\.sudops\.pl/okd-test/[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*$'

FAILS=0
IMAGE_HEADS=()     # the new CSV names on IMAGE_BRANCH, per PACKAGES index
OLD_HEAD=()        # per PACKAGES index, for the branch being edited
NEW_CSV=()
WANT_CSV=()        # per PACKAGES index: the bundle names bundle_versions read

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

installed_args() {  # installed_args <package>: "--installed <CSV>" for its INSTALLED CSVs, one word per line
  local csv
  for csv in "${INSTALLED[@]}"; do
    if [[ $csv == "${1}.v"* ]]; then printf -- '--installed\n%s\n' "$csv"; fi
  done
}

pkg_index() {  # pkg_index <package>: its index in PACKAGES, or nothing
  local i
  for i in "${!PACKAGES[@]}"; do
    if [[ ${PACKAGES[$i]} == "$1" ]]; then echo "$i"; fi
  done
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
    [[ $n == 2 ]] || die "BUNDLES has ${n} refs, want 2 (cluster-logging and loki-operator)"
    [[ $CATALOG_IMAGE =~ $PUSH_RE ]] || die "CATALOG_IMAGE '${CATALOG_IMAGE}' is not a zot okd-test/ tag"
  fi
  echo "INFO tool python3 $(python3 --version 2>&1)"
}

# Once, before any clone or edit: what the bundles are. A wrong paste (a 6.5 bundle, two of
# one package) stops here instead of producing and pushing a catalog.
bundle_versions() {
  local dir=${RUN_DIR}/bundles n=0 ref f name pkg version i failed=0
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
        check "bundle-version-${n}" FAIL "opm render $(digest_ref "$ref") failed"
        return 1
      fi
    done
  fi
  WANT_CSV=()
  for f in "$dir"/*.yaml; do
    [[ -f $f ]] || continue
    name=$(bundle_field "$f" .name)
    pkg=$(bundle_field "$f" .package)
    version=$(bundle_field "$f" '.properties[] | select(.type == "olm.package") | .value.version')
    i=$(pkg_index "$pkg")
    if [[ -z $i ]]; then
      check "bundle-version-${pkg}" FAIL "${name}: package ${pkg} is not one of ${PACKAGES[*]}"
      failed=1
    elif [[ -n ${WANT_CSV[$i]:-} ]]; then
      check "bundle-version-${pkg}" FAIL "two bundles for ${pkg}: ${WANT_CSV[$i]} and ${name}"
      failed=1
    elif [[ $version != "${BUNDLE_MINOR}."* ]]; then
      check "bundle-version-${pkg}" FAIL "${name} has version ${version}, want ${BUNDLE_MINOR}.*"
      failed=1
    else
      WANT_CSV[$i]=$name
      check "bundle-version-${pkg}" PASS "${name} ${version}"
    fi
  done
  for i in "${!PACKAGES[@]}"; do
    if [[ $failed == 0 && -z ${WANT_CSV[$i]:-} ]]; then
      check "bundle-version-${PACKAGES[$i]}" FAIL "no bundle for ${PACKAGES[$i]}"
      failed=1
    fi
  done
  return "$failed"
}

# ---------------------------------------------------------------------------------------
# per branch

current_heads() {  # current_heads <branch> <tree>: fill OLD_HEAD, or FAIL and return 1
  local b=$1 tree=$2 i pkg render heads n max
  for i in "${!PACKAGES[@]}"; do
    pkg=${PACKAGES[$i]}
    render=$RUN_DIR/render-${b}-${pkg}-before.json
    opm render "${tree}/catalog/${pkg}" -o json >"$render"
    if ! heads=$(walker heads "$render" "$pkg" "$CHANNEL"); then
      check "edit-${b}-${pkg}" FAIL "$(echo "$heads" | one_line)"
      return 1
    fi
    n=$(echo "$heads" | grep -c . || true)
    if [[ $n != 1 ]]; then
      check "edit-${b}-${pkg}" FAIL "${n} heads in ${CHANNEL} before the edit: $(echo "$heads" | one_line)"
      return 1
    fi
    max=$(jq -r --arg n "$heads" 'select(.schema == "olm.bundle" and .name == $n)
           | [.properties[]? | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | first // "none"' "$render")
    echo "INFO head before ${b} ${pkg} ${heads} olm.maxOpenShiftVersion=${max}"
    OLD_HEAD[$i]=$heads
  done
}

# hack/add-bundle.sh writes `opm render <bundle> -o yaml` to catalog/<package>/<CSV name>.yaml.
# On release-4.2x it first runs `podman create` on the bundle to read the CSV name, which fails
# for a bundle built FROM scratch with no CMD (every bundle this pipeline builds;
# okderators-catalog-index PR #59, open, drops the podman step). If it fails, write the same
# file the same way, reading the name from the render as PR #59 does.
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

add_bundles() {  # add_bundles <tree>; records how each bundle was added in add-bundles.how
  local tree=$1 ref f name pkg repo how=()
  if [[ -n $TEST_BUNDLES ]]; then
    for f in "$TEST_BUNDLES"/*.yaml; do
      [[ -f $f ]] || continue
      name=$(bundle_field "$f" .name)
      pkg=$(bundle_field "$f" .package)
      mkdir -p "${tree}/catalog/${pkg}"
      cp "$f" "${tree}/catalog/${pkg}/${name}.yaml"
      how+=("${pkg}:test-file")
    done
  else
    for ref in $BUNDLES; do
      ref=$(digest_ref "$ref")
      repo=${ref##*/}
      repo=${repo%%[@:]*}
      echo "INFO add-bundle ${ref}"
      if (cd "$tree" && bash ./hack/add-bundle.sh "$ref"); then
        how+=("${repo}:hack/add-bundle.sh")
      else
        echo "INFO hack/add-bundle.sh failed for ${ref}; rendering with opm directly"
        add_bundle_render "$tree" "$ref"
        how+=("${repo}:opm-render")
      fi
    done
  fi
  echo "${how[*]:-none}" >"${RUN_DIR}/add-bundles.how"
}

new_bundles() {  # new_bundles <branch> <tree>: fill NEW_CSV from the files add_bundles wrote
  local b=$1 tree=$2 line file name pkg i n=0
  NEW_CSV=()
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line != '?? '* ]]; then
      check "bundles-${b}" FAIL "adding the bundles changed a tracked file (already in the catalog?): ${line}"
      return 1
    fi
    file=${line#'?? '}
    name=$(bundle_field "${tree}/${file}" .name)
    pkg=$(bundle_field "${tree}/${file}" .package)
    i=$(pkg_index "$pkg")
    if [[ -z $i || $file != "catalog/${pkg}/${name}.yaml" ]]; then
      check "bundles-${b}" FAIL "unexpected new file ${file} (package ${pkg}, bundle ${name})"
      return 1
    fi
    if [[ -n ${NEW_CSV[$i]:-} ]]; then
      check "bundles-${b}" FAIL "two bundles for package ${pkg}: ${NEW_CSV[$i]} and ${name}"
      return 1
    fi
    if [[ $name != "${WANT_CSV[$i]}" ]]; then
      check "bundles-${b}" FAIL "added ${name}, but the bundle checked up front is ${WANT_CSV[$i]}"
      return 1
    fi
    NEW_CSV[$i]=$name
    n=$((n + 1))
  done <<<"$(git -C "$tree" status --porcelain --untracked-files=all)"
  if [[ $n != "${#PACKAGES[@]}" ]]; then
    check "bundles-${b}" FAIL "${n} new bundle files, want one per package (${PACKAGES[*]}); already in the catalog?"
    return 1
  fi
  check "bundles-${b}" PASS "${NEW_CSV[*]} ($(cat "${RUN_DIR}/add-bundles.how"))"
}

edit_package() {  # edit_package <branch> <tree> <index>: append the new entry, or FAIL and return 1
  local b=$1 tree=$2 i=$3 pkg file orig want
  pkg=${PACKAGES[$i]}
  file=${tree}/catalog/${pkg}/${pkg}.yaml
  if NEW=${NEW_CSV[$i]} CH=$CHANNEL yq e -e \
      'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW))' \
      "$file" >/dev/null 2>&1; then
    check "edit-${b}-${pkg}" FAIL "${NEW_CSV[$i]} is already in channel ${CHANNEL}: refusing to edit twice"
    return 1
  fi
  orig=${RUN_DIR}/${b}-${pkg}.yaml.orig
  want=${RUN_DIR}/${b}-${pkg}.yaml.want
  cp "$file" "$orig"
  NEW=${NEW_CSV[$i]} OLD=${OLD_HEAD[$i]} SR=$SKIP_RANGE CH=$CHANNEL yq -i \
    '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) += [{"name": strenv(NEW), "replaces": strenv(OLD), "skipRange": strenv(SR)}]' \
    "$file"
  # The edit must be exactly the appended entry (plus a final newline where the file had
  # none): yq re-emits the whole file, and nothing else in it may change.
  {
    cat "$orig"
    if [[ -n $(tail -c 1 "$orig") ]]; then echo; fi
    printf "  - name: %s\n    replaces: %s\n    skipRange: '%s'\n" "${NEW_CSV[$i]}" "${OLD_HEAD[$i]}" "$SKIP_RANGE"
  } >"$want"
  if ! cmp -s "$want" "$file"; then
    check "edit-${b}-${pkg}" FAIL "yq changed more than the appended entry: $(diff "$want" "$file" | head -n 6 | one_line)"
    return 1
  fi
  check "edit-${b}-${pkg}" PASS "${NEW_CSV[$i]} replaces ${OLD_HEAD[$i]}, skipRange '${SKIP_RANGE}' (+3 lines)"
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

walk_out() {  # walk_out <render json> <index> <head>: catalog-walk.py walk, with the INSTALLED CSVs
  local pkg=${PACKAGES[$2]} word args=()
  while IFS= read -r word; do
    if [[ -n $word ]]; then args+=("$word"); fi
  done <<<"$(installed_args "$pkg")"
  walker walk "$1" "$pkg" "$CHANNEL" "$3" ${args[@]+"${args[@]}"}
}

walk_package() {  # walk_package <check name> <render json> <index> <head>
  local name=$1 render=$2 i=$3 head=$4 out rc=0 result
  out=$(walk_out "$render" "$i" "$head") || rc=$?
  echo "$out" | grep '^INFO ' || true
  result=$(echo "$out" | tail -n 1)
  if [[ $rc == 0 && $result == 'PASS '* ]]; then
    check "$name" PASS "${result#PASS }"
  else
    check "$name" FAIL "${result#FAIL }"
  fi
}

negative_control() {  # negative_control <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative i pkg out lines line found=() missing=()
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  for i in "${!PACKAGES[@]}"; do
    pkg=${PACKAGES[$i]}
    NEW=${NEW_CSV[$i]} CH=$CHANNEL yq -i \
      '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW))) |= del(.replaces)' \
      "${neg}/catalog/${pkg}/${pkg}.yaml"
  done
  if out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-${b}" FAIL "opm validate passed with the new entries' replaces removed"
    return 0
  fi
  # opm logs the whole error tree as one logfmt msg with literal \n separators: split it, so
  # each package needs its own "multiple channel heads" line naming its old head and new entry.
  lines=$(echo "$out" | awk '{ gsub(/\\n/, "\n"); print }')
  echo "$lines" | tail -n 10
  for i in "${!PACKAGES[@]}"; do
    line=$(echo "$lines" | grep -F 'multiple channel heads found in graph' | grep -F "${OLD_HEAD[$i]}" \
      | grep -F "${NEW_CSV[$i]}" | head -n 1 || true)
    if [[ -n $line ]]; then
      line=${line##*graph: }
      found+=("${line%\"}")
    else
      missing+=("${PACKAGES[$i]}")
    fi
  done
  if [[ ${#missing[@]} == 0 ]]; then
    check "negative-control-${b}" PASS "opm validate failed as expected, multiple channel heads: $(IFS='|'; echo "${found[*]}" | sed 's/|/ | /g')"
  else
    check "negative-control-${b}" FAIL "opm validate failed, but not with multiple channel heads for ${missing[*]}: $(echo "$out" | tail -n 2 | one_line)"
  fi
}

in_channel() {  # in_channel <render json> <CSV>: is the CSV a channel entry
  jq -e --arg c "$CHANNEL" --arg n "$2" \
    'select(.schema == "olm.channel" and .name == $c) | .entries[] | select(.name == $n)' "$1" >/dev/null
}

# The case the walker exists for: without the new skipRange, opm validate still passes, but a
# cluster on the homelab's CSV (absent from this channel) has no edge to the head.
negative_control_skiprange() {  # negative_control_skiprange <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-skiprange i pkg csv render out rc want=() stranded=() wrong=()
  for i in "${!PACKAGES[@]}"; do
    for csv in "${HOMELAB_CSVS[@]}"; do
      if [[ $csv == "${PACKAGES[$i]}.v"* ]] && ! in_channel "${RUN_DIR}/render-${b}-${PACKAGES[$i]}-before.json" "$csv"; then
        want+=("$i:$csv")
      fi
    done
  done
  if [[ ${#want[@]} == 0 ]]; then
    echo "INFO negative-control-skiprange-${b} not run: the homelab's CSVs are channel entries here"
    return 0
  fi
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  for i in "${!PACKAGES[@]}"; do
    pkg=${PACKAGES[$i]}
    NEW=${NEW_CSV[$i]} CH=$CHANNEL yq -i \
      '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW))) |= del(.skipRange)' \
      "${neg}/catalog/${pkg}/${pkg}.yaml"
  done
  if ! out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-skiprange-${b}" FAIL "opm validate failed without the skipRange: $(echo "$out" | tail -n 2 | one_line)"
    return 0
  fi
  for csv in "${want[@]}"; do
    i=${csv%%:*}
    csv=${csv#*:}
    pkg=${PACKAGES[$i]}
    render=${neg}/render-${pkg}.json
    opm render "${neg}/catalog/${pkg}" -o json >"$render"
    rc=0
    out=$(walk_out "$render" "$i" "${NEW_CSV[$i]}") || rc=$?
    if [[ $rc != 0 ]] && echo "$out" | grep -qF "INFO stranded ${csv} "; then
      stranded+=("$csv")
    else
      wrong+=("${pkg}: $(echo "$out" | tail -n 1)")
    fi
  done
  if [[ ${#wrong[@]} == 0 ]]; then
    check "negative-control-skiprange-${b}" PASS "without the new skipRange opm validate passes and the walker strands ${stranded[*]}"
  else
    check "negative-control-skiprange-${b}" FAIL "walker did not strand the homelab CSV: ${wrong[*]}"
  fi
}

do_branch() {  # do_branch <branch>
  local b=$1 tree=${RUN_DIR}/${1} i pkg render
  [[ ! -e $tree ]] || die "${tree} exists: catalog-edit.sh runs once per RUN_DIR"
  git clone --quiet --depth 1 --branch "$b" "$CATALOG_REPO" "$tree"
  echo "INFO catalog ${b} $(git -C "$tree" rev-parse HEAD) from ${CATALOG_REPO}"
  [[ -z $(git -C "$tree" status --porcelain --untracked-files=all) ]] || die "fresh clone of ${b} is not clean"

  OLD_HEAD=()
  current_heads "$b" "$tree" || return 0
  add_bundles "$tree"
  new_bundles "$b" "$tree" || return 0
  for i in "${!PACKAGES[@]}"; do
    edit_package "$b" "$tree" "$i" || return 0
  done

  validate_tree "opm-validate-${b}" "${tree}/catalog"

  for i in "${!PACKAGES[@]}"; do
    pkg=${PACKAGES[$i]}
    render=${RUN_DIR}/render-${b}-${pkg}-after.json
    if ! opm render "${tree}/catalog/${pkg}" -o json >"$render" 2>"${render}.err"; then
      check "walk-${b}-${pkg}" FAIL "opm render: $(tail -n 2 "${render}.err" | one_line)"
      continue
    fi
    walk_package "walk-${b}-${pkg}" "$render" "$i" "${NEW_CSV[$i]}"
  done

  negative_control "$b" "$tree"
  negative_control_skiprange "$b" "$tree"

  # The edit, for the log and for the catalog PRs later.
  git -C "$tree" add -A
  git -C "$tree" diff --cached >"${RUN_DIR}/${b}.diff"
  git -C "$tree" diff --cached --stat | sed "s|^|INFO diff ${b} |"
  for pkg in "${PACKAGES[@]}"; do
    git -C "$tree" diff --cached -- "catalog/${pkg}/${pkg}.yaml" | sed "s|^|INFO diff ${b} |"
  done

  if [[ $b == "$IMAGE_BRANCH" ]]; then IMAGE_HEADS=("${NEW_CSV[@]}"); fi
}

# ---------------------------------------------------------------------------------------
# test catalog image

image_context() {  # assemble ${RUN_DIR}/catalog-image; FAIL and return 1 if it is not right
  local tree=${RUN_DIR}/${IMAGE_BRANCH} ctx=${RUN_DIR}/catalog-image pkg from got
  mkdir -p "${ctx}/catalog"
  for pkg in "${PACKAGES[@]}"; do
    cp -R "${tree}/catalog/${pkg}" "${ctx}/catalog/"
  done
  from=$(grep '^FROM ' "${tree}/catalog.Containerfile" || true)
  if [[ $from != "$UPSTREAM_OPM_FROM" ]]; then
    check catalog-image FAIL "${IMAGE_BRANCH} catalog.Containerfile FROM is '$(echo "$from" | one_line)', want '${UPSTREAM_OPM_FROM}'"
    return 1
  fi
  sed "s|^${UPSTREAM_OPM_FROM}\$|FROM ${OPM_IMAGE}|" "${tree}/catalog.Containerfile" >"${ctx}/catalog.Containerfile"
  sed 's|^|INFO Containerfile |' "${ctx}/catalog.Containerfile"
  validate_tree opm-validate-image "${ctx}/catalog"
  got=$(opm render "${ctx}/catalog" -o json | jq -r 'select(.schema == "olm.package") | .name' | sort | paste -sd ' ' -)
  if [[ $got != "$(printf '%s\n' "${PACKAGES[@]}" | sort | paste -sd ' ' -)" ]]; then
    check catalog-image FAIL "image context packages '${got}', want '${PACKAGES[*]}'"
    return 1
  fi
}

image_check() {  # image_check <render json of the image>: packages and walks
  local render=$1 got i out rc fails=()
  got=$(jq -r 'select(.schema == "olm.package") | .name' "$render" | sort | paste -sd ' ' -)
  if [[ $got != "$(printf '%s\n' "${PACKAGES[@]}" | sort | paste -sd ' ' -)" ]]; then
    fails+=("packages '${got}', want '${PACKAGES[*]}'")
  fi
  for i in "${!PACKAGES[@]}"; do
    rc=0
    out=$(walk_out "$render" "$i" "${IMAGE_HEADS[$i]}") || rc=$?
    echo "$out" | grep '^INFO ' | sed 's|^INFO |INFO image |' || true
    if [[ $rc != 0 ]]; then fails+=("${PACKAGES[$i]}: $(echo "$out" | tail -n 1)"); fi
  done
  if [[ ${#fails[@]} == 0 ]]; then
    check catalog-image PASS "${CATALOG_IMAGE}: packages ${got}; heads ${IMAGE_HEADS[*]}; every entry and ${INSTALLED[*]} reach the head"
  else
    check catalog-image FAIL "${CATALOG_IMAGE}: ${fails[*]}"
  fi
}

do_image() {
  local ctx=${RUN_DIR}/catalog-image
  if [[ " ${CATALOG_BRANCHES} " != *" ${IMAGE_BRANCH} "* ]]; then
    check catalog-image FAIL "${IMAGE_BRANCH} (the test catalog's source) is not in CATALOG_BRANCHES"
    return 0
  fi
  if [[ $FAILS != 0 || ${#IMAGE_HEADS[@]} == 0 ]]; then
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
