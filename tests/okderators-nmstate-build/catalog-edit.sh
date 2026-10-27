#!/bin/bash
# MODE=catalog of the okderators-nmstate-build Job (README.md, "MODE=catalog"). build.sh runs it
# as /scripts/catalog-edit.sh in an empty RUN_DIR and copies its CHECK lines into the contract.
#
# What each okderators-catalog-index branch gets is data, not code: catalog-branches.tsv (next to
# this script) has one row per branch with REMOVE (the channel entries, and their bundle files,
# the edit replaces), SKIPS (the new entry's skips) and INSTALLED (CSVs a cluster may run; the
# walker starts from them too).
#
# First, for every branch in CATALOG_BRANCHES, before any clone or edit (a FAIL stops the run):
#   - its catalog-branches.tsv row exists and holds no TO-FILL       CHECK branch-data-<branch>
#   - its bundle (BUNDLES <branch>=<ref@digest>): package kubernetes-nmstate-operator, version
#     4.N.0-<DATE> for release-4.N, name kubernetes-nmstate-operator.v<version>, objects exactly
#     the CRD nmstates.nmstate.io and that CSV                       CHECK bundle-<branch>
#   - no ImageStream object in it                                    CHECK no-imagestream-<branch>
# Then per branch:
#   1. clone it; channel alpha's entries must be exactly REMOVE, each with its bundle file
#   2. negative control: the unedited head bundle fails the no-imagestream check
#                                                      CHECK negative-control-imagestream-<branch>
#   3. add catalog/<package>/<CSV>.yaml, written as hack/add-bundle.sh writes it
#      (`opm render <bundle>@<digest> -o yaml`, echoed to the file)  CHECK bundles-<branch>
#   4. git rm the REMOVE bundle files; the channel's entries become exactly one entry: name <CSV>,
#      skips SKIPS, skipRange '>=4.3.0 <<version>'; nothing else in the package file changes
#                                                                    CHECK edit-<branch>
#   5. opm validate catalog                                          CHECK opm-validate-<branch>
#   6. graph walk (catalog-walk.py): the CSV is the single head and every entry and every
#      INSTALLED CSV reaches it                                      CHECK walk-<branch>
#   7. negative control: with the entry's skipRange removed opm validate still passes, and the
#      walker reports exactly the INSTALLED CSVs that SKIPS does not name as stranded
#                                                      CHECK negative-control-skiprange-<branch>
# Then, only if every check passed: the test catalog image from the edited IMAGE_BRANCH tree,
# package kubernetes-nmstate-operator only, built from that branch's own catalog.Containerfile
# with the opm base image pinned, pushed to CATALOG_IMAGE, rendered back and walked
#                                                                    CHECK catalog-image
#
# Env:
#   CATALOG_BRANCHES     okderators-catalog-index branches, e.g. "release-4.21 release-4.22"
#   BUNDLES              one bundle per branch: "<branch>=<ref@sha256:...> ..."; a ref may keep its tag
#   IMAGE_BRANCH         optional, default release-4.21: the branch the test catalog image comes from;
#                        must be one of CATALOG_BRANCHES
#   RUN_DIR              empty working directory (build.sh: /work/run)
#   CATALOG_IMAGE        push target, set and guarded by build.sh: ${BASE_REGISTRY}/nmstate-catalog:${DATE}
#   CATALOG_REPO         optional, default the upstream GitHub repository
#   CATALOG_BRANCH_DATA  optional, default catalog-branches.tsv next to this script
# Test mode, for a laptop: CATALOG_EDIT_TEST_BUNDLES=<directory with one <branch>.yaml olm.bundle
#   file per branch> replaces the bundle render (no image pulls), BUNDLES is ignored and
#   CATALOG_IMAGE must be empty; the image context is still assembled and validated, but nothing is
#   built or pushed.
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
DATA=${CATALOG_BRANCH_DATA:-${HERE}/catalog-branches.tsv}
PKG=kubernetes-nmstate-operator
CRD_NAME=nmstates.nmstate.io
CHANNEL=alpha
# Lower end of every new entry's skipRange (the upper end is the bundle's own version): the range
# the upstream CSV has carried since 4.3, so any earlier nmstate CSV upgrades to the new entry.
SKIP_FROM='>=4.3.0'
CSV_RE='^kubernetes-nmstate-operator\.v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
# The branch the test catalog image is built from; release-4.22 for a cluster on OKD 4.22.
IMAGE_BRANCH=${IMAGE_BRANCH:-release-4.21}
# catalog.Containerfile builds FROM the mutable :latest; the test image pins it. v1.74.0 is the
# opm build.sh installs (the GitOps Job's pin, 2026-10-20). Digest only: containers/image refuses
# a reference with both a tag and a digest.
UPSTREAM_OPM_FROM='FROM quay.io/operator-framework/opm:latest'
OPM_IMAGE=quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f
# Independent of build.sh's guard: never push anywhere but zot okd-test/.
PUSH_RE='^zot\.apps\.okd\.sudops\.pl/okd-test/[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*$'
# The ImageStream test, shared by no-imagestream and its negative control: the number of
# ImageStream objects among an olm.bundle document's olm.bundle.object properties.
IMAGESTREAM_COUNT='[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson | select(.kind == "ImageStream")] | length'

