#!/bin/sh
# run.sh -- the gate of this repository: register.sh against test/stub.py.
#
# Ten cases, and each of them asserts the EXIT CODE and the line the action
# printed for a human to read. The five roads the registry's spec names --
# queued -> done, failed, 404, 429, timeout -- are the first five; the next four
# are the assertions that belong to this side alone: the index proof, the tag
# rule, the draft rule and `wait: false`; the tenth is the token (section 28 of
# the spec): what the stub RECEIVED on each poll, the 401 and the two 403s,
# and -- asserted on every token case -- that the value is on no line of the
# action's stdout or stderr except the one `::add-mask::` line under Actions.
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

# Invoked by the trap below, which shellcheck cannot see. The two codes are the
# same complaint from two shellcheck generations: SC2317 (0.9 and older, once
# per command in the body) and SC2329 (0.10 and newer, once for the function).
# shellcheck disable=SC2317,SC2329
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

# The same two, anchored: what matters about a workflow command is not that the
# text is somewhere in the log but WHERE it is on its line. Actions parses `::`
# only at column 0.
hasnt_at_col0() {
    total=$((total + 1))
    if grep -q -e "^$2" "$3"; then
        printf 'FAIL %-34s at column 0: %s\n' "$1" "$2"
        sed 's/^/     /' "$3"
        failures=$((failures + 1))
        rc=1
    else
        printf 'ok   %-34s not at column 0: %s\n' "$1" "$2"
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
    ERR="$WORK/$name.err"
    # stderr on its own file first -- the token cases assert on it alone --
    # and then behind stdout in the log every other assertion reads.
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
        MCA_REGISTRY="$REG" MCA_INDEX="$REG" \
        MCA_REPOSITORY="$repo" MCA_TAG="$tag" \
        MCA_WAIT=true MCA_TIMEOUT=20 MCA_SETTLE=0 \
        GITHUB_OUTPUT="$WORK/$name.out" \
        "$@" \
        sh "$ROOT/register.sh" > "$LOG" 2> "$ERR"
    CODE=$?
    cat "$ERR" >> "$LOG"
    echo "-- $name (exit $CODE)"
}

# The `Authorization` header the stub saw on its LAST poll, as it logs it:
# `Bearer <value>`, or `none`.
last_auth() {
    grep 'stub: POST /poll authorization: ' "$WORK/stub.log" | tail -1 |
        sed 's/^stub: POST \/poll authorization: //'
}
polls_seen() {
    grep -c 'stub: POST /poll authorization: ' "$WORK/stub.log"
}

# The two fixtures, read out of the stub so there is one spelling of each.
TOKEN_GOOD=$(sed -n 's/^TOKEN_GOOD = "\(.*\)"$/\1/p' "$ROOT/test/stub.py")
TOKEN_OTHER=$(sed -n 's/^TOKEN_OTHER = "\(.*\)"$/\1/p' "$ROOT/test/stub.py")
# a well-formed token the stub has never issued: 401
TOKEN_REVOKED="mcr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
[ "${#TOKEN_GOOD}" -eq 47 ] || { echo "FAIL TOKEN_GOOD not read from the stub"; exit 1; }
[ "${#TOKEN_REVOKED}" -eq 47 ] || { echo "FAIL TOKEN_REVOKED is not 47 bytes"; exit 1; }

# The value must not be on ANY line of stderr, and on stdout only where
# `::add-mask::` hands it to Actions -- and there at most once.
token_hidden() {
    # $1 the case, $2 the value, $3 how many `::add-mask::` lines are allowed
    hasnt "$1-stderr-clean" "$2" "$WORK/$1.err"
    total=$((total + 1))
    n=$(grep -cF "$2" "$WORK/$1.log")
    m=$(grep -cF "::add-mask::$2" "$WORK/$1.log")
    if [ "$n" -eq "$m" ] && [ "$m" -eq "$3" ]; then
        printf 'ok   %-34s %s line(s) carry the value, all ::add-mask::\n' "$1-stdout-clean" "$n"
    else
        printf 'FAIL %-34s %s line(s) carry the value, %s of them ::add-mask::, want %s\n' "$1-stdout-clean" "$n" "$m" "$3"
        grep -nF "$2" "$WORK/$1.log" | sed 's/^/     /'
        failures=$((failures + 1))
        rc=1
    fi
}

# ---- 1: queued -> running -> done, and the version is in the index ----
run_case good o/good v1.2.0
check "good-exit" "$CODE" 0
check "good-anonymous" "$(last_auth)" "none"
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
# The report is a stranger's text and it is printed into a log GitHub parses.
# Every line of it goes out behind two spaces, so a `::` the registry sent
# cannot be a workflow command here -- whatever the registry did with it.
has "report-gutter-error" "  ::error::pwned" "$LOG"
has "report-gutter-setoutput" "  ::set-output name=x::y" "$LOG"
has "report-gutter-stop" "  ::stop-commands::tok" "$LOG"
hasnt_at_col0 "report-no-command-error" "::error::pwned" "$LOG"
hasnt_at_col0 "report-no-command-setoutput" "::set-output" "$LOG"
hasnt_at_col0 "report-no-command-stop" "::stop-commands" "$LOG"
hasnt_at_col0 "report-no-command-clone" "clone 180 KiB" "$LOG"

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

