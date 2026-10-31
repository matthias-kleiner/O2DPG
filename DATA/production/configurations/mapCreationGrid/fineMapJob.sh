#!/usr/bin/env bash
# fineMapJob.sh — TPC fine map of one time slot per GRID job (STAGE 3, optional).
#
# Runs fineMapCreatorGBL.C on the same slot as stage 1 / stage 2: the slot's residual files from the stage-1 manifest
# (mapSlots.<STAGE1_JOBNAME_TAG>.tsv, line SUBJOBID), the same TF time window as the coarse map (the manifest's window bounds
# become the macro's firstTFTime / lastTFTime, the cut staticMapCreatorCPM.C applies), and the slot's stage-2 FastTransform
# (FT_voxRes.<...>.root, found via STAGE2_OUTPUTDIR_BASE like stage 2 finds stage 1) as the base correction of the clusters. Per
# track a TPC-only GBL fit; the voxel map of the unbiased residuals is what the coarse map leaves: the fine map of this slot.
# Its output is staged to this job's own ${ALIEN_JDL_OUTPUTDIR} as <stage-1 stem>.fine.root, next to nothing else -- the
# coarse map of the same slot stays where stage 2 put it; the subjob index identifies the slot in all three stages.
#
# Submitted by submitFineMap.sh, which substitutes the placeholder lines below (STAGE1_JOBNAME_TAG, STAGE2_OUTPUTDIR_BASE,
# COUNTERWIDTH, MACRO_SOURCE, MACRO_ALIEN_DIR_BARE) -- don't hand-edit those here. Local single-slot test:
#   SUBJOBID=1 MACRO_ALIEN_DIR_BARE=... ./fineMapJob.sh     (after setting the placeholders by hand)
#
# Missing stage-2 output for this slot (stage 1 marked it badCalib_, or stage 1 / 2 failed or have not run yet): logged and
# exit 0, as stage 2 does -- resubmit this subjob once stage 2 has produced the FastTransform.
STAGE1_JOBNAME_TAG=default
STAGE2_OUTPUTDIR_BASE=
COUNTERWIDTH=3
MACRO_SOURCE=official
MACRO_ALIEN_DIR_BARE=${MACRO_ALIEN_DIR_BARE:-}
#JDL_OUTPUT=*.log@disk=2,*.txt@disk=2
#JDL_REQUIRE={member(other.GridPartitions,"multicore_8") && (other.CE != "ALICE::NIHAM::PBS64") && (other.CE != "ALICE::KISTI_GSDC::LCG") && (other.CE != "ALICE::SaoPaulo::LCG")};

set -e

# same xrootd timeouts as stage 1: a stalled replica fails fast instead of idling into AliEn's CPU watchdog
export XRD_TIMEOUTRESOLUTION=15
export XRD_CONNECTIONWINDOW=30
export XRD_CONNECTIONRETRY=2
export XRD_REQUESTTIMEOUT=120
export XRD_STREAMTIMEOUT=120
export XRD_STREAMERRORWINDOW=0

: "${MACRO_ALIEN_DIR_BARE:?MACRO_ALIEN_DIR_BARE is empty -- the submission wrapper normally substitutes it. For a standalone/local run, export it first, e.g. MACRO_ALIEN_DIR_BARE=/alice/cern.ch/user/<initial>/<user>/MapCreation}"
: "${STAGE2_OUTPUTDIR_BASE:?STAGE2_OUTPUTDIR_BASE is empty -- the submission wrapper normally substitutes it from stage2Workdir.<STAGE2_JOBNAME_TAG>.txt}"
MACRO_ALIEN_DIR="alien://${MACRO_ALIEN_DIR_BARE}"

if [[ "${MACRO_SOURCE}" == "official" ]]; then
  : "${O2_ROOT:?O2_ROOT is not set -- MACRO_SOURCE=official needs the O2 package loaded via --packagespec}"
  MACRO_PATH="${O2_ROOT}/share/macro/fineMapCreatorGBL.C"
  if [[ ! -f "${MACRO_PATH}" ]]; then
    echo "ERROR: MACRO_SOURCE=official but ${MACRO_PATH} does not exist -- this job's --packagespec does not include fineMapCreatorGBL.C yet. Use MACRO_SOURCE=alien until a packagespec with it is published." >&2
    exit 1
  fi
else
  alien.py cp -f "${MACRO_ALIEN_DIR}/fineMapCreatorGBL.C" file:./fineMapCreatorGBL.C
  MACRO_PATH="./fineMapCreatorGBL.C"
fi