FAILS=0
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

# ---------------------------------------------------------------------------------------
# inputs

row_count() {  # row_count <branch>
  awk -F '\t' -v b="$1" '$0 !~ /^#/ && $1 == b' "$DATA" | wc -l | tr -d ' '
}

row_field() {  # row_field <branch> <column>: 2 REMOVE, 3 SKIPS, 4 INSTALLED
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
    [[ $b =~ ^release-4\.[0-9]+$ ]] || die "catalog branch '${b}' is not release-4.N"
    [[ $seen != *" ${b} "* ]] || die "catalog branch ${b} is listed twice"
    seen="${seen}${b} "
  done
  if [[ -n $TEST_BUNDLES ]]; then
    [[ -d $TEST_BUNDLES ]] || die "CATALOG_EDIT_TEST_BUNDLES '${TEST_BUNDLES}' is not a directory"
    [[ -z $CATALOG_IMAGE ]] || die "test mode builds no image: CATALOG_IMAGE must be empty"
    echo "INFO test mode: bundles from ${TEST_BUNDLES}, no image build"
  else
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
}

# One catalog-branches.tsv row per branch, no TO-FILL, every name a nmstate CSV name.
branch_data() {  # branch_data <branch>; writes <branch>.remove and <branch>.skips
  local b=$1 n remove skips installed name bad=
  n=$(row_count "$b")
  if [[ $n != 1 ]]; then
    check "branch-data-${b}" FAIL "${n} rows for ${b} in ${DATA##*/}, want 1"
    return 1
  fi
  remove=$(row_field "$b" 2)
  skips=$(row_field "$b" 3)
  installed=$(row_field "$b" 4)
  if [[ -z $remove || -z $skips || -z $installed || "${remove}${skips}${installed}" == *TO-FILL* ]]; then
    check "branch-data-${b}" FAIL "row incomplete: remove '${remove}', skips '${skips}', installed '${installed}'"
    return 1
  fi
  list_lines "$remove" >"${RUN_DIR}/${b}.remove"
  list_lines "$skips" >"${RUN_DIR}/${b}.skips"
  for name in $(cat "${RUN_DIR}/${b}.remove" "${RUN_DIR}/${b}.skips"); do
    [[ $name =~ $CSV_RE ]] || bad="${bad} ${name}"
  done
  if [[ -n $bad ]]; then
    check "branch-data-${b}" FAIL "not a ${PKG} CSV name:${bad}"
    return 1
  fi
  echo "$installed" >"${RUN_DIR}/${b}.installed-templates"
  check "branch-data-${b}" PASS "remove [$(joined "${RUN_DIR}/${b}.remove")]; skips [$(joined "${RUN_DIR}/${b}.skips")]; installed [${installed}]"
}

# INSTALLED templates: {DATE} is the new bundle's DATE, {DATE-1d} / {DATE+1d} that DATE a day
# earlier / later (same time of day). Prints one CSV name per line.
expand_installed() {  # expand_installed <comma-separated templates> <bundle DATE>
  python3 -I -c '
import datetime, re, sys
base = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d-%H%M%S")
def date(m):
    return (base + datetime.timedelta(days=int(m.group(1) or 0))).strftime("%Y-%m-%d-%H%M%S")
for item in sys.argv[1].split(","):
    item = item.strip()
    if item:
        print(re.sub(r"\{DATE(?:([+-][0-9]+)d)?\}", date, item))
' "$1" "$2"
}

