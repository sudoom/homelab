#!/bin/bash
# MODE=catalog of the okderators-descheduler-build Job (README.md, "MODE=catalog"). build.sh runs it as
# /scripts/catalog-edit.sh in an empty RUN_DIR and copies its CHECK lines into the contract. Adapted
# from tests/okderators-oadp-build/catalog-edit.sh: the new entry is added and nothing is removed; new
# here is a branch that has no package yet.
#
# What each okderators-catalog-index branch gets is data, not code: catalog-branches.tsv (next to
# this script) has one row per branch with REPLACES (the new entry's replaces) and INSTALLED (CSVs a
# cluster may run; the walker starts from them too). REPLACES=NONE names a branch without the package.
#
# First, for every branch in CATALOG_BRANCHES, before any clone or edit (a FAIL stops the run):
#   - its catalog-branches.tsv row exists and is complete            CHECK branch-data-<branch>
#   - its bundle (BUNDLES <branch>=<ref@digest>): package cluster-kube-descheduler-operator, version
#     5.4.0-<DATE>, name clusterkubedescheduleroperator.v<version>, that CSV and the CRD among its
#     objects, olm.maxOpenShiftVersion of that branch's next release, relatedImages by digest with no
#     Red Hat registry or quay.io/openshift                          CHECK bundle-<branch>
# Then per branch with a REPLACES:
#   1. clone it; channel alpha's single head must be REPLACES
#   2. add catalog/cluster-kube-descheduler-operator/<CSV>.yaml, written as hack/add-bundle.sh writes
#      it (`opm render <bundle>@<digest> -o yaml`, echoed to the file)
#                                                                    CHECK bundles-<branch>
#   3. the channel's entries gain one entry at the end: name <CSV>, replaces REPLACES, skipRange
#      '>=5.3.0-0 <<version>'; nothing else in the package file changes, no file goes
#                                                                    CHECK edit-<branch>
#   4. opm validate catalog                                          CHECK opm-validate-<branch>
#   5. graph walk (catalog-walk.py): the CSV is the single head and every entry and every INSTALLED
#      CSV reaches it                                                CHECK walk-<branch>
#   6. negative control: without the entry's replaces and skipRange, two heads (REPLACES and the
#      CSV), every other name stranded and opm validate refuses it
#                                                      CHECK negative-control-no-edge-<branch>
#   7. negative control: with only replaces, opm validate passes and exactly the INSTALLED CSVs
#      absent from the channel are stranded, so the skipRange is what serves them
#                                                      CHECK negative-control-replaces-only-<branch>
# Per branch with REPLACES=NONE:
#   1. clone it; catalog/cluster-kube-descheduler-operator/ must be absent, or the branch stops
#   2. add the bundle as above                                       CHECK bundles-<branch>
#   3. write the package file the way the pipeline's scripts/update-catalog-package.sh creates one,
#      its one entry carrying the skipRange and no replaces          CHECK edit-<branch>
#   4. opm validate catalog                                          CHECK opm-validate-<branch>
#   5. graph walk, from the entry alone                              CHECK walk-<branch>
#   6. the entry is the channel's single head, there is nothing to strand
#                                                                    CHECK fresh-head-<branch>
# Then, only if every check passed: the test catalog image from the edited IMAGE_BRANCH tree,
# package cluster-kube-descheduler-operator only, built from that branch's own catalog.Containerfile
# with the opm base image pinned, pushed to CATALOG_IMAGE, rendered back and walked
#                                                                    CHECK catalog-image
#
# Env:
#   CATALOG_BRANCHES     okderators-catalog-index branches, e.g. "release-4.22 release-5.0"
#   BUNDLES              one bundle per branch: "<branch>=<ref@sha256:...> ..."; a ref may keep its tag
#   IMAGE_BRANCH         optional, default release-4.22: the branch the test catalog image comes from;
#                        must be one of CATALOG_BRANCHES
#   RUN_DIR              empty working directory (build.sh: /work/run)
#   CATALOG_IMAGE        push target, set and guarded by build.sh: ${BASE_REGISTRY}/descheduler-catalog:${DATE}
#   CATALOG_REPO         optional, default the upstream GitHub repository
#   CATALOG_BRANCH_DATA  optional, default catalog-branches.tsv next to this script
# Test mode, for a laptop: CATALOG_EDIT_TEST_BUNDLES=<directory with one <branch>.yaml olm.bundle
#   file per branch> replaces the bundle render (no image pulls), BUNDLES is ignored and
#   CATALOG_IMAGE must be empty; the image context is still assembled and validated, but nothing is
#   built or pushed.
#
# Output: CHECK <name> PASS|FAIL <detail>, INFO and ERROR lines. Exit 0 when every check passed,
# 1 otherwise (a hard error exits 1 too, possibly before any CHECK line). Written for bash 3.2
# as well (no associative arrays, namerefs or mapfile), so the same file runs on the Mac. Sourcing
# this file does not run main.
set -euo pipefail

