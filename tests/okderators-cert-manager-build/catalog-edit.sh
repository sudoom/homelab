#!/bin/bash
# MODE=catalog of the okderators-cert-manager-build Job (README.md, "MODE=catalog"). build.sh runs it
# as /scripts/catalog-edit.sh in an empty RUN_DIR and copies its CHECK lines into the contract.
# Adapted from the previous operator Job's catalog-edit.sh (README.md, "What differs"): the per-branch
# loop, the bundle check, opm validate, the graph walk (catalog-walk.py, unchanged), a negative
# control, the image build and push and the CHECK format are kept; the edit is different. One entry
# is APPENDED after the channel's last, with `replaces`, the shape every existing cert-manager-operator
# entry has (no skipRange, no skips).
#
# What each okderators-catalog-index branch gets is data, not code: catalog-branches.tsv (next to
# this script) has one row per branch with REPLACES (the alpha channel's last entry before the edit)
# and INSTALLED (CSVs a cluster may run; the walker starts from them too).
#
# First, before any clone or edit (a FAIL stops the run): IMAGE_BRANCH is one of CATALOG_BRANCHES
# (CHECK catalog-image FAIL otherwise), and for every branch in CATALOG_BRANCHES:
#   - its catalog-branches.tsv row exists and holds no TO-FILL       CHECK branch-data-<branch>
#   - its bundle (BUNDLES <branch>=<ref@digest>): package cert-manager-operator, version
#     1.21.0-<DATE>, olm.bundle name cert-manager-operator.v<version>, exactly one CSV object and
#     it has that name (the three names agree)                       CHECK bundle-<branch>
# Then per branch:
#   1. clone it (with opm: the unedited catalog's opm validate verdict as INFO, the baseline);
#      channel alpha's last entry must be REPLACES, REPLACES its single head, with its
#      bundle file, and the new CSV not yet in the channel           (CHECK edit-<branch> on a FAIL)
#   2. add catalog/<package>/<CSV>.yaml, written as hack/add-bundle.sh writes it
#      (`opm render <bundle>@<digest> -o yaml`, echoed to the file)  CHECK bundles-<branch>
#   3. append one entry to the alpha channel: name <CSV>, replaces REPLACES; nothing else in the
#      package file changes                                          CHECK edit-<branch>
#   4. opm validate catalog                                          CHECK opm-validate-<branch>
#   5. graph walk (catalog-walk.py): the CSV is the single head and every entry and every
#      INSTALLED CSV reaches it                                      CHECK walk-<branch>
#   6. negative control, on a copy with the new entry's replaces removed (two heads): the walker
#      fails and reports every older entry and every INSTALLED CSV as stranded
#                                                            CHECK negative-control-replaces-<branch>
#      and opm validate rejects it with "multiple channel heads"
#                                                        CHECK negative-control-replaces-opm-<branch>
# Then, only if every check passed: the test catalog image from the edited IMAGE_BRANCH tree,
# package cert-manager-operator only, built from that branch's own catalog.Containerfile with the
# opm base image pinned, pushed to CATALOG_IMAGE, rendered back and walked
#                                                     CHECK opm-validate-image, CHECK catalog-image
#
# Env:
#   CATALOG_BRANCHES     okderators-catalog-index branches, e.g. "release-5.0"
#   BUNDLES              one bundle per branch: "<branch>=<ref@sha256:...> ..."; a ref may keep its tag
#   IMAGE_BRANCH         optional, default release-5.0: the branch the test catalog image comes from;
#                        must be one of CATALOG_BRANCHES
#   RUN_DIR              empty working directory (build.sh: /work/run)
#   CATALOG_IMAGE        push target, set and guarded by build.sh: ${BASE_REGISTRY}/cert-manager-catalog:${DATE}
#   CATALOG_REPO         optional, default the upstream GitHub repository
#   CATALOG_BRANCH_DATA  optional, default catalog-branches.tsv next to this script
# Test mode, for a laptop: CATALOG_EDIT_TEST_BUNDLES=<directory with one <branch>.yaml olm.bundle
#   file per branch> replaces the bundle render (no image pulls), BUNDLES is ignored and
#   CATALOG_IMAGE must be empty; the image context is still assembled, but nothing is built or
#   pushed. Only in test mode may opm be missing: then every `opm validate` is CHECK ... SKIP (never
#   PASS), and the catalog renders the walker reads are the FBC files converted by yq, not opm
#   render. Outside test mode a missing opm stops the run before any check.
#
# Output: CHECK <name> PASS|FAIL|SKIP <detail>, INFO and ERROR lines. Exit 0 when no check failed,
# 1 otherwise (a hard error exits 1 too, possibly before any CHECK line). SKIP appears only in test
# mode without opm. Written for bash 3.2 as well (no associative arrays, namerefs or mapfile), so
# the same file runs on the Mac.
set -euo pipefail

