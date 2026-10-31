#!/usr/bin/env bash
# submitFineMap.sh
#
# STAGE 3 submission wrapper (optional): the fine map of every slot, one grid_submit.sh production-split job with one subjob
# per slot -- the same granularity and subjob indices as stage 1 (submitMapCreation.sh) and stage 2 (submitPostProcess.sh).
# Payload: fineMapJob.sh (fineMapCreatorGBL.C), with the slot's stage-2 FastTransform as the base correction.
#
# Like stage 2, this does NOT rebuild the slot manifest: it reuses the one stage 1 uploaded (here only to count its lines for
# --prodsplit N), so subjob N is the same slot in all three stages. It needs two pointers:
#   - mapSlots.<STAGE1_JOBNAME_TAG>.tsv          the slots (run, window, residual files), from stage 1
#   - stage2Workdir.<STAGE2_JOBNAME_TAG>.txt     where stage 2 staged each slot's FT_voxRes.<...>.root
# Its own output directory goes to stage3Workdir.<JOBNAME>.txt, for whatever combines the coarse and fine maps later.
#
# CPU: the fine pass fits every track of the window (~40 CPU-s per PbPb TF, measured), far more than stage 1 with its track cap.
# SLOT_LENGTH_MIN of stage 1 therefore also sets the CPU time of a stage-3 subjob; check the first subjobs against the TTL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Config -- edit per submission
# ---------------------------------------------------------------------------
JOBNAME="mapcreation-finemap-v1"            # this stage's OWN job name -- unique per submission
STAGE1_JOBNAME_TAG="mapcreation-v1"          # the JOBNAME stage 1 (submitMapCreation.sh) was submitted with: the slot manifest
STAGE2_JOBNAME_TAG="mapcreation-postprocess-v1" # the JOBNAME stage 2 (submitPostProcess.sh) was submitted with: the base maps
TOPWORKDIR="MapCreation"
PACKAGESPEC="O2::daily-20260730-0000-1"     # needs an O2 build with fineMapCreatorGBL.C, or MACRO_SOURCE=alien
ASUSER="pwg_pp"                             # as stages 1 and 2
MACRO_SOURCE="official"                     # "official": ${O2_ROOT}/share/macro/fineMapCreatorGBL.C from PACKAGESPEC;
                                            # "alien": MACRO_LOCAL_PATH is staged to MACRO_ALIEN_DIR and the jobs use that copy
MACRO_LOCAL_PATH=""                         # only used when MACRO_SOURCE=alien: local path to fineMapCreatorGBL.C
MAX_SLOTS=0                                 # 0: every slot of the manifest; N > 0: only the first N slots (e.g. a first test)

ALIEN_USER_NAME="${ALIEN_USER:-$(whoami)}"
MACRO_ALIEN_DIR_BARE="${MAPCREATION_ALIEN_DIR:-/alice/cern.ch/user/${ALIEN_USER_NAME:0:1}/${ALIEN_USER_NAME}/MapCreation}"
MACRO_ALIEN_DIR="alien://${MACRO_ALIEN_DIR_BARE}"
echo "== Staging area (must match stages 1 and 2): ${MACRO_ALIEN_DIR_BARE} =="
echo "   (derived from AliEn user '${ALIEN_USER_NAME}' -- export ALIEN_USER or MAPCREATION_ALIEN_DIR if that is wrong)"

if [[ "${MACRO_SOURCE}" == "alien" ]]; then
  [[ -n "${MACRO_LOCAL_PATH}" && -f "${MACRO_LOCAL_PATH}" ]] || { echo "ERROR: MACRO_SOURCE=alien needs MACRO_LOCAL_PATH set to a real fineMapCreatorGBL.C (got '${MACRO_LOCAL_PATH}')" >&2; exit 1; }
  echo "== Re-staging macro from ${MACRO_LOCAL_PATH} to ${MACRO_ALIEN_DIR} =="
  alien.py cp -f "file:${MACRO_LOCAL_PATH}" "${MACRO_ALIEN_DIR}/fineMapCreatorGBL.C"
else
  echo "== MACRO_SOURCE=official -- skipping macro upload, jobs will use \${O2_ROOT}/share/macro/fineMapCreatorGBL.C from PACKAGESPEC =="
fi