CATALOG_REPO=${CATALOG_REPO:-https://github.com/okd-project/okderators-catalog-index.git}
CATALOG_BRANCHES=${CATALOG_BRANCHES:-}
BUNDLES=${BUNDLES:-}
RUN_DIR=${RUN_DIR:-}
CATALOG_IMAGE=${CATALOG_IMAGE:-}
TEST_BUNDLES=${CATALOG_EDIT_TEST_BUNDLES:-}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA=${CATALOG_BRANCH_DATA:-${HERE}/catalog-branches.tsv}
PKG=cluster-kube-descheduler-operator
CSV_PREFIX=clusterkubedescheduleroperator
CRD_NAME=kubedeschedulers.operator.openshift.io
CHANNEL=alpha
RELEASE=5.4
NONE=NONE
# Lower end of the new entry's skipRange (the upper end is the bundle's own version): the installed
# prerelease 5.3.0-<date> and a test build 5.4.0-<earlier date> can skip straight to this one. The -0
# makes the prereleases of 5.3.0 count: a bare >=5.3.0 sits above them in semver.
SKIP_FROM='>=5.3.0-0'
CSV_RE="^${CSV_PREFIX}\\.v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?\$"
# The branch the test catalog image is built from.
IMAGE_BRANCH=${IMAGE_BRANCH:-release-4.22}
# catalog.Containerfile builds FROM the mutable :latest; the test image pins it. v1.74.0 is the
# opm build.sh installs. Digest only: containers/image refuses a reference with both a tag and a digest.
UPSTREAM_OPM_FROM='FROM quay.io/operator-framework/opm:latest'
OPM_IMAGE=quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f
# Independent of build.sh's guard: never push anywhere but zot okd-test/.
PUSH_RE='^zot\.apps\.okd\.sudops\.pl/okd-test/[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*$'
BAD_REGISTRY_RE='registry\.redhat\.io|registry-proxy|brew\.registry|quay\.io/openshift'

FAILS=0
IMAGE_HEAD=        # the new CSV name on IMAGE_BRANCH
STOPPED=0          # 1: this branch's edit ended at a FAIL, nothing further to do on it

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

joined() {  # joined <file>: its lines joined by ", "; "none" for an empty file
  if [[ -s $1 ]]; then paste -sd ',' "$1" | sed 's/,/, /g'; else echo none; fi
}

# containers/image (opm render, podman) refuses "repo:tag@sha256:..."; keep the digest.
digest_ref() {
  if [[ $1 =~ ^([^@]+):([^/@:]+)@(sha256:[0-9a-f]{64})$ ]]; then
    echo "${BASH_REMATCH[1]}@${BASH_REMATCH[3]}"
  else
    echo "$1"
  fi
}

# release-N.M -> N.(M+1), what kube-descheduler/build.sh sets as olm.maxOpenShiftVersion there.
max_ocp_of() {  # max_ocp_of <branch>
  local v=${1#release-}
  echo "${v%%.*}.$((${v##*.} + 1))"
}

# ---------------------------------------------------------------------------------------
# inputs

row_count() {  # row_count <branch>
  awk -F '\t' -v b="$1" '$0 !~ /^#/ && $1 == b' "$DATA" | wc -l | tr -d ' '
}

row_field() {  # row_field <branch> <column>: 2 REPLACES, 3 INSTALLED
  awk -F '\t' -v b="$1" -v c="$2" '$0 !~ /^#/ && $1 == b {print $c}' "$DATA"
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
    [[ $b =~ ^release-[0-9]+\.[0-9]+$ ]] || die "catalog branch '${b}' is not release-N.M"
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

# One catalog-branches.tsv row per branch: a CSV name in REPLACES with INSTALLED templates, or NONE
# in both.
branch_data() {  # branch_data <branch>; writes <branch>.replaces and <branch>.installed-templates
  local b=$1 n replaces installed
  n=$(row_count "$b")
  if [[ $n != 1 ]]; then
    check "branch-data-${b}" FAIL "${n} rows for ${b} in ${DATA##*/}, want 1"
    return 1
  fi
  replaces=$(row_field "$b" 2)
  installed=$(row_field "$b" 3)
  if [[ -z $replaces || -z $installed ]]; then
    check "branch-data-${b}" FAIL "row incomplete: replaces '${replaces}', installed '${installed}'"
    return 1
  fi
  if [[ $replaces == "$NONE" || $installed == "$NONE" ]]; then
    if [[ $replaces != "$installed" ]]; then
      check "branch-data-${b}" FAIL "replaces '${replaces}', installed '${installed}': ${NONE} goes in both or in neither"
      return 1
    fi
  elif [[ ! $replaces =~ $CSV_RE ]]; then
    check "branch-data-${b}" FAIL "replaces '${replaces}' is not a ${CSV_PREFIX} CSV name"
    return 1
  fi
  echo "$replaces" >"${RUN_DIR}/${b}.replaces"
  echo "$installed" >"${RUN_DIR}/${b}.installed-templates"
  check "branch-data-${b}" PASS "replaces ${replaces}; installed [${installed}]"
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

# Before any clone: what the branch's bundle is. A wrong paste (a bundle of another package, release
# or cap, one that still names a Red Hat registry) stops here instead of producing and pushing a
# catalog. Only the cap tells a release-4.22 build from a main build: both are 5.4.0-<DATE>.
bundle_check() {  # bundle_check <branch>; writes <branch>.csv, .version, .installed, bundles/<branch>.{yaml,json}
  local b=$1 dir=${RUN_DIR}/bundles ref rendered f name pkg version csvname n_crd cap want_cap imgs notdigest badreg bad bdate templates
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
  cap=$(jq -r '[.properties[]? | select(.type == "olm.maxOpenShiftVersion") | .value | tostring] | join(" ")' "${dir}/${b}.json")
  want_cap=$(max_ocp_of "$b")
  jq '[.properties[]? | select(.type == "olm.bundle.object") | .value.data | @base64d | fromjson
       | {kind, name: (.metadata.name // "-")}]' "${dir}/${b}.json" >"${dir}/${b}.objects.json"
  csvname=$(jq -r '[.[] | select(.kind == "ClusterServiceVersion") | .name] | join(" ")' "${dir}/${b}.objects.json")
  n_crd=$(jq --arg n "$CRD_NAME" '[.[] | select(.kind == "CustomResourceDefinition" and .name == $n)] | length' "${dir}/${b}.objects.json")
  imgs=$(jq -r '.relatedImages[]?.image' "${dir}/${b}.json")
  # the bundle's own entry may carry a tag when it was rendered by tag; every other must be a digest
  notdigest=$(echo "$imgs" | grep -v '@sha256:[0-9a-f]\{64\}$' | grep -vxF "$(jq -r '.image' "${dir}/${b}.json")" || true)
  badreg=$(echo "$imgs" | grep -E "$BAD_REGISTRY_RE" || true)
  bad=
  [[ $pkg == "$PKG" ]] || bad="${bad} package ${pkg};"
  [[ $version =~ ^${RELEASE//./\\.}\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] || bad="${bad} version ${version}, want ${RELEASE}.0-<DATE>;"
  [[ $name == "${CSV_PREFIX}.v${version}" ]] || bad="${bad} name ${name}, want ${CSV_PREFIX}.v${version};"
  [[ $csvname == "$name" ]] || bad="${bad} CSV objects '${csvname}', want ${name};"
  [[ $n_crd == 1 ]] || bad="${bad} ${n_crd} CRDs ${CRD_NAME}, want 1;"
  [[ $cap == "$want_cap" ]] || bad="${bad} olm.maxOpenShiftVersion '${cap}', want ${want_cap} on ${b};"
  [[ -n $imgs ]] || bad="${bad} no relatedImages;"
  [[ -z $notdigest ]] || bad="${bad} relatedImages not by digest: $(echo "$notdigest" | one_line);"
  [[ -z $badreg ]] || bad="${bad} relatedImages from a forbidden registry: $(echo "$badreg" | one_line);"
  if [[ -n $bad ]]; then
    check "bundle-${b}" FAIL "${name}:${bad}"
    return 1
  fi
  check "bundle-${b}" PASS "${name} version ${version}, the CSV and the CRD, olm.maxOpenShiftVersion ${cap}, relatedImages by digest"
  echo "$name" >"${RUN_DIR}/${b}.csv"
  echo "$version" >"${RUN_DIR}/${b}.version"

  templates=$(cat "${RUN_DIR}/${b}.installed-templates")
  if [[ $templates == "$NONE" ]]; then
    : >"${RUN_DIR}/${b}.installed"
    echo "INFO installed ${b}: none"
    return 0
  fi
  bdate=${version#"${RELEASE}".0-}
  expand_installed "$templates" "$bdate" >"${RUN_DIR}/${b}.installed"
  bad=$(grep -vE "$CSV_RE" "${RUN_DIR}/${b}.installed" || true)
  if [[ -n $bad || ! -s ${RUN_DIR}/${b}.installed ]]; then
    check "installed-${b}" FAIL "INSTALLED names that are not ${CSV_PREFIX} CSV names after expansion: $(echo "$bad" | one_line)"
    return 1
  fi
  echo "INFO installed ${b}: $(joined "${RUN_DIR}/${b}.installed")"
}

# ---------------------------------------------------------------------------------------
# per branch

head_before() {  # head_before <branch> <render json>: alpha's single head must be REPLACES
  local b=$1 render=$2 heads want
  want=$(cat "${RUN_DIR}/${b}.replaces")
  if ! heads=$(walker heads "$render" "$PKG" "$CHANNEL"); then
    check "edit-${b}" FAIL "before the edit: $(echo "$heads" | one_line)"
    return 1
  fi
  if [[ $heads != "$want" ]]; then
    check "edit-${b}" FAIL "channel ${CHANNEL} heads before the edit are [$(echo "$heads" | one_line)], ${DATA##*/} says [${want}]"
    return 1
  fi
  echo "INFO ${b} head before: ${heads}"
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

# The package file is edited as text: the new entry goes at the end of the alpha channel's
# `entries:` block, every other line is kept byte for byte (blank lines after the block included; a
# last line that lacks its newline gains it). yq then proves it: the entries are the old ones plus
# the new one, and with the alpha entries emptied the old and the new file are the same documents.
entry_text() {  # entry_text <branch>
  local b=$1
  echo "  - name: $(cat "${RUN_DIR}/${b}.csv")"
  echo "    replaces: $(cat "${RUN_DIR}/${b}.replaces")"
  echo "    skipRange: '${SKIP_FROM} <$(cat "${RUN_DIR}/${b}.version")'"
}

append_entry() {  # append_entry <entry text file> <in> <out>; exit 3 unless exactly one block
  awk -v ch="$CHANNEL" -v entry="$1" '
    function emit_entry(   e) {
      while ((getline e < entry) > 0) print e
      close(entry)
    }
    function flush(   i, line, is_ch, inblk, pend) {
      is_ch = (schema == "olm.channel" && name == ch)
      inblk = 0
      pend = 0
      for (i = 1; i <= n; i++) {
        line = buf[i]
        if (is_ch && !inblk && line ~ /^entries:[ \t]*$/) {
          print line
          inblk = 1
          done++
          continue
        }
        if (inblk) {
          if (line ~ /^[ \t]*$/) { pend++; continue }
          if (line ~ /^[ \t-]/) {
            for (; pend > 0; pend--) print ""
            print line
            continue
          }
          emit_entry()
          inblk = 0
          for (; pend > 0; pend--) print ""
        }
        print line
      }
      if (inblk) emit_entry()
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

channel_entries() {  # channel_entries <package file>: the alpha entries as sorted-key JSON
  CH=$CHANNEL yq e -o=json -I=0 'select(.schema == "olm.channel" and .name == strenv(CH)) | .entries' "$1" | jq -c -S .
}

channel_rest() {  # channel_rest <package file>: everything but the alpha entries
  CH=$CHANNEL yq e -o=json -I=0 '(select(.schema == "olm.channel" and .name == strenv(CH)) | .entries) = []' "$1"
}

edit_package() {  # edit_package <branch> <tree>: add the entry; nothing else may change
  local b=$1 tree=$2 file orig etext want got rest_orig rest_new csv replaces version range deleted
  file=${tree}/catalog/${PKG}/${PKG}.yaml
  orig=${RUN_DIR}/${b}.yaml.orig
  etext=${RUN_DIR}/${b}.entry
  csv=$(cat "${RUN_DIR}/${b}.csv")
  replaces=$(cat "${RUN_DIR}/${b}.replaces")
  version=$(cat "${RUN_DIR}/${b}.version")
  range="${SKIP_FROM} <${version}"
  cp "$file" "$orig"
  entry_text "$b" >"$etext"
  if ! append_entry "$etext" "$orig" "$file"; then
    check "edit-${b}" FAIL "no single top-level entries: block in the ${CHANNEL} channel of ${PKG}.yaml"
    return 1
  fi
  want=$(channel_entries "$orig" | jq -c -S --arg n "$csv" --arg p "$replaces" --arg r "$range" '. + [{name: $n, replaces: $p, skipRange: $r}]')
  if ! got=$(channel_entries "$file"); then
    check "edit-${b}" FAIL "the edited ${PKG}.yaml does not parse"
    return 1
  fi
  rest_orig=$(channel_rest "$orig")
  rest_new=$(channel_rest "$file")
  if [[ $got != "$want" ]]; then
    check "edit-${b}" FAIL "entries after the edit ${got}, want ${want}"
    return 1
  fi
  if [[ $rest_orig != "$rest_new" ]]; then
    check "edit-${b}" FAIL "the edit changed more than the ${CHANNEL} entries: $(diff <(echo "$rest_orig") <(echo "$rest_new") | head -n 4 | one_line)"
    return 1
  fi
  deleted=$(git -C "$tree" status --porcelain --untracked-files=all | grep -c '^ *D' || true)
  if [[ $deleted != 0 ]]; then
    check "edit-${b}" FAIL "${deleted} files deleted: nothing may be removed"
    return 1
  fi
  check "edit-${b}" PASS "entry ${csv} replaces ${replaces} skipRange '${range}' added; $(echo "$got" | jq 'length') entries, the old ones unchanged; no file removed"
}

# A branch without the package: the file update-catalog-package.sh creates for a fresh package, one
# olm.package and one olm.channel document. Its entry carries the skipRange for a cluster that moves
# here with an older CSV installed, and no replaces, which would name a CSV this channel never held.
create_package() {  # create_package <branch> <tree>: the package file, then yq reads it back
  local b=$1 tree=$2 file csv version range got want status want_status
  file=${tree}/catalog/${PKG}/${PKG}.yaml
  csv=$(cat "${RUN_DIR}/${b}.csv")
  version=$(cat "${RUN_DIR}/${b}.version")
  range="${SKIP_FROM} <${version}"
  cat >"$file" <<EOF
---
schema: olm.package
name: ${PKG}
defaultChannel: ${CHANNEL}
---
schema: olm.channel
package: ${PKG}
name: ${CHANNEL}
entries:
  - name: ${csv}
    skipRange: '${range}'
EOF
  want=$(jq -c -S -n --arg p "$PKG" --arg c "$CHANNEL" --arg n "$csv" --arg r "$range" \
    '[{defaultChannel: $c, name: $p, schema: "olm.package"},
      {entries: [{name: $n, skipRange: $r}], name: $c, package: $p, schema: "olm.channel"}]')
  got=$(yq e -o=json -I=0 '.' "$file" | jq -c -s -S .)
  want_status=$(printf '?? catalog/%s/%s\n?? catalog/%s/%s.yaml' "$PKG" "${csv}.yaml" "$PKG" "$PKG" | LC_ALL=C sort)
  status=$(git -C "$tree" status --porcelain --untracked-files=all | LC_ALL=C sort)
  if [[ $got != "$want" ]]; then
    check "edit-${b}" FAIL "package file reads ${got}, want ${want}"
    return 1
  fi
  if [[ $status != "$want_status" ]]; then
    check "edit-${b}" FAIL "the new package changed more than its two files: $(echo "$status" | one_line)"
    return 1
  fi
  check "edit-${b}" PASS "new package catalog/${PKG}/: channel ${CHANNEL}, one entry ${csv} skipRange '${range}', no replaces; no other file changed"
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

negative_tree() {  # negative_tree <dir> <tree> <csv> <yq path to delete, under the entry>: the copy
  local neg=$1 tree=$2 csv=$3 fields=$4
  mkdir -p "$neg"
  cp -R "${tree}/catalog" "${neg}/catalog"
  NEW=$csv CH=$CHANNEL yq -i \
    "del(select(.schema == \"olm.channel\" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | ${fields})" \
    "${neg}/catalog/${PKG}/${PKG}.yaml"
}

entry_field() {  # entry_field <package file> <csv> <field>
  NEW=$2 CH=$CHANNEL yq e "select(.schema == \"olm.channel\" and .name == strenv(CH)) | .entries[] | select(.name == strenv(NEW)) | .$3" "$1"
}

stranded_names() {  # the names the walker reported stranded, sorted; "name," without a note
  awk '$1 == "INFO" && $2 == "stranded" {n = $3; sub(/,$/, "", n); print n}' | LC_ALL=C sort | paste -sd ' ' -
}

entry_names() {  # entry_names <render json>
  jq -r --arg p "$PKG" --arg c "$CHANNEL" 'select(.schema == "olm.channel" and .package == $p and .name == $c) | .entries[].name' "$1"
}

# Without either edge the bundle is just a second head: the installed head is stranded, and so is
# everything that ends on it. This is the graph a bundle added on its own would have.
negative_control_no_edge() {  # negative_control_no_edge <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-no-edge name render out rc=0 result csv replaces heads got want vout vrc=0
  name="negative-control-no-edge-${b}"
  csv=$(cat "${RUN_DIR}/${b}.csv")
  replaces=$(cat "${RUN_DIR}/${b}.replaces")
  negative_tree "$neg" "$tree" "$csv" '(.replaces, .skipRange)'
  if [[ $(entry_field "${neg}/catalog/${PKG}/${PKG}.yaml" "$csv" replaces) != null \
    || $(entry_field "${neg}/catalog/${PKG}/${PKG}.yaml" "$csv" skipRange) != null ]]; then
    check "$name" FAIL "could not remove the edges of ${csv}"
    return 0
  fi
  vout=$(opm validate "${neg}/catalog" 2>&1) || vrc=$?
  render=${neg}/render.json
  opm render "${neg}/catalog/${PKG}" -o json >"$render"
  heads=$(walker heads "$render" "$PKG" "$CHANNEL" | LC_ALL=C sort | paste -sd ' ' -)
  out=$(walk_out "$render" "$csv" "${RUN_DIR}/${b}.installed") || rc=$?
  result=$(echo "$out" | tail -n 1)
  got=$(echo "$out" | stranded_names)
  want=$( { entry_names "$render"; cat "${RUN_DIR}/${b}.installed"; } | grep -vxF "$csv" | LC_ALL=C sort -u | paste -sd ' ' -)
  if [[ $vrc == 0 ]]; then
    check "$name" FAIL "opm validate passed a channel with two heads: the control shows nothing"
  elif [[ $heads != "$(printf '%s\n%s\n' "$replaces" "$csv" | LC_ALL=C sort | paste -sd ' ' -)" ]]; then
    check "$name" FAIL "heads [${heads}], want ${replaces} and ${csv}"
  elif [[ $rc != 0 && $result == FAIL* && $got == "$want" && " ${got} " == *" ${replaces} "* ]]; then
    check "$name" PASS "without replaces and skipRange: two heads [${heads}], ${replaces} stranded with the rest [${got}]; opm validate refuses it: $(echo "$vout" | tail -n 1 | cut -c1-120)"
  else
    check "$name" FAIL "walker (exit ${rc}) stranded [${got}], want [${want}]: ${result}"
  fi
}

# With only replaces the channel is valid and the installed entries reach the head. What is left
# stranded is what skipRange is for: a CSV the channel does not list, our test build at the later
# move to the official one. opm validate parses a skipRange but never evaluates it, so it cannot tell.
negative_control_replaces_only() {  # negative_control_replaces_only <branch> <tree>
  local b=$1 tree=$2 neg=${RUN_DIR}/${1}-negative-replaces-only name render out rc=0 result csv got want
  name="negative-control-replaces-only-${b}"
  csv=$(cat "${RUN_DIR}/${b}.csv")
  negative_tree "$neg" "$tree" "$csv" '.skipRange'
  if [[ $(entry_field "${neg}/catalog/${PKG}/${PKG}.yaml" "$csv" skipRange) != null ]]; then
    check "$name" FAIL "could not remove the skipRange of ${csv}"
    return 0
  fi
  if ! out=$(opm validate "${neg}/catalog" 2>&1); then
    check "$name" FAIL "opm validate failed without the skipRange: $(echo "$out" | tail -n 2 | one_line)"
    return 0
  fi
  render=${neg}/render.json
  opm render "${neg}/catalog/${PKG}" -o json >"$render"
  out=$(walk_out "$render" "$csv" "${RUN_DIR}/${b}.installed") || rc=$?
  result=$(echo "$out" | tail -n 1)
  got=$(echo "$out" | stranded_names)
  entry_names "$render" | LC_ALL=C sort >"${neg}/entries.txt"
  want=$(LC_ALL=C sort -u "${RUN_DIR}/${b}.installed" | LC_ALL=C comm -23 - "${neg}/entries.txt" | paste -sd ' ' -)
  if [[ -z $want ]]; then
    check "$name" FAIL "INSTALLED names no CSV absent from the channel: the control shows nothing, the row needs the test-shaped CSV"
  elif [[ $rc != 0 && $result == FAIL* && $got == "$want" ]]; then
    check "$name" PASS "with only replaces opm validate passes and the walker reports stranded: ${got}"
  else
    check "$name" FAIL "walker (exit ${rc}) stranded [${got}], want [${want}]: ${result}"
  fi
}

# A fresh package has no old head to strand, so instead of the negative controls: the one entry is
# the single head, and it names no predecessor. opm-validate-<branch> is the other half.
check_fresh_head() {  # check_fresh_head <branch> <render json>
  local b=$1 render=$2 csv heads replaces name="fresh-head-${1}"
  csv=$(cat "${RUN_DIR}/${b}.csv")
  if ! heads=$(walker heads "$render" "$PKG" "$CHANNEL"); then
    check "$name" FAIL "$(echo "$heads" | one_line)"
    return 0
  fi
  replaces=$(jq -r --arg p "$PKG" --arg c "$CHANNEL" --arg n "$csv" \
    'select(.schema == "olm.channel" and .package == $p and .name == $c) | .entries[] | select(.name == $n) | .replaces // "none"' "$render")
  if [[ $heads == "$csv" && $replaces == none && $(entry_names "$render" | wc -l | tr -d ' ') == 1 ]]; then
    check "$name" PASS "${csv} is the channel's one entry and single head, no replaces"
  else
    check "$name" FAIL "heads [$(echo "$heads" | one_line)], replaces ${replaces}, entries [$(entry_names "$render" | one_line)]; want the one entry ${csv} with no replaces"
  fi
}

walk_edited() {  # walk_edited <branch> <tree>: render-<branch>-after.json and walk-<branch>; returns 1 if it did not render
  local b=$1 tree=$2 render=${RUN_DIR}/render-${1}-after.json
  if ! opm render "${tree}/catalog/${PKG}" -o json >"$render" 2>"${render}.err"; then
    check "walk-${b}" FAIL "opm render: $(tail -n 2 "${render}.err" | one_line)"
    return 1
  fi
  walk_package "walk-${b}" "$render" "$(cat "${RUN_DIR}/${b}.csv")" "${RUN_DIR}/${b}.installed"
}

edit_existing() {  # edit_existing <branch> <tree>: REPLACES names the head
  local b=$1 tree=$2 render=${RUN_DIR}/render-${1}-before.json
  if [[ ! -d ${tree}/catalog/${PKG} ]]; then
    check "edit-${b}" FAIL "catalog/${PKG}/ does not exist on ${b}, ${DATA##*/} says its head is $(cat "${RUN_DIR}/${b}.replaces")"
    STOPPED=1
    return 0
  fi
  opm render "${tree}/catalog/${PKG}" -o json >"$render"
  head_before "$b" "$render" || { STOPPED=1; return 0; }
  add_bundle "$b" "$tree" || { STOPPED=1; return 0; }
  edit_package "$b" "$tree" || { STOPPED=1; return 0; }
  validate_tree "opm-validate-${b}" "${tree}/catalog"
  walk_edited "$b" "$tree" || true
  negative_control_no_edge "$b" "$tree"
  negative_control_replaces_only "$b" "$tree"
}

edit_fresh() {  # edit_fresh <branch> <tree>: REPLACES=NONE, the branch must not have the package
  local b=$1 tree=$2
  if [[ -e ${tree}/catalog/${PKG} ]]; then
    check "edit-${b}" FAIL "${DATA##*/} says ${b} has no package, but catalog/${PKG}/ exists: read the branch again and fix the row"
    STOPPED=1
    return 0
  fi
  mkdir -p "${tree}/catalog/${PKG}"
  add_bundle "$b" "$tree" || { STOPPED=1; return 0; }
  create_package "$b" "$tree" || { STOPPED=1; return 0; }
  validate_tree "opm-validate-${b}" "${tree}/catalog"
  if walk_edited "$b" "$tree"; then
    check_fresh_head "$b" "${RUN_DIR}/render-${b}-after.json"
  fi
}

do_branch() {  # do_branch <branch>
  local b=$1 tree=${RUN_DIR}/${1}
  [[ ! -e $tree ]] || die "${tree} exists: catalog-edit.sh runs once per RUN_DIR"
  git clone --quiet --depth 1 --branch "$b" "$CATALOG_REPO" "$tree"
  echo "INFO catalog ${b} $(git -C "$tree" rev-parse HEAD) from ${CATALOG_REPO}"
  [[ -z $(git -C "$tree" status --porcelain --untracked-files=all) ]] || die "fresh clone of ${b} is not clean"

  STOPPED=0
  if [[ $(cat "${RUN_DIR}/${b}.replaces") == "$NONE" ]]; then
    edit_fresh "$b" "$tree"
  else
    edit_existing "$b" "$tree"
  fi
  if [[ $STOPPED == 1 ]]; then return 0; fi

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
    check catalog-image PASS "${CATALOG_IMAGE}: package ${got}; head ${IMAGE_HEAD}; every entry and installed [$(joined "${RUN_DIR}/${IMAGE_BRANCH}.installed")] reach the head"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