# GBL and Eigen are not on ROOT's paths in the O2 environment (their modules set none): the headers for ACLiC, libGBL for the
# macro's R__LOAD_LIBRARY(libGBL)
GBL_DIR="${GBL_ROOT:-}"
if [[ -z "${GBL_DIR}" && -n "${BASEDIR:-}" ]]; then
  GBL_MODULE=$(tr ':' '\n' <<< "${LOADEDMODULES:-}" | grep '^GBL/' | head -1)
  [[ -n "${GBL_MODULE}" ]] && GBL_DIR="${BASEDIR}/${GBL_MODULE}"
fi
EIGEN_DIR="${EIGEN3_ROOT:-}"
if [[ -z "${EIGEN_DIR}" && -n "${BASEDIR:-}" ]]; then
  EIGEN_DIR=$(ls -d "${BASEDIR}"/Eigen3/* 2>/dev/null | tail -1)
fi
if [[ ! -f "${GBL_DIR}/include/GblTrajectory.h" || ! -f "${EIGEN_DIR}/include/eigen3/Eigen/Core" ]]; then
  echo "ERROR: GBL headers (GBL_DIR='${GBL_DIR}') or Eigen headers (EIGEN_DIR='${EIGEN_DIR}') not found -- set GBL_ROOT / EIGEN3_ROOT" >&2
  exit 1
fi
export ROOT_INCLUDE_PATH="${GBL_DIR}/include:${EIGEN_DIR}/include/eigen3${ROOT_INCLUDE_PATH:+:${ROOT_INCLUDE_PATH}}"
export LD_LIBRARY_PATH="${GBL_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# GBL >= V04 includes Mille's headers (Mille/MilleFactory.h) and libGBL needs libMille2
MILLE_DIR="${MILLE_ROOT:-}"
if [[ -z "${MILLE_DIR}" && -n "${BASEDIR:-}" ]]; then
  MILLE_MODULE=$(tr ':' '\n' <<< "${LOADEDMODULES:-}" | grep '^Mille/' | head -1)
  [[ -n "${MILLE_MODULE}" ]] && MILLE_DIR="${BASEDIR}/${MILLE_MODULE}"
fi
if grep -q '#include "Mille/' "${GBL_DIR}/include/GblTrajectory.h"; then
  if [[ ! -f "${MILLE_DIR}/include/Mille/MilleFactory.h" ]]; then
    echo "ERROR: GBL includes Mille's headers, but Mille was not found (MILLE_DIR='${MILLE_DIR}') -- set MILLE_ROOT" >&2
    exit 1
  fi
  export ROOT_INCLUDE_PATH="${MILLE_DIR}/include:${ROOT_INCLUDE_PATH}"
  export LD_LIBRARY_PATH="${MILLE_DIR}/lib:${LD_LIBRARY_PATH}"
fi
echo "GBL: ${GBL_DIR}, Eigen: ${EIGEN_DIR}, Mille: ${MILLE_DIR:-not needed}"

# this subjob's slot: the same manifest line as stage 1 / stage 2
alien.py cp -f "${MACRO_ALIEN_DIR}/mapSlots.${STAGE1_JOBNAME_TAG}.tsv" file:./mapSlots.tsv
SUBJOBID="${ALIEN_O2DPG_GRIDSUBMIT_SUBJOBID:-${SUBJOBID:-}}"
: "${SUBJOBID:?SUBJOBID must be set (via ALIEN_O2DPG_GRIDSUBMIT_SUBJOBID on GRID, or the SUBJOBID env var for --local testing)}"
LINE=$(sed -n "${SUBJOBID}p" mapSlots.tsv)
if [[ -z "${LINE}" ]]; then
  echo "ERROR: mapSlots.tsv has no line ${SUBJOBID}" >&2
  exit 1
fi
IFS=$'\t' read -r RUN WIN_IDX WIN_COUNT firstTSIter lastTSIter PATHS <<< "${LINE}"
for v in RUN WIN_IDX WIN_COUNT firstTSIter lastTSIter; do
  if [[ ! "${!v}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: manifest line ${SUBJOBID} field ${v}='${!v}' is not numeric -- expected 6 tab-separated fields <run> <winIdx> <winCount> <winFirstTS> <winLastTS> <paths>" >&2
    exit 1
  fi
done
[[ -n "${PATHS}" ]] || { echo "ERROR: manifest line ${SUBJOBID} carries no file paths" >&2; exit 1; }
SLOT_LIST="slotlist_${SUBJOBID}.txt"
tr ',' '\n' <<< "${PATHS}" > "${SLOT_LIST}"
nSlotFiles=$(wc -l < "${SLOT_LIST}" | tr -d '[:space:]')
echo "Fine map of slot ${SUBJOBID}: run ${RUN}, window ${WIN_IDX}/${WIN_COUNT} [${firstTSIter},${lastTSIter}], ${nSlotFiles} file(s)"

# ---------------------------------------------------------------------------
# Physics / processing parameters (a hand-edit here is a normal, permanent change)
# ---------------------------------------------------------------------------
Y2XBINNING="20"                     # the voxel grid of the fine map (stage 1's grid)
Z2XBINNING="28"
MAX_Z2X=1.4
TRACK_SOURCES="ITS-TPC,ITS-TPC-TRD,ITS-TPC-TOF,ITS-TPC-TRD-TOF"
MIN_ENTRIES=15                      # residuals for a voxel to be solved
N_THREADS=8                         # fit threads: match the JDL's multicore_8 allocation
STAGE2_MAP_SUFFIX=".GausSmooth.Extrapolation"   # stage 2's FT name suffix: must match postProcessJob.sh's DO_GAUS_SMOOTH / DO_EXTRAPOLATION
DERIVATIVE_MAP=""                   # "": the slot's coarse map as is (each slot independent, no IDC needed); "ccdb": in addition
                                    # TPC/Calib/CorrectionMapDerivativeV2, scaled per TF with the IDC (needs IDC in both maps)
ENTRIES_PER_FILE=${ENTRIES_PER_FILE:--1} # -1: every TF of the window; a few for a quick local test (SUBJOBID=1 ENTRIES_PER_FILE=2 ./fineMapJob.sh)

# the base correction: this slot's stage-2 FastTransform
OUTPUT_STEM="voxRes.${RUN}_${firstTSIter}_${lastTSIter}.TD${WIN_IDX}of${WIN_COUNT}.it0"
SUBJOB_COUNTER_DIR=$(printf "%0${COUNTERWIDTH}d" "${SUBJOBID}")
BASE_MAP="alien://${STAGE2_OUTPUTDIR_BASE}/${SUBJOB_COUNTER_DIR}/FT_${OUTPUT_STEM}${STAGE2_MAP_SUFFIX}.root"
echo "Base correction: ${BASE_MAP}"
if ! alien.py ls "${BASE_MAP#alien://}" > /dev/null 2>&1; then
  echo "WARNING: stage-2 FastTransform not found at ${BASE_MAP} -- stage 1 marked this slot badCalib_, or stage 1 / 2 failed or have not run yet. Skipping (not an error) -- resubmit this subjob once stage 2 has produced it." >&2
  exit 0
fi

OUTPUT_FILE="${OUTPUT_STEM}.fine.root"
cmd="(time root.exe -b -q -l -x '${MACRO_PATH}+O(\"${SLOT_LIST}\", ${RUN}, \"${OUTPUT_FILE}\", \"${BASE_MAP}\", \"${DERIVATIVE_MAP}\", \"\", \"${TRACK_SOURCES}\", \"${Y2XBINNING}\", \"${Z2XBINNING}\", ${MAX_Z2X}, ${firstTSIter}, ${lastTSIter}, ${ENTRIES_PER_FILE}, 0, ${MIN_ENTRIES}, false, ${N_THREADS})')"
echo "$(date) ${cmd}"
eval "${cmd}"
if [[ ! -s "${OUTPUT_FILE}" ]]; then
  echo "ERROR: ${OUTPUT_FILE} was not produced -- this slot's fine map failed" >&2
  exit 1
fi

# stage to this job's own JDL output directory, as stages 1 and 2
ALIEN_OUTPUT_DIR="alien://${ALIEN_JDL_OUTPUTDIR:-${ALIEN_JOB_OUTPUTDIR:-}}"
if [[ "${ALIEN_OUTPUT_DIR}" == "alien://" ]]; then
  echo "ERROR: neither ALIEN_JDL_OUTPUTDIR nor ALIEN_JOB_OUTPUTDIR is set -- don't know where to stage ${OUTPUT_FILE}" >&2
  exit 1
fi
if ! alien.py cp -f "file:${OUTPUT_FILE}" "${ALIEN_OUTPUT_DIR}/${OUTPUT_FILE}"; then
  echo "ERROR: failed to stage ${OUTPUT_FILE} to ${ALIEN_OUTPUT_DIR}" >&2
  exit 1
fi
echo "Staged ${OUTPUT_FILE} to ${ALIEN_OUTPUT_DIR}"

# provenance: the base correction this fine map sits on (non-fatal)
BASE_SOURCE_FILE="baseMapSource.txt"
echo "${BASE_MAP}" > "${BASE_SOURCE_FILE}"
alien.py cp -f "file:${BASE_SOURCE_FILE}" "${ALIEN_OUTPUT_DIR}/${BASE_SOURCE_FILE}" || \
  echo "WARNING: failed to stage ${BASE_SOURCE_FILE} -- provenance pointer only, not fatal" >&2
rm -f "${BASE_SOURCE_FILE}"
echo "Stage 3 complete: ${OUTPUT_FILE}"