# ---- 10: the token ----
#
# Outside Actions (no GITHUB_ACTIONS in the environment) the value goes to no
# stream at all; under Actions it goes to stdout exactly once, as the
# `::add-mask::` line that makes the runner redact it from everything after.
run_case tokgood o/good v1.2.0 MCA_TOKEN="$TOKEN_GOOD"
check "token-exit" "$CODE" 0
check "token-sent-as-bearer" "$(last_auth)" "Bearer $TOKEN_GOOD"
has "token-notice" "::notice::mc registry: $REG, repository o/good, tag v1.2.0, as the token's account" "$LOG"
has "token-published" "::notice::published: good 1.2.0" "$LOG"
token_hidden tokgood "$TOKEN_GOOD" 0

run_case tokmask o/good v1.2.0 MCA_TOKEN="$TOKEN_GOOD" GITHUB_ACTIONS=true
check "token-mask-exit" "$CODE" 0
has "token-mask-line" "::add-mask::$TOKEN_GOOD" "$LOG"
token_hidden tokmask "$TOKEN_GOOD" 1
# the mask is the FIRST thing printed: nothing can carry the value before it
total=$((total + 1))
if [ "$(head -1 "$LOG")" = "::add-mask::$TOKEN_GOOD" ]; then
    printf 'ok   %-34s the first line\n' "token-mask-first"
else
    printf 'FAIL %-34s the first line is: %s\n' "token-mask-first" "$(head -1 "$LOG")"
    failures=$((failures + 1)); rc=1
fi

# a pasted secret's trailing newline is forgiven
run_case toknl o/good v1.2.0 MCA_TOKEN="$TOKEN_GOOD
"
check "token-newline-exit" "$CODE" 0
check "token-newline-trimmed" "$(last_auth)" "Bearer $TOKEN_GOOD"

# 401: well-formed, never issued (revoked, expired: the registry does not say)
run_case tokbad o/good v1.2.0 MCA_TOKEN="$TOKEN_REVOKED"
check "token-401-exit" "$CODE" 1
check "token-401-sent" "$(last_auth)" "Bearer $TOKEN_REVOKED"
has "token-401-error" "::error::the token was refused (revoked, expired, or not a token)" "$LOG"
hasnt "token-401-no-group" "::group::registry report" "$LOG"
token_hidden tokbad "$TOKEN_REVOKED" 0

# 403: the account behind the token owns nothing here, two ways
run_case tokother o/good v1.2.0 MCA_TOKEN="$TOKEN_OTHER"
check "token-403-exit" "$CODE" 1
has "token-403-error" "::error::the token's account does not own this repository" "$LOG"
token_hidden tokother "$TOKEN_OTHER" 0
run_case toktheirs o/theirs v1.2.0 MCA_TOKEN="$TOKEN_GOOD"
check "token-403-theirs-exit" "$CODE" 1
has "token-403-theirs-error" "::error::the token's account does not own this repository" "$LOG"

# 403 with the other body: the account has a document to accept
run_case tokaccept o/accept v1.2.0 MCA_TOKEN="$TOKEN_GOOD"
check "token-accept-exit" "$CODE" 1
has "token-accept-error" "::error::the token's account has to accept the registry's documents first: accept the updated terms first" "$LOG"

# a value that is not a token never leaves the runner: refused by shape,
# not echoed, and the stub saw no poll for it
before=$(polls_seen)
run_case tokshape o/good v1.2.0 MCA_TOKEN="hunter2-not-a-token-at-all"
check "token-shape-exit" "$CODE" 1
has "token-shape-error" "::error::the token is not an mc registry token (mcr_ + 43 characters): create one on $REG/me > Tokens" "$LOG"
check "token-shape-no-poll" "$(polls_seen)" "$before"
token_hidden tokshape "hunter2-not-a-token-at-all" 0
# and the same with a quote in it, which is what the shape rule is FOR: a `"`
# would close curl's quoted config value
run_case tokquote o/good v1.2.0 MCA_TOKEN='mcr_"
url = "http://evil.example/'
check "token-quote-exit" "$CODE" 1
has "token-quote-error" "::error::the token is not an mc registry token" "$LOG"
check "token-quote-no-poll" "$(polls_seen)" "$before"
hasnt "token-quote-not-echoed" "evil.example" "$LOG"

# without a token, 401 and 403 are what any other status is
run_case anon o/theirs v1.2.0
check "anonymous-theirs-exit" "$CODE" 0
check "anonymous-theirs-header" "$(last_auth)" "none"

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