# the slots: stage 1's manifest, not rebuilt
MANIFEST_NAME="mapSlots.${STAGE1_JOBNAME_TAG}.tsv"
echo "== Fetching existing slot manifest from ${MACRO_ALIEN_DIR}/${MANIFEST_NAME} (NOT rebuilt) =="
TMP_MANIFEST="$(mktemp)"
TMP_SCRIPT="$(mktemp)"
TMP_STAGE2_POINTER="$(mktemp)"
TMP_STAGE3_POINTER="$(mktemp)"
trap 'rm -f "${TMP_MANIFEST}" "${TMP_SCRIPT}" "${TMP_STAGE2_POINTER}" "${TMP_STAGE3_POINTER}"' EXIT
alien.py cp -f "${MACRO_ALIEN_DIR}/${MANIFEST_NAME}" "file:${TMP_MANIFEST}"
N=$(wc -l < "${TMP_MANIFEST}" | tr -d '[:space:]')
echo "N=${N} slot(s)"
[[ "${N}" -gt 0 ]] || { echo "ERROR: ${MANIFEST_NAME} has no lines -- was stage 1 ever submitted with this JOBNAME?" >&2; exit 1; }
# stage 2's subjob directories are zero-padded to this width (same N, same formula as submitPostProcess.sh)
COUNTERWIDTH=${#N}
[[ "${COUNTERWIDTH}" -lt 3 ]] && COUNTERWIDTH=3
# only the first MAX_SLOTS slots: subjob i is still manifest line i (and stage 2's subjob i)
NSUBMIT=${N}
if [[ "${MAX_SLOTS}" -gt 0 && "${MAX_SLOTS}" -lt "${N}" ]]; then
  NSUBMIT=${MAX_SLOTS}
  echo "== MAX_SLOTS=${MAX_SLOTS}: submitting only the first ${NSUBMIT} of ${N} slots =="
fi

# where stage 2 staged the FastTransforms
STAGE2_POINTER_NAME="stage2Workdir.${STAGE2_JOBNAME_TAG}.txt"
echo "== Fetching ${STAGE2_POINTER_NAME} =="
: > "${TMP_STAGE2_POINTER}"
if ! alien.py cp -f "${MACRO_ALIEN_DIR}/${STAGE2_POINTER_NAME}" "file:${TMP_STAGE2_POINTER}" || [[ ! -s "${TMP_STAGE2_POINTER}" ]]; then
  echo "ERROR: could not fetch ${STAGE2_POINTER_NAME} -- was stage 2 actually submitted under STAGE2_JOBNAME_TAG=${STAGE2_JOBNAME_TAG}?" >&2
  exit 1
fi
STAGE2_OUTPUTDIR_BASE=$(head -1 "${TMP_STAGE2_POINTER}")
if [[ "${STAGE2_OUTPUTDIR_BASE}" != /alice/* ]]; then
  echo "ERROR: ${STAGE2_POINTER_NAME} does not contain an absolute /alice/... path: '${STAGE2_OUTPUTDIR_BASE}'" >&2
  exit 1
fi
echo "== STAGE2_OUTPUTDIR_BASE = ${STAGE2_OUTPUTDIR_BASE} =="

sed \
  -e "s/^STAGE1_JOBNAME_TAG=.*/STAGE1_JOBNAME_TAG=${STAGE1_JOBNAME_TAG}/" \
  -e "s|^STAGE2_OUTPUTDIR_BASE=.*|STAGE2_OUTPUTDIR_BASE=${STAGE2_OUTPUTDIR_BASE}|" \
  -e "s/^COUNTERWIDTH=.*/COUNTERWIDTH=${COUNTERWIDTH}/" \
  -e "s/^MACRO_SOURCE=.*/MACRO_SOURCE=${MACRO_SOURCE}/" \
  -e "s|^MACRO_ALIEN_DIR_BARE=.*|MACRO_ALIEN_DIR_BARE=${MACRO_ALIEN_DIR_BARE}|" \
  "${SCRIPT_DIR}/fineMapJob.sh" > "${TMP_SCRIPT}"

GRID_SUBMIT_ARGS=(
  --script "${TMP_SCRIPT}"
  --jobname "${JOBNAME}"
  --topworkdir "${TOPWORKDIR}"
  --prodsplit "${NSUBMIT}"
  --packagespec "${PACKAGESPEC}"
  --asuser "${ASUSER}"
)
echo "== Submitting ${JOBNAME} (prodsplit=${NSUBMIT}, asuser=${ASUSER}) =="
SUBMIT_LOG=$("${O2DPG_ROOT}/GRID/utils/grid_submit.sh" "${GRID_SUBMIT_ARGS[@]}" 2>&1 | tee /dev/stderr)
MY_JOBWORKDIR=$(echo "${SUBMIT_LOG}" | sed -E 's/\x1b\[[0-9;]*m//g' | sed -n "s/^Your job's working directory will be //p" | tail -1)
if [[ -z "${MY_JOBWORKDIR}" ]]; then
  echo "ERROR: could not find \"Your job's working directory will be ...\" in grid_submit.sh's output -- the fine maps could not be located later. Aborting." >&2
  exit 1
fi
echo "== MY_JOBWORKDIR (stage 3's own) = ${MY_JOBWORKDIR} =="
STAGE3_POINTER_NAME="stage3Workdir.${JOBNAME}.txt"
echo "${MY_JOBWORKDIR}" > "${TMP_STAGE3_POINTER}"
alien.py cp -f "file:${TMP_STAGE3_POINTER}" "${MACRO_ALIEN_DIR}/${STAGE3_POINTER_NAME}"
echo "== Uploaded ${STAGE3_POINTER_NAME} =="