objects_json() {  # objects_json <olm.bundle json file>: [{kind, name}] of its bundle objects
  jq -c '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson
          | {kind, name: (.metadata.name // "-")}]' "$1"
}

# Before any clone: what the branch's bundle is. A wrong paste (a bundle of another release or
# package, a bundle with the ImageStream) stops here instead of producing and pushing a catalog.
bundle_check() {  # bundle_check <branch>; writes <branch>.csv, .version, .installed, bundles/<branch>.{yaml,json}
  local b=$1 dir=${RUN_DIR}/bundles minor ref rendered f name pkg version objs kinds crd csvname bdate bad n
  minor=${b#release-}
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
  name=$(jq -r '.name' "${dir}/${b}.json")
  pkg=$(jq -r '.package' "${dir}/${b}.json")
  version=$(jq -r '[.properties[]? | select(.type == "olm.package") | .value.version] | first // "none"' "${dir}/${b}.json")
  objs=$(objects_json "${dir}/${b}.json")
  kinds=$(jq -r '[.[].kind] | sort | join(" ")' <<<"$objs")
  crd=$(jq -r '[.[] | select(.kind == "CustomResourceDefinition") | .name] | join(" ")' <<<"$objs")
  csvname=$(jq -r '[.[] | select(.kind == "ClusterServiceVersion") | .name] | join(" ")' <<<"$objs")
  bad=
  [[ $pkg == "$PKG" ]] || bad="${bad} package ${pkg};"
  [[ $version =~ ^${minor//./\\.}\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] || bad="${bad} version ${version}, want ${minor}.0-<DATE>;"
  [[ $name == "${PKG}.v${version}" ]] || bad="${bad} name ${name}, want ${PKG}.v${version};"
  [[ $kinds == "ClusterServiceVersion CustomResourceDefinition" && $crd == "$CRD_NAME" && $csvname == "$name" ]] \
    || bad="${bad} objects $(jq -r '[.[] | .kind + "/" + .name] | join(" ")' <<<"$objs"), want CustomResourceDefinition/${CRD_NAME} and ClusterServiceVersion/${name};"
  if [[ -n $bad ]]; then
    check "bundle-${b}" FAIL "${name}:${bad}"
  else
    check "bundle-${b}" PASS "${name} version ${version}, objects CustomResourceDefinition/${CRD_NAME} ClusterServiceVersion/${name}"
  fi
  n=$(jq "$IMAGESTREAM_COUNT" "${dir}/${b}.json")
  if [[ $n == 0 ]]; then
    check "no-imagestream-${b}" PASS "no ImageStream object in ${name}"
  else
    check "no-imagestream-${b}" FAIL "${name} has ${n} ImageStream object(s)"
    bad="${bad} ImageStream;"
  fi
  if [[ -n $bad ]]; then return 1; fi
  echo "$name" >"${RUN_DIR}/${b}.csv"
  echo "$version" >"${RUN_DIR}/${b}.version"

  bdate=${version#"${minor}".0-}
  expand_installed "$(cat "${RUN_DIR}/${b}.installed-templates")" "$bdate" >"${RUN_DIR}/${b}.installed"
  bad=$(grep -vE "$CSV_RE" "${RUN_DIR}/${b}.installed" || true)
  if [[ -n $bad || ! -s ${RUN_DIR}/${b}.installed ]]; then
    check "installed-${b}" FAIL "INSTALLED names that are not ${PKG} CSV names after expansion: $(echo "$bad" | one_line)"
    return 1
  fi
  echo "INFO installed ${b}: $(joined "${RUN_DIR}/${b}.installed")"
}

# ---------------------------------------------------------------------------------------
# per branch

entries_before() {  # entries_before <branch> <render json>: alpha's entries must be exactly REMOVE
  local b=$1 render=$2 got want
  got=$(jq -r --arg p "$PKG" --arg c "$CHANNEL" \
    'select(.schema == "olm.channel" and .package == $p and .name == $c) | .entries[].name' "$render" | sort | paste -sd ' ' -)
  want=$(sort "${RUN_DIR}/${b}.remove" | paste -sd ' ' -)
  if [[ $got != "$want" ]]; then
    check "edit-${b}" FAIL "channel ${CHANNEL} entries before the edit are [${got}], ${DATA##*/} says [${want}]"
    return 1
  fi
  echo "INFO ${b} entries before: ${got}"
}

# The unedited head's olm.bundle, through the same IMAGESTREAM_COUNT as no-imagestream: it has to
# find the ImageStream the broken builds shipped, or the check proves nothing.
negative_control_imagestream() {  # negative_control_imagestream <branch> <render json>
  local b=$1 render=$2 heads n
  if ! heads=$(walker heads "$render" "$PKG" "$CHANNEL"); then
    check "negative-control-imagestream-${b}" FAIL "$(echo "$heads" | one_line)"
    return 0
  fi
  if [[ $(echo "$heads" | grep -c .) != 1 ]]; then
    check "negative-control-imagestream-${b}" FAIL "heads before the edit: $(echo "$heads" | one_line), want one"
    return 0
  fi
  n=$(jq -s --arg n "$heads" "[.[] | select(.schema == \"olm.bundle\" and .name == \$n)] | first | ${IMAGESTREAM_COUNT}" "$render")
  if [[ $n =~ ^[1-9][0-9]*$ ]]; then
    check "negative-control-imagestream-${b}" PASS "no-imagestream fails on the unedited head ${heads}: ${n} ImageStream object(s)"
  else
    check "negative-control-imagestream-${b}" FAIL "the unedited head ${heads} has '${n}' ImageStream objects: the control shows nothing"
  fi
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

# The package file is rewritten as text: the alpha channel's `entries:` block is replaced by the
# new one, every other line is kept byte for byte (blank lines after the block included). yq
# then proves it: the entries are exactly the wanted one, and with the alpha entries emptied the
# old and the new file are the same documents.
entries_text() {  # entries_text <branch>
  local b=$1 s
  echo "entries:"
  echo "  - name: $(cat "${RUN_DIR}/${b}.csv")"
  echo "    skips:"
  while read -r s; do
    echo "      - ${s}"
  done <"${RUN_DIR}/${b}.skips"
  echo "    skipRange: '${SKIP_FROM} <$(cat "${RUN_DIR}/${b}.version")'"
}

replace_entries() {  # replace_entries <entries text file> <in> <out>; exit 3 unless exactly one block
  awk -v ch="$CHANNEL" -v entries="$1" '
    function flush(   i, line, is_ch, inblk, pend, e) {
      is_ch = (schema == "olm.channel" && name == ch)
      inblk = 0
      pend = 0
      for (i = 1; i <= n; i++) {
        line = buf[i]
        if (is_ch && !inblk && line ~ /^entries:[ \t]*$/) {
          while ((getline e < entries) > 0) print e
          close(entries)
          inblk = 1
          done++
          continue
        }
        if (inblk) {
          if (line ~ /^[ \t]*$/) { pend++; continue }
          if (line ~ /^[ \t-]/) { pend = 0; continue }
          inblk = 0
          for (; pend > 0; pend--) print ""
        }
        print line
      }
      for (; pend > 0; pend--) print ""
      n = 0; schema = ""; name = ""
    }
    /^---[ \t]*$/ { flush(); print; next }
    {
      buf[++n] = $0
      if ($0 ~ /^schema:[ \t]/) { v = $0; sub(/^schema:[ \t]*/, "", v); schema = v }
      if ($0 ~ /^name:[ \t]/) { v = $0; sub(/^name:[ \t]*/, "", v); name = v }
    }
    END { flush(); if (done != 1) exit 3 }
  ' "$2" >"$3"
}

edit_package() {  # edit_package <branch> <tree>: remove the old bundles, replace the entries
  local b=$1 tree=$2 file orig etext name want got rest_orig rest_new plus minus
  file=${tree}/catalog/${PKG}/${PKG}.yaml
  orig=${RUN_DIR}/${b}.yaml.orig
  etext=${RUN_DIR}/${b}.entries
  cp "$file" "$orig"
  while read -r name; do
    if ! git -C "$tree" rm -q "catalog/${PKG}/${name}.yaml"; then
      check "edit-${b}" FAIL "git rm catalog/${PKG}/${name}.yaml failed (no bundle file for a REMOVE entry)"
      return 1
    fi
  done <"${RUN_DIR}/${b}.remove"
  entries_text "$b" >"$etext"
  if ! replace_entries "$etext" "$orig" "$file"; then
    check "edit-${b}" FAIL "no single top-level entries: block in the ${CHANNEL} channel of ${PKG}.yaml"
    return 1
  fi
  want=$(jq -n -c -S --arg n "$(cat "${RUN_DIR}/${b}.csv")" --arg r "${SKIP_FROM} <$(cat "${RUN_DIR}/${b}.version")" \
    --argjson s "$(jq -R . "${RUN_DIR}/${b}.skips" | jq -s -c .)" '[{name: $n, skips: $s, skipRange: $r}]')
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
  plus=$(diff "$orig" "$file" | grep -c '^>' || true)
  minus=$(diff "$orig" "$file" | grep -c '^<' || true)
  check "edit-${b}" PASS "entries [$(joined "${RUN_DIR}/${b}.remove")] -> $(cat "${RUN_DIR}/${b}.csv") skips [$(joined "${RUN_DIR}/${b}.skips")] skipRange '${SKIP_FROM} <$(cat "${RUN_DIR}/${b}.version")'; bundle files removed: $(sed 's/$/.yaml/' "${RUN_DIR}/${b}.remove" | paste -sd ' ' -); package file +${plus} -${minus} lines"
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

# The case INSTALLED is there for: without the entry's skipRange, opm validate still passes, and
# every INSTALLED CSV that SKIPS does not name (our test-shaped CSVs) has no edge to the head.
negative_control_skiprange() {  # negative_control_skiprange <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-skiprange render out rc=0 result csv got want
  csv=$(cat "${RUN_DIR}/${b}.csv")
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  NEW=$csv CH=$CHANNEL yq -i \
    'del(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .skipRange)' \
    "${neg}/catalog/${PKG}/${PKG}.yaml"
  if [[ $(NEW=$csv CH=$CHANNEL yq e 'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .skipRange' \
      "${neg}/catalog/${PKG}/${PKG}.yaml") != null ]]; then
    check "negative-control-skiprange-${b}" FAIL "could not remove the skipRange of ${csv}"
    return 0
  fi
  if ! out=$(opm validate "${neg}/catalog" 2>&1); then
    check "negative-control-skiprange-${b}" FAIL "opm validate failed without the skipRange: $(echo "$out" | tail -n 2 | one_line)"
    return 0
  fi
  render=${neg}/render.json
  opm render "${neg}/catalog/${PKG}" -o json >"$render"
  out=$(walk_out "$render" "$csv" "${RUN_DIR}/${b}.installed") || rc=$?
  result=$(echo "$out" | tail -n 1)
  got=$(echo "$out" | awk '$1 == "INFO" && $2 == "stranded" {print $3}' | sort | paste -sd ' ' -)
  want=$(grep -vxF -f "${RUN_DIR}/${b}.skips" "${RUN_DIR}/${b}.installed" | grep -vxF "$csv" | sort | paste -sd ' ' - || true)
  if [[ -z $want ]]; then
    check "negative-control-skiprange-${b}" FAIL "every installed CSV is in skips: the control shows nothing"
  elif [[ $rc != 0 && $result == FAIL* && $got == "$want" ]]; then
    check "negative-control-skiprange-${b}" PASS "without skipRange opm validate passes and the walker reports stranded: ${got}"
  else
    check "negative-control-skiprange-${b}" FAIL "walker (exit ${rc}) stranded [${got}], want [${want}]: ${result}"
  fi
}

do_branch() {  # do_branch <branch>
  local b=$1 tree=${RUN_DIR}/${1} render
  [[ ! -e $tree ]] || die "${tree} exists: catalog-edit.sh runs once per RUN_DIR"
  git clone --quiet --depth 1 --branch "$b" "$CATALOG_REPO" "$tree"
  echo "INFO catalog ${b} $(git -C "$tree" rev-parse HEAD) from ${CATALOG_REPO}"
  [[ -z $(git -C "$tree" status --porcelain --untracked-files=all) ]] || die "fresh clone of ${b} is not clean"

  render=${RUN_DIR}/render-${b}-before.json
  opm render "${tree}/catalog/${PKG}" -o json >"$render"
  entries_before "$b" "$render" || return 0
  negative_control_imagestream "$b" "$render"

  add_bundle "$b" "$tree" || return 0
  edit_package "$b" "$tree" || return 0

  validate_tree "opm-validate-${b}" "${tree}/catalog"

  render=${RUN_DIR}/render-${b}-after.json
  if ! opm render "${tree}/catalog/${PKG}" -o json >"$render" 2>"${render}.err"; then
    check "walk-${b}" FAIL "opm render: $(tail -n 2 "${render}.err" | one_line)"
  else
    walk_package "walk-${b}" "$render" "$(cat "${RUN_DIR}/${b}.csv")" "${RUN_DIR}/${b}.installed"
  fi

  negative_control_skiprange "$b" "$tree"

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
  got=$(opm render "${ctx}/catalog" -o json | jq -r 'select(.schema == "olm.package") | .name' | sort | paste -sd ' ' -)
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
    check catalog-image PASS "${CATALOG_IMAGE}: package ${got}; head ${IMAGE_HEAD}; the entry and $(joined "${RUN_DIR}/${IMAGE_BRANCH}.installed") reach the head"
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
  local b ok=1
  validate_inputs
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
  echo "INFO catalog-edit: ${FAILS} checks failed"
  if [[ $FAILS != 0 ]]; then exit 1; fi
}

main "$@"
