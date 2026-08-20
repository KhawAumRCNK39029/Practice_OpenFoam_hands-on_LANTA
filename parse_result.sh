#!/bin/bash
# Read one icoFoam log and report the competition result.
#
#   usage: bash parse_result.sh log.icoFoam
#
# A valid run of this case performs exactly:
#   5 time steps  x  2 pressure correctors  x  321 PCG iterations
# over 64,000,000 cells. All four checks below read that back out of the log.
#
# FVOPS_trim = cells x (steps - 1) / (ExecutionTime[last] - ExecutionTime[first])
# Step 1 is dropped because it also carries mesh loading and first-touch cost.

LOG=$1

if [ ! -f "$LOG" ]; then
    echo "STATUS: INVALID   reason: log file '$LOG' not found"
    exit 1
fi

EXPECTED_CELLS=64000000
EXPECTED_STEPS=5
EXPECTED_SOLVES=10
EXPECTED_ITERS=321

# --- gather ---------------------------------------------------------------
ET=$(grep -oE 'ExecutionTime = [0-9.]+' "$LOG" | awk '{print $3}')
NSTEPS=$(printf '%s\n' "$ET" | grep -c .)
ET_FIRST=$(printf '%s\n' "$ET" | head -1)
ET_LAST=$(printf '%s\n' "$ET" | tail -1)

ENDED=$(grep -c '^End' "$LOG")
# Only the solver's own residual and time lines can carry a broken number.
# Scanning the whole log also scans the header, where the case path appears --
# a team whose directory contains "nan" or "inf" (nanjing, finance, ...) would
# otherwise be told its run diverged.
BADNUM=$(grep -E '^(Time = |ExecutionTime|.*Solving for )' "$LOG" | grep -ciE '\b(nan|inf)\b')

# every pressure solve should report exactly 321 iterations
NSOLVES=$(grep -cE 'Solving for p' "$LOG")
NGOOD=$(grep -cE "Solving for p.*No Iterations ${EXPECTED_ITERS}\$" "$LOG")

# icoFoam does not print the mesh size, so the cell count cannot be read back
# out of a solver log. Earlier versions of this script defaulted it to the
# expected value, which meant the cell-count test silently passed on every real
# log without checking anything. It is now reported as unverified.
#
# That is acceptable, because the metric itself exposes a wrong mesh: FVOPS_trim
# divides by a fixed 64,000,000, so a run on a smaller mesh returns a score
# larger by the ratio of the meshes -- an 8-million-cell run would score about
# eight, which no reader could miss.
CELLS=$(grep -oE 'nCells:[[:space:]]*[0-9]+' "$LOG" | head -1 | grep -oE '[0-9]+$')
CELLS=${CELLS:-unverified}

# Worth reporting because a wrong rank count is an easy mistake to make and the
# score alone will not reveal it.
#
# A missing rank count is reported, not failed. This check has been verified
# against Gadi and Iris logs but not against ASPIRE-2A, which runs cray-mpich
# under PALS rather than OpenMPI -- and a check that cannot be tested against a
# competition cluster must not be able to invalidate results there. The
# consistency test below still applies whenever both fields are present, since a
# log that contradicts itself is wrong regardless of who wrote it.
NPROCS=$(grep -oE '^nProcs[[:space:]]*:[[:space:]]*[0-9]+' "$LOG" | grep -oE '[0-9]+$')
NPROCS=${NPROCS:-0}
[ "$NPROCS" -gt 0 ] || NPROCS_DISP=unknown
NPROCS_DISP=${NPROCS_DISP:-$NPROCS}
HOSTSUM=$(sed -n '/^Hosts[[:space:]]*:/,/^)/p' "$LOG" | grep -oE '[0-9]+\)' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
HOSTSUM=${HOSTSUM:-0}
NNODES=$(sed -n '/^Hosts[[:space:]]*:/,/^)/p' "$LOG" | grep -cE '^[[:space:]]+\(')

# --- check ----------------------------------------------------------------
FAIL=""
[ "$ENDED"  -eq 1 ] || FAIL="${FAIL} solver-did-not-finish"
[ "$BADNUM" -eq 0 ] || FAIL="${FAIL} NaN-or-Inf"
[ "$NSTEPS" -eq "$EXPECTED_STEPS" ] || FAIL="${FAIL} wrong-step-count(${NSTEPS}!=${EXPECTED_STEPS})"
[ "$NSOLVES" -eq "$EXPECTED_SOLVES" ] || FAIL="${FAIL} wrong-solve-count(${NSOLVES}!=${EXPECTED_SOLVES})"
[ "$NGOOD"  -eq "$EXPECTED_SOLVES" ] || FAIL="${FAIL} not-all-solves-ran-${EXPECTED_ITERS}-iterations(${NGOOD}/${EXPECTED_SOLVES})"
[ "$CELLS" = "unverified" ] || [ "$CELLS" -eq "$EXPECTED_CELLS" ] || FAIL="${FAIL} wrong-cell-count(${CELLS}!=${EXPECTED_CELLS})"
[ "$NPROCS" -eq 0 ] || [ "$HOSTSUM" -eq 0 ] || [ "$NPROCS" -eq "$HOSTSUM" ] || FAIL="${FAIL} ranks-do-not-match-hosts(${NPROCS}!=${HOSTSUM})"

echo "checks: End=${ENDED} nan_or_inf=${BADNUM} steps=${NSTEPS}/${EXPECTED_STEPS} p_solves=${NSOLVES}/${EXPECTED_SOLVES} solves_at_${EXPECTED_ITERS}_iters=${NGOOD}/${EXPECTED_SOLVES} ranks=${NPROCS_DISP} nodes=${NNODES} cells=${CELLS}"

if [ -n "$FAIL" ]; then
    echo "STATUS: INVALID   reason:${FAIL}"
    exit 0
fi

# --- report ---------------------------------------------------------------
TRIM=$(awk "BEGIN{print ${ET_LAST} - ${ET_FIRST}}")
# FVOPS divides by the fixed cell count that defines the case, not by whatever
# the log happened to report. That is what makes a run on a smaller mesh score
# proportionally higher, which is how a wrong mesh shows itself.
FVOPS=$(awk "BEGIN{printf \"%.4f\", ${EXPECTED_CELLS}*(${NSTEPS}-1)/${TRIM}/1e6}")
SSTEP=$(awk "BEGIN{printf \"%.3f\", ${TRIM}/(${NSTEPS}-1)}")

echo "STATUS: VALID"
echo "RESULT: FVOPS_trim=${FVOPS}M  s_per_step=${SSTEP}  trim_time=${TRIM}s  steps=${NSTEPS}  ranks=${NPROCS_DISP}  nodes=${NNODES}"
