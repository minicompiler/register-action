#!/bin/sh
# run.sh -- the gate of this repository: register.sh against test/stub.py.
#
# Nine cases, and each of them asserts the EXIT CODE and the line the action
# printed for a human to read. The five roads the registry's spec names --
# queued -> done, failed, 404, 429, timeout -- are the first five; the last four
# are the assertions that belong to this side alone: the index proof, the tag
# rule, the draft rule and `wait: false`.
#
# Nothing here reaches the network. The stub is a loopback HTTP server, which is
# also why register.sh widens curl's `--proto` for a loopback address and for
# nothing else.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
rc=0
total=0
failures=0

# invoked by the trap below, which shellcheck cannot see
# shellcheck disable=SC2329
cleanup() {
    if [ -n "${STUB:-}" ]; then
        kill "$STUB" 2> /dev/null
        # `wait` so the shell reaps the stub itself instead of printing
        # "Terminated" over the last line of the report
        wait "$STUB" 2> /dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        printf 'ok   %-34s %s\n' "$1" "$2"
    else
        printf 'FAIL %-34s got %s, want %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
        rc=1
    fi
}

has() {
    total=$((total + 1))
    if grep -qF "$2" "$3"; then
        printf 'ok   %-34s %s\n' "$1" "$2"
    else
        printf 'FAIL %-34s no such line: %s\n' "$1" "$2"
        sed 's/^/     /' "$3"
        failures=$((failures + 1))
        rc=1
    fi
}

hasnt() {
    total=$((total + 1))
    if grep -qF "$2" "$3"; then
        printf 'FAIL %-34s the line is there: %s\n' "$1" "$2"
        failures=$((failures + 1))
        rc=1
    else
        printf 'ok   %-34s no %s\n' "$1" "$2"
    fi
}