CATALOG_REPO=${CATALOG_REPO:-https://github.com/okd-project/okderators-catalog-index.git}
CATALOG_BRANCHES=${CATALOG_BRANCHES:-}
BUNDLES=${BUNDLES:-}
RUN_DIR=${RUN_DIR:-}
CATALOG_IMAGE=${CATALOG_IMAGE:-}
TEST_BUNDLES=${CATALOG_EDIT_TEST_BUNDLES:-}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA=${CATALOG_BRANCH_DATA:-${HERE}/catalog-branches.tsv}
PKG=cert-manager-operator
CHANNEL=alpha
CSV_RE='^cert-manager-operator\.v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
# What the full run builds: cert-manager/build.sh MINOR=21, OCP_DATE 1.21.0-<DATE>.
BUNDLE_VERSION_RE='^1\.21\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$'
# The branch the test catalog image is built from (callers pass it); release-5.0 for a cluster on OKD 5.0.
IMAGE_BRANCH=${IMAGE_BRANCH:-release-5.0}
# catalog.Containerfile builds FROM the mutable :latest; the test image pins it. v1.74.0 is the
# opm build.sh installs (the GitOps Job's pin, 2026-10-20). Digest only: containers/image refuses
# a reference with both a tag and a digest.
UPSTREAM_OPM_FROM='FROM quay.io/operator-framework/opm:latest'
OPM_IMAGE=quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f
# Independent of build.sh's guard: never push anywhere but zot okd-test/.
PUSH_RE='^zot\.apps\.okd\.sudops\.pl/okd-test/[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*$'

FAILS=0
SKIPS=0
IMAGE_HEAD=        # the new CSV name on IMAGE_BRANCH
HAVE_OPM=0
if command -v opm >/dev/null 2>&1; then HAVE_OPM=1; fi

check() {  # check <name> PASS|FAIL|SKIP <detail...>
  local name=$1 result=$2
  shift 2
  # SKIP only where the header allows it: test mode without opm. Anywhere else it is a FAIL.
  if [[ $result == SKIP && (-z $TEST_BUNDLES || $HAVE_OPM == 1) ]]; then
    result=FAIL
    set -- "(SKIP outside test mode)" "$@"
  fi
  echo "CHECK ${name} ${result} $*"
  case $result in
    PASS) ;;
    SKIP) SKIPS=$((SKIPS + 1)) ;;
    *) FAILS=$((FAILS + 1)) ;;
  esac
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

joined() {  # joined <file>: its lines joined by ", "
  paste -sd ',' "$1" | sed 's/,/, /g'
}

# containers/image (opm render, podman) refuses "repo:tag@sha256:..."; keep the digest.
digest_ref() {
  if [[ $1 =~ ^([^@]+):([^/@:]+)@(sha256:[0-9a-f]{64})$ ]]; then
    echo "${BASH_REMATCH[1]}@${BASH_REMATCH[3]}"
  else
    echo "$1"
  fi
}

# render_catalog <dir> <out json>: `opm render <dir> -o json`. Without opm (test mode only, checked
# in validate_inputs) the FBC files are converted by yq instead: the same documents, which is all the
# walker reads (schema, package, name, entries, olm.package properties), but nothing opm checks.
render_catalog() {
  if [[ $HAVE_OPM == 1 ]]; then
    opm render "$1" -o json >"$2"
  else
    yq_render "$1" "$2"
  fi
}

# yq_render <dir> <out json>: the FBC files of <dir> as a JSON stream, no opm. Also used in the Job
# for the negative control's deliberately invalid copy, so that no opm render runs on a broken graph.
yq_render() {
  find "$1" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | LC_ALL=C sort \
    | tr '\n' '\0' | xargs -0 yq ea -o=json -I=0 'select(. != null)' >"$2"
}

# ---------------------------------------------------------------------------------------
# inputs

row_count() {  # row_count <branch>
  awk -F '\t' -v b="$1" '$0 !~ /^#/ && $1 == b' "$DATA" | wc -l | tr -d ' '
}