command -v python3 > /dev/null 2>&1 || { echo "run.sh: SKIPPED (no python3)"; exit 0; }
command -v curl > /dev/null 2>&1 || { echo "run.sh: SKIPPED (no curl)"; exit 0; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$ROOT/test/stub.py" "$PORT" 2> "$WORK/stub.log" &
STUB=$!
i=0
until grep -q "stub: listening" "$WORK/stub.log" 2> /dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { echo "FAIL the stub did not start"; cat "$WORK/stub.log"; exit 1; }
    sleep 0.1
done
REG="http://127.0.0.1:$PORT"
echo "run.sh: the stub is on $REG"

# One case: run register.sh with an environment and nothing else, and report
# what it did. $1 names the case, $2 the repository, $3 the tag; anything after
# that is `NAME=VALUE` for the environment.
LOG=""
CODE=0
run_case() {
    name=$1
    repo=$2
    tag=$3
    shift 3
    LOG="$WORK/$name.log"
    : > "$WORK/$name.out"
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
        MCA_REGISTRY="$REG" MCA_INDEX="$REG" \
        MCA_REPOSITORY="$repo" MCA_TAG="$tag" \
        MCA_WAIT=true MCA_TIMEOUT=20 MCA_SETTLE=0 \
        GITHUB_OUTPUT="$WORK/$name.out" \
        "$@" \
        sh "$ROOT/register.sh" > "$LOG" 2>&1
    CODE=$?
    echo "-- $name (exit $CODE)"
}

# ---- 1: queued -> running -> done, and the version is in the index ----
run_case good o/good v1.2.0
check "good-exit" "$CODE" 0
has "good-group" "::group::registry report" "$LOG"
has "good-report" "box: ok" "$LOG"
has "good-published" "::notice::published: good 1.2.0" "$LOG"
has "good-state" "state=done" "$WORK/good.out"
has "good-job" "job=1" "$WORK/good.out"
has "good-report-url" "report-url=$REG/jobs/1" "$WORK/good.out"

# ---- 2: the registry refused the package ----
run_case bad o/bad v1.2.0
check "failed-exit" "$CODE" 1
has "failed-error" "::error::the mc registry refused this release" "$LOG"
has "failed-report-in-log" "sandbox: refused: open /etc/shadow" "$LOG"
has "failed-filtered-colour" "colour: ?[31mred?[0m" "$LOG"
has "failed-state" "state=failed" "$WORK/bad.out"

# ---- 3: the repository was never registered ----
run_case missing o/missing v1.2.0
check "404-exit" "$CODE" 1
has "404-error" "::error::o/missing is not registered: register it once on" "$LOG"
hasnt "404-no-group" "::group::registry report" "$LOG"

# ---- 4: rate-limited, then queued ----
run_case busy o/busy v1.2.0
check "429-exit" "$CODE" 0
has "429-waited" "::notice::rate-limited by the registry; waiting 1s" "$LOG"
has "429-published" "::notice::published: good 1.2.0" "$LOG"

# ---- 5: the job never ends ----
run_case slow o/slow v1.2.0 MCA_TIMEOUT=3
check "timeout-exit" "$CODE" 1
has "timeout-error" "::error::the job did not end within 3s" "$LOG"
has "timeout-state" "state=timeout" "$WORK/slow.out"

# ---- 6: done, but the index does not carry the version ----
run_case noindex o/noindex v1.2.0
check "noindex-exit" "$CODE" 1
has "noindex-error" "::error::the job ended but 1.2.0 is not in the index" "$LOG"
has "noindex-state" "state=failed" "$WORK/noindex.out"

# ---- 7: the tag rule, four ways ----
run_case badtag1 o/good 1.2.0
check "badtag-no-v-exit" "$CODE" 1
has "badtag-no-v" "::error::the tag has to start with v" "$LOG"
run_case badtag2 o/good v1.2
check "badtag-two-fields-exit" "$CODE" 1
has "badtag-two-fields" "::error::the tag has to be v + a SemVer version" "$LOG"
run_case badtag3 o/good v01.2.0
check "badtag-leading-zero-exit" "$CODE" 1
has "badtag-leading-zero" "::error::the tag has to be v + a SemVer version" "$LOG"
run_case badtag4 o/good v1.2.0+build.5
check "badtag-build-exit" "$CODE" 1
has "badtag-build" "::error::the registry does not publish build metadata" "$LOG"
run_case pretag o/good v1.2.0-rc.1
check "pre-release-tag-reaches-the-registry" "$CODE" 1
has "pre-release-not-in-index" "::error::the job ended but 1.2.0-rc.1 is not in the index" "$LOG"

# ---- 8: the event has to be a published, non-draft release ----
run_case draft o/good v1.2.0 MCA_EVENT_NAME=release MCA_EVENT_ACTION=published MCA_RELEASE_DRAFT=true
check "draft-exit" "$CODE" 1
has "draft-error" "::error::a draft release publishes nothing" "$LOG"
run_case created o/good v1.2.0 MCA_EVENT_NAME=release MCA_EVENT_ACTION=created
check "unpublished-exit" "$CODE" 1
has "unpublished-error" "::error::this action runs on a published release" "$LOG"
run_case published o/good v1.2.0 MCA_EVENT_NAME=release MCA_EVENT_ACTION=published MCA_RELEASE_DRAFT=false
check "published-exit" "$CODE" 0
has "published-ok" "::notice::published: good 1.2.0" "$LOG"

# ---- 9: wait: false queues the job and stops ----
run_case nowait o/good v1.2.0 MCA_WAIT=false
check "nowait-exit" "$CODE" 0
has "nowait-state" "state=queued" "$WORK/nowait.out"
hasnt "nowait-no-group" "::group::registry report" "$LOG"

# ---- and the registry has to be https ----
LOG="$WORK/http.log"
env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    MCA_REGISTRY="http://registry.example" MCA_INDEX="$REG" \
    MCA_REPOSITORY=o/good MCA_TAG=v1.2.0 MCA_SETTLE=0 \
    sh "$ROOT/register.sh" > "$LOG" 2>&1
CODE=$?
echo "-- plain-http registry (exit $CODE)"
check "http-registry-exit" "$CODE" 1
has "http-registry-error" "::error::the registry has to be an https URL" "$LOG"

echo "run.sh: $total checks, $failures failed"
exit "$rc"