row_field() {  # row_field <branch> <column>: 2 REPLACES, 3 INSTALLED
  awk -F '\t' -v b="$1" -v c="$2" '$0 !~ /^#/ && $1 == b {print $c}' "$DATA"
}

list_lines() {  # list_lines <comma-separated list>: one item per line, blanks dropped
  echo "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

bundle_ref() {  # bundle_ref <branch>: the ref BUNDLES names for it
  local item
  for item in $BUNDLES; do
    if [[ ${item%%=*} == "$1" ]]; then echo "${item#*=}"; fi
  done
}

validate_inputs() {
  local b seen=" " item key n
  [[ $RUN_DIR == /* && -d $RUN_DIR ]] || die "RUN_DIR '${RUN_DIR}' is not an absolute directory"
  [[ -n $CATALOG_BRANCHES ]] || die "CATALOG_BRANCHES is empty"
  [[ -f $DATA ]] || die "branch data ${DATA} does not exist"
  for b in $CATALOG_BRANCHES; do
    [[ $b =~ ^release-[0-9]+\.[0-9]+$ ]] || die "catalog branch '${b}' is not release-X.Y"
    [[ $seen != *" ${b} "* ]] || die "catalog branch ${b} is listed twice"
    seen="${seen}${b} "
  done
  if [[ -n $TEST_BUNDLES ]]; then
    [[ -d $TEST_BUNDLES ]] || die "CATALOG_EDIT_TEST_BUNDLES '${TEST_BUNDLES}' is not a directory"
    [[ -z $CATALOG_IMAGE ]] || die "test mode builds no image: CATALOG_IMAGE must be empty"
    echo "INFO test mode: bundles from ${TEST_BUNDLES}, no image build"
    if [[ $HAVE_OPM == 0 ]]; then
      echo "INFO test mode without opm: every opm validate is SKIP, catalogs are rendered by yq (not opm render)"
    fi
  else
    [[ $HAVE_OPM == 1 ]] || die "opm is not on PATH (only test mode may run without it)"
    for item in $BUNDLES; do
      key=${item%%=*}
      [[ $item == *=* && $seen == *" ${key} "* ]] || die "BUNDLES item '${item}' is not <branch>=<ref> for a branch in CATALOG_BRANCHES"
      [[ ${item#*=} =~ @sha256:[0-9a-f]{64}$ ]] || die "BUNDLES item '${item}': the ref has no @sha256: digest"
    done
    for b in $CATALOG_BRANCHES; do
      n=$(bundle_ref "$b" | grep -c . || true)
      [[ $n == 1 ]] || die "BUNDLES has ${n} refs for ${b}, want 1"
    done
    [[ $CATALOG_IMAGE =~ $PUSH_RE ]] || die "CATALOG_IMAGE '${CATALOG_IMAGE}' is not a zot okd-test/ tag"
  fi
  echo "INFO branch data ${DATA}"
  echo "INFO tool python3 $(python3 --version 2>&1)"
  if [[ $HAVE_OPM == 1 ]]; then echo "INFO tool opm $(opm version 2>&1 | head -n 1)"; fi
}

# One catalog-branches.tsv row per branch, no TO-FILL, every name a cert-manager-operator CSV name.
branch_data() {  # branch_data <branch>; writes <branch>.replaces and <branch>.installed
  local b=$1 n replaces installed name bad=
  n=$(row_count "$b")
  if [[ $n != 1 ]]; then
    check "branch-data-${b}" FAIL "${n} rows for ${b} in ${DATA##*/}, want 1"
    return 1
  fi
  replaces=$(row_field "$b" 2)
  installed=$(row_field "$b" 3)
  if [[ -z $replaces || -z $installed || "${replaces}${installed}" == *TO-FILL* || $replaces == *,* ]]; then
    check "branch-data-${b}" FAIL "row incomplete or REPLACES not one name: replaces '${replaces}', installed '${installed}'"
    return 1
  fi
  echo "$replaces" >"${RUN_DIR}/${b}.replaces"
  list_lines "$installed" >"${RUN_DIR}/${b}.installed"
  for name in $(cat "${RUN_DIR}/${b}.replaces" "${RUN_DIR}/${b}.installed"); do
    [[ $name =~ $CSV_RE ]] || bad="${bad} ${name}"
  done
  if [[ -n $bad ]]; then
    check "branch-data-${b}" FAIL "not a ${PKG} CSV name:${bad}"
    return 1
  fi
  check "branch-data-${b}" PASS "replaces ${replaces}; installed [$(joined "${RUN_DIR}/${b}.installed")]"
}

objects_json() {  # objects_json <olm.bundle json file>: [{kind, name}] of its bundle objects
  jq -c '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson
          | {kind, name: (.metadata.name // "-")}]' "$1"
}

# Before any clone: what the branch's bundle is. A wrong paste (the 1.20 bundle, a bundle of another
# package, a CSV renamed in one place only) stops here instead of producing and pushing a catalog.
bundle_check() {  # bundle_check <branch>; writes <branch>.csv, .version, bundles/<branch>.{yaml,json}
  local b=$1 dir=${RUN_DIR}/bundles ref rendered f name pkg version image objs csvname ncsv ncrd nobj bad
  mkdir -p "$dir"
  f=${dir}/${b}.yaml
  if [[ -n $TEST_BUNDLES ]]; then
    if [[ ! -f ${TEST_BUNDLES}/${b}.yaml ]]; then
      check "bundle-${b}" FAIL "no test bundle ${TEST_BUNDLES}/${b}.yaml"
      return 1
    fi
    cp "${TEST_BUNDLES}/${b}.yaml" "$f"
  else
    ref=$(digest_ref "$(bundle_ref "$b")")
    # hack/add-bundle.sh: RENDERED=$(opm render $BUNDLE -o yaml); echo "$RENDERED" > <file>
    if ! rendered=$(opm render "$ref" -o yaml); then
      check "bundle-${b}" FAIL "opm render ${ref} failed"
      return 1
    fi
    echo "$rendered" >"$f"
  fi
  yq e -o=json 'select(.schema == "olm.bundle")' "$f" >"${dir}/${b}.json"
  if [[ $(jq -s 'length' "${dir}/${b}.json") != 1 ]]; then
    check "bundle-${b}" FAIL "$(jq -s 'length' "${dir}/${b}.json") olm.bundle documents in ${f##*/}, want 1"
    return 1
  fi
  name=$(jq -r '.name' "${dir}/${b}.json")
  pkg=$(jq -r '.package' "${dir}/${b}.json")
  image=$(jq -r '.image // ""' "${dir}/${b}.json")
  version=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "${dir}/${b}.json")
  objs=$(objects_json "${dir}/${b}.json")
  csvname=$(jq -r '[.[] | select(.kind == "ClusterServiceVersion") | .name] | join(" ")' <<<"$objs")
  ncsv=$(jq '[.[] | select(.kind == "ClusterServiceVersion")] | length' <<<"$objs")
  ncrd=$(jq '[.[] | select(.kind == "CustomResourceDefinition")] | length' <<<"$objs")
  nobj=$(jq 'length' <<<"$objs")
  bad=
  [[ $pkg == "$PKG" ]] || bad="${bad} package ${pkg};"
  [[ $version =~ $BUNDLE_VERSION_RE ]] || bad="${bad} version ${version}, want 1.21.0-<DATE>;"
  [[ $name == "${PKG}.v${version}" ]] || bad="${bad} name ${name}, want ${PKG}.v${version};"
  [[ $ncsv == 1 && $csvname == "$name" ]] || bad="${bad} CSV objects [${csvname}], want exactly ${name};"
  if [[ -z $TEST_BUNDLES && $image != "$ref" ]]; then bad="${bad} image ${image}, want ${ref};"; fi
  if [[ -n $bad ]]; then
    check "bundle-${b}" FAIL "${name}:${bad}"
    return 1
  fi
  check "bundle-${b}" PASS "${name}: package ${pkg}, olm.package version ${version}, CSV object ${csvname}; ${nobj} objects (${ncrd} CRDs); image ${image}"
  echo "$name" >"${RUN_DIR}/${b}.csv"
  echo "$version" >"${RUN_DIR}/${b}.version"
}

# ---------------------------------------------------------------------------------------
# per branch

# Before the edit: the channel's last entry is REPLACES and the single head, its bundle file
# exists, and the new CSV is neither an entry nor a file yet. Otherwise upstream moved: fix the tsv.
entries_before() {  # entries_before <branch> <tree> <render json>
  local b=$1 tree=$2 render=$3 last heads replaces csv
  replaces=$(cat "${RUN_DIR}/${b}.replaces")
  csv=$(cat "${RUN_DIR}/${b}.csv")
  jq -r --arg p "$PKG" --arg c "$CHANNEL" \
    'select(.schema == "olm.channel" and .package == $p and .name == $c) | .entries[].name' "$render" \
    >"${RUN_DIR}/${b}.entries-before"
  last=$(tail -n 1 "${RUN_DIR}/${b}.entries-before")
  if [[ $last != "$replaces" ]]; then
    check "edit-${b}" FAIL "channel ${CHANNEL}'s last entry is '${last}', ${DATA##*/} says REPLACES ${replaces}"
    return 1
  fi
  if ! heads=$(walker heads "$render" "$PKG" "$CHANNEL"); then
    check "edit-${b}" FAIL "heads before the edit: $(echo "$heads" | one_line)"
    return 1
  fi
  if [[ $heads != "$replaces" ]]; then
    check "edit-${b}" FAIL "heads before the edit [$(echo "$heads" | one_line)], want only ${replaces}"
    return 1
  fi
  if [[ ! -f ${tree}/catalog/${PKG}/${replaces}.yaml ]]; then
    check "edit-${b}" FAIL "no bundle file catalog/${PKG}/${replaces}.yaml for REPLACES"
    return 1
  fi
  if grep -qxF "$csv" "${RUN_DIR}/${b}.entries-before"; then
    check "edit-${b}" FAIL "${csv} is already a ${CHANNEL} entry"
    return 1
  fi
  echo "INFO ${b} entries before: $(paste -sd ' ' "${RUN_DIR}/${b}.entries-before")"
}

add_bundle() {  # add_bundle <branch> <tree>: the new bundle file must be the only change
  local b=$1 tree=$2 csv file status
  csv=$(cat "${RUN_DIR}/${b}.csv")
  file=catalog/${PKG}/${csv}.yaml
  if [[ -e ${tree}/${file} ]]; then
    check "bundles-${b}" FAIL "${file} already exists"
    return 1
  fi
  cp "${RUN_DIR}/bundles/${b}.yaml" "${tree}/${file}"
  status=$(git -C "$tree" status --porcelain --untracked-files=all)
  if [[ $status != "?? ${file}" ]]; then
    check "bundles-${b}" FAIL "adding the bundle changed more than ${file}: $(echo "$status" | one_line)"
    return 1
  fi
  check "bundles-${b}" PASS "${file} ($(if [[ -n $TEST_BUNDLES ]]; then echo test-file; else echo 'opm render -o yaml, as hack/add-bundle.sh'; fi))"
}

# The package file is edited as text: two lines are inserted after the last line of the alpha
# channel's `entries:` block, indented like the entries already there; every other line is kept
# byte for byte. yq then proves it: the entries are the old ones plus exactly the new one, and with
# the alpha entries emptied the old and the new file are the same documents.
append_entry() {  # append_entry <csv> <replaces> <in> <out>; exit 3 unless exactly one block with entries
  awk -v ch="$CHANNEL" -v csv="$1" -v rep="$2" '
    function flush(   i, line, is_ch, inblk, last, pfx) {
      is_ch = (schema == "olm.channel" && name == ch)
      inblk = 0; last = 0; pfx = ""
      if (is_ch) {
        for (i = 1; i <= n; i++) {
          line = buf[i]
          if (!inblk && line ~ /^entries:[ \t]*$/) { inblk = 1; blocks++; continue }
          if (inblk) {
            if (line ~ /^[ \t]*$/) continue
            if (line ~ /^[ \t-]/) {
              last = i
              if (pfx == "" && line ~ /^[ \t]*- name:/) { pfx = line; sub(/-.*$/, "", pfx); found = 1 }
              continue
            }
            inblk = 0
          }
        }
        if (last == 0 || !found) bad = 1
      }
      for (i = 1; i <= n; i++) {
        print buf[i]
        if (is_ch && i == last && found) {
          print pfx "- name: " csv
          print pfx "  replaces: " rep
          done++
        }
      }
      n = 0; schema = ""; name = ""
    }
    /^---[ \t]*$/ { flush(); print; next }
    {
      buf[++n] = $0
      if ($0 ~ /^schema:[ \t]/) { v = $0; sub(/^schema:[ \t]*/, "", v); schema = v }
      if ($0 ~ /^name:[ \t]/) { v = $0; sub(/^name:[ \t]*/, "", v); name = v }
    }
    END { flush(); if (done != 1 || blocks != 1 || bad) exit 3 }
  ' "$3" >"$4"
}

edit_package() {  # edit_package <branch> <tree>: append the entry
  local b=$1 tree=$2 file orig csv replaces want got rest_orig rest_new plus minus
  file=${tree}/catalog/${PKG}/${PKG}.yaml
  orig=${RUN_DIR}/${b}.yaml.orig
  csv=$(cat "${RUN_DIR}/${b}.csv")
  replaces=$(cat "${RUN_DIR}/${b}.replaces")
  cp "$file" "$orig"
  # awk ends every line with a newline. If the upstream file has no final newline, count the lines
  # against a copy that has one, so the missing newline is not taken for a changed line.
  cp "$orig" "${orig}.nl"
  if [[ -s $orig && -n $(tail -c 1 "$orig") ]]; then
    echo >>"${orig}.nl"
    echo "INFO ${b}: ${PKG}.yaml has no final newline; the edited file gets one (line counts ignore it)"
  fi
  if ! append_entry "$csv" "$replaces" "$orig" "$file"; then
    check "edit-${b}" FAIL "no single top-level entries: block with '- name:' entries in the ${CHANNEL} channel of ${PKG}.yaml"
    return 1
  fi
  want=$(CH=$CHANNEL yq e -o=json -I=0 'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries' "$orig" \
    | jq -c -S --arg n "$csv" --arg r "$replaces" '. + [{name: $n, replaces: $r}]')
  got=$(CH=$CHANNEL yq e -o=json -I=0 'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries' "$file" | jq -c -S .)
  rest_orig=$(CH=$CHANNEL yq e -o=json -I=0 '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) = []' "$orig")
  rest_new=$(CH=$CHANNEL yq e -o=json -I=0 '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) = []' "$file")
  if [[ $got != "$want" ]]; then
    check "edit-${b}" FAIL "entries after the edit ${got}, want ${want}"
    return 1
  fi
  if [[ $rest_orig != "$rest_new" ]]; then
    check "edit-${b}" FAIL "the edit changed more than the ${CHANNEL} entries: $(diff <(echo "$rest_orig") <(echo "$rest_new") | head -n 4 | one_line)"
    return 1
  fi
  if [[ $(jq -r --arg n "$csv" '.[] | select(.name == $n) | keys | join(",")' <<<"$got") != "name,replaces" ]]; then
    check "edit-${b}" FAIL "the new entry has keys other than name and replaces"
    return 1
  fi
  plus=$(diff "${orig}.nl" "$file" | grep -c '^>' || true)
  minus=$(diff "${orig}.nl" "$file" | grep -c '^<' || true)
  if [[ $plus != 2 || $minus != 0 ]]; then
    check "edit-${b}" FAIL "package file +${plus} -${minus} lines, want +2 -0"
    return 1
  fi
  check "edit-${b}" PASS "appended ${csv} replaces ${replaces} (no skipRange, no skips) after $(wc -l <"${RUN_DIR}/${b}.entries-before" | tr -d ' ') entries; package file +${plus} -${minus} lines"
}

validate_tree() {  # validate_tree <check name> <catalog dir> [<note for a FAIL>]
  local out
  if [[ $HAVE_OPM == 0 ]]; then
    check "$1" SKIP "opm not on PATH (test mode): opm validate ${2##*/} not run"
    return 0
  fi
  if out=$(opm validate "$2" 2>&1); then
    check "$1" PASS "opm validate ${2##*/}"
  else
    echo "$out" | tail -n 20
    check "$1" FAIL "$(echo "$out" | tail -n 3 | one_line)${3:+ (${3})}"
  fi
}

walk_out() {  # walk_out <render json> <head> <installed file>
  local csv args=()
  while read -r csv; do
    if [[ -n $csv ]]; then args+=(--installed "$csv"); fi
  done <"$3"
  walker walk "$1" "$PKG" "$CHANNEL" "$2" ${args[@]+"${args[@]}"}
}

walk_package() {  # walk_package <check name> <render json> <head> <installed file>
  local name=$1 out rc=0 result
  out=$(walk_out "$2" "$3" "$4") || rc=$?
  echo "$out" | grep '^INFO ' || true
  result=$(echo "$out" | tail -n 1)
  if [[ $rc == 0 && $result == 'PASS '* ]]; then
    check "$name" PASS "${result#PASS }; installed: $(joined "$4")"
  else
    check "$name" FAIL "${result#FAIL }"
  fi
}

# The edge the edit adds is the only way to the new head. A copy with the new entry's replaces
# removed has two heads (the old last entry, which nobody replaces any more, and the new CSV):
#   negative-control-replaces-<b>      the walker fails and reports as stranded exactly every older
#                                      entry and every INSTALLED CSV
#   negative-control-replaces-opm-<b>  opm validate rejects the copy with "multiple channel heads"
#                                      (SKIP in test mode without opm, never PASS)
# The copy is rendered by yq in both modes: opm render never runs on a deliberately broken graph.
negative_control_replaces() {  # negative_control_replaces <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-replaces render out rc=0 result csv got want
  csv=$(cat "${RUN_DIR}/${b}.csv")
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  NEW=$csv CH=$CHANNEL yq -i \
    'del(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .replaces)' \
    "${neg}/catalog/${PKG}/${PKG}.yaml"
  if [[ $(NEW=$csv CH=$CHANNEL yq e 'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .replaces' \
      "${neg}/catalog/${PKG}/${PKG}.yaml") != null ]]; then
    check "negative-control-replaces-${b}" FAIL "could not remove the replaces of ${csv}"
    check "negative-control-replaces-opm-${b}" FAIL "no broken copy to validate"
    return 0
  fi

  if [[ $HAVE_OPM == 0 ]]; then
    check "negative-control-replaces-opm-${b}" SKIP "opm not on PATH (test mode): opm validate of the two-heads copy not run"
  elif out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-replaces-opm-${b}" FAIL "opm validate passes on the copy without the replaces (two heads): the control shows nothing"
  elif grep -qi 'multiple channel heads' <<<"$out"; then
    check "negative-control-replaces-opm-${b}" PASS "opm validate rejects the copy without the replaces: $(echo "$out" | grep -i 'multiple channel heads' | head -n 1 | one_line)"
  else
    echo "$out" | tail -n 20
    check "negative-control-replaces-opm-${b}" FAIL "opm validate fails on the copy, but not with 'multiple channel heads': $(echo "$out" | tail -n 3 | one_line)"
  fi

  render=${neg}/render.json
  if ! yq_render "${neg}/catalog/${PKG}" "$render" 2>"${render}.err"; then
    check "negative-control-replaces-${b}" FAIL "yq render: $(tail -n 2 "${render}.err" | one_line)"
    return 0
  fi
  out=$(walk_out "$render" "$csv" "${RUN_DIR}/${b}.installed") || rc=$?
  result=$(echo "$out" | tail -n 1)
  got=$(echo "$out" | awk '$1 == "INFO" && $2 == "stranded" {n = $3; sub(/,$/, "", n); print n}' | LC_ALL=C sort -u | paste -sd ' ' -)
  want=$(cat "${RUN_DIR}/${b}.entries-before" "${RUN_DIR}/${b}.installed" | grep -vxF "$csv" | LC_ALL=C sort -u | paste -sd ' ' - || true)
  if [[ -z $want ]]; then
    check "negative-control-replaces-${b}" FAIL "no older entry and no installed CSV: the control shows nothing"
  elif [[ $rc != 0 && $result == FAIL* && $got == "$want" ]]; then
    check "negative-control-replaces-${b}" PASS "without the replaces the walker fails and reports stranded: ${got}"
  else
    check "negative-control-replaces-${b}" FAIL "walker (exit ${rc}) stranded [${got}], want [${want}]: ${result}"
  fi
}

do_branch() {  # do_branch <branch>
  local b=$1 tree=${RUN_DIR}/${1} render baseline out
  [[ ! -e $tree ]] || die "${tree} exists: catalog-edit.sh runs once per RUN_DIR"
  git clone --quiet --depth 1 --branch "$b" "$CATALOG_REPO" "$tree"
  echo "INFO catalog ${b} $(git -C "$tree" rev-parse HEAD) from ${CATALOG_REPO}"
  [[ -z $(git -C "$tree" status --porcelain --untracked-files=all) ]] || die "fresh clone of ${b} is not clean"
  # Baseline: the unedited branch's own opm validate verdict, so an opm-validate FAIL after the edit
  # says whether the defect predates it (the whole catalog is validated, every package).
  baseline="baseline: opm not run"
  if [[ $HAVE_OPM == 1 ]]; then
    if out=$(opm validate "${tree}/catalog" 2>&1); then
      baseline="baseline: the unedited ${b} passes opm validate"
    else
      baseline="baseline: the unedited ${b} already fails opm validate: $(echo "$out" | tail -n 2 | one_line)"
    fi
  fi
  echo "INFO ${b} ${baseline}"

  render=${RUN_DIR}/render-${b}-before.json
  if ! render_catalog "${tree}/catalog/${PKG}" "$render" 2>"${render}.err"; then
    check "edit-${b}" FAIL "render before the edit: $(tail -n 2 "${render}.err" | one_line)"
    return 0
  fi
  entries_before "$b" "$tree" "$render" || return 0

  add_bundle "$b" "$tree" || return 0
  edit_package "$b" "$tree" || return 0

  validate_tree "opm-validate-${b}" "${tree}/catalog" "$baseline"

  render=${RUN_DIR}/render-${b}-after.json
  if ! render_catalog "${tree}/catalog/${PKG}" "$render" 2>"${render}.err"; then
    check "walk-${b}" FAIL "render: $(tail -n 2 "${render}.err" | one_line)"
  else
    walk_package "walk-${b}" "$render" "$(cat "${RUN_DIR}/${b}.csv")" "${RUN_DIR}/${b}.installed"
  fi

  negative_control_replaces "$b" "$tree"

  # The edit, for the log and for the catalog PRs later.
  git -C "$tree" add -A
  git -C "$tree" diff --cached >"${RUN_DIR}/${b}.diff"
  git -C "$tree" diff --cached --stat | sed "s|^|INFO diff ${b} |"
  git -C "$tree" diff --cached -- "catalog/${PKG}/${PKG}.yaml" | sed "s|^|INFO diff ${b} |"

  if [[ $b == "$IMAGE_BRANCH" ]]; then IMAGE_HEAD=$(cat "${RUN_DIR}/${b}.csv"); fi
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
  if ! render_catalog "${ctx}/catalog" "${RUN_DIR}/render-image-context.json"; then
    check catalog-image FAIL "render of the image context failed"
    return 1
  fi
  got=$(jq -r 'select(.schema == "olm.package") | .name' "${RUN_DIR}/render-image-context.json" | sort | paste -sd ' ' -)
  if [[ $got != "$PKG" ]]; then
    check catalog-image FAIL "image context packages '${got}', want '${PKG}'"
    return 1
  fi
}

image_check() {  # image_check <render json of the image>: package and walk
  local render=$1 got out rc=0
  got=$(jq -r 'select(.schema == "olm.package") | .name' "$render" | sort | paste -sd ' ' -)
  out=$(walk_out "$render" "$IMAGE_HEAD" "${RUN_DIR}/${IMAGE_BRANCH}.installed") || rc=$?
  echo "$out" | grep '^INFO ' | sed 's|^INFO |INFO image |' || true
  if [[ $got == "$PKG" && $rc == 0 ]]; then
    check catalog-image PASS "${CATALOG_IMAGE}: package ${got}; head ${IMAGE_HEAD}; every entry and $(joined "${RUN_DIR}/${IMAGE_BRANCH}.installed") reach the head"
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
    echo "INFO test mode: image context ${ctx} assembled, not built"
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
  local b ok=1
  validate_inputs
  # The image's source branch first, so a wrong IMAGE_BRANCH stops before any clone (do_image checks again).
  if [[ " ${CATALOG_BRANCHES} " != *" ${IMAGE_BRANCH} "* ]]; then
    check catalog-image FAIL "${IMAGE_BRANCH} (the test catalog's source) is not in CATALOG_BRANCHES"
    ok=0
  fi
  for b in $CATALOG_BRANCHES; do
    if branch_data "$b"; then
      bundle_check "$b" || ok=0
    else
      ok=0
    fi
  done
  if [[ $ok == 0 || $FAILS != 0 ]]; then
    echo "INFO catalog-edit: stopped before any edit, ${FAILS} checks failed"
    exit 1
  fi
  for b in $CATALOG_BRANCHES; do
    do_branch "$b"
  done
  do_image
  echo "INFO catalog-edit: ${FAILS} checks failed, ${SKIPS} skipped"
  if [[ $SKIPS != 0 ]]; then
    echo "INFO test mode: ${SKIPS} opm checks SKIP (opm not on PATH); they have not passed, they did not run"
  fi
  if [[ $FAILS != 0 ]]; then exit 1; fi
}

main "$@"
