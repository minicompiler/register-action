#!/bin/sh
# register.sh -- the whole of minicompiler/register-action.
#
# What it does, in the order it does it (the registry's spec, section 19.2 of
# minicompiler/mc-registry's docs/spec-M47.md):
#
#   1. refuse a tag that is not `v` + a SemVer version, and an event that is not
#      a published, non-draft release;
#   2. wait ten seconds, so the Release the registry is about to ask github.com
#      about is visible to the API;
#   3. POST the repository's URL to <registry>/poll and read the job's address
#      out of `Location`;
#   4. read <registry>/jobs/<id> until the job ends or the timeout passes;
#   5. print the report into the Actions log, inside a group;
#   6. fail the workflow if the registry refused the package;
#   7. and, when it did not, require the version to BE in the published index --
#      the only assertion here that is about what a consumer will see.
#
# It carries no secret and needs no permission beyond the default `contents:
# read`. Everything it sends is the repository's own public URL.
#
# There is no `set -e`: every command whose failure means something is checked
# where it runs, and a `curl` that fails in the middle of a poll loop is a
# retry, not the end of the job.
set -u

REGISTRY=${MCA_REGISTRY:-https://minicompiler.dev}
INDEX=${MCA_INDEX:-https://pkg.minicompiler.dev}
REPOSITORY=${MCA_REPOSITORY:-}
TAG=${MCA_TAG:-}
WAIT=${MCA_WAIT:-true}
TIMEOUT=${MCA_TIMEOUT:-900}
EVENT_NAME=${MCA_EVENT_NAME:-}
EVENT_ACTION=${MCA_EVENT_ACTION:-}
RELEASE_DRAFT=${MCA_RELEASE_DRAFT:-}
# MCA_TOKEN is accepted by action.yml and deliberately not read here: account
# tokens are S7 of the registry and nothing on the server would look at one.

# How long to wait before the first poll. It is a variable so the gate can set
# it to 0; a workflow never does.
SETTLE=${MCA_SETTLE:-10}

# ---- what goes into the Actions log ----

group()   { printf '::group::%s\n' "$1"; }
endgroup() { printf '::endgroup::\n'; }
notice()  { printf '::notice::%s\n' "$1"; }
err()     { printf '::error::%s\n' "$1"; }

out() {
    # A step output, when there is a file to write it to. Outside Actions -- the
    # gate -- there is not, and the values are on stdout instead.
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    else
        printf 'output %s=%s\n' "$1" "$2"
    fi
}

die() {
    err "$1"
    out state "${STATE:-error}"
    exit 1
}

STATE=error
JOB=""

# ---- 1. the tag and the event ----

[ -n "$REPOSITORY" ] || die "no repository: pass repository: owner/repo"
case "$REPOSITORY" in
    */*/*|/*|*/) die "the repository has to be owner/repo, not '$REPOSITORY'" ;;
    */*) : ;;
    *) die "the repository has to be owner/repo, not '$REPOSITORY'" ;;
esac

[ -n "$TAG" ] || die "no tag: on a release use the default, elsewhere pass tag: vX.Y.Z"

# `v` + SemVer, the shape the registry publishes (its web/semver.mc): three
# numeric fields with no leading zero, an optional `-pre.release` of non-empty
# identifiers, and no `+build` -- the registry refuses a tag carrying build
# metadata rather than publish two versions that compare equal.
version=${TAG#v}
if [ "$version" = "$TAG" ]; then
    die "the tag has to start with v: '$TAG' is not vX.Y.Z"
fi
case "$version" in
    *+*) die "the registry does not publish build metadata: '$TAG'" ;;
esac
core=${version%%-*}
pre=""
case "$version" in
    *-*) pre=${version#*-} ;;
esac
if ! printf '%s' "$core" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    die "the tag has to be v + a SemVer version: '$TAG'"
fi
if [ -n "$pre" ]; then
    if ! printf '%s' "$pre" | grep -Eq '^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$'; then
        die "the pre-release part of '$TAG' is not a SemVer identifier list"
    fi
fi

if [ "$EVENT_NAME" = "release" ]; then
    if [ "$EVENT_ACTION" != "published" ]; then
        die "this action runs on a published release: the event was '$EVENT_ACTION'"
    fi
    if [ "$RELEASE_DRAFT" = "true" ]; then
        die "a draft release publishes nothing: publish it and the event fires"
    fi
fi

# ---- the two addresses, and how curl is allowed to reach them ----
#
# https and nothing else, exactly as the registry itself refuses every protocol
# but https when it clones. The one widening is a loopback address, which is
# what this repository's own gate serves the stub on -- the same shape as the
# registry's MCREG_GITHUB_API override, and no deployment can name it by
# accident.
proto_of() {
    case "$1" in
        https://*) printf '%s' "=https" ;;
        http://127.0.0.1:*|http://localhost:*) printf '%s' "=http,https" ;;
        *) printf '%s' "" ;;
    esac
}
REG_PROTO=$(proto_of "$REGISTRY")
IDX_PROTO=$(proto_of "$INDEX")
[ -n "$REG_PROTO" ] || die "the registry has to be an https URL: '$REGISTRY'"
[ -n "$IDX_PROTO" ] || die "the index has to be an https URL: '$INDEX'"
# a trailing slash would make every address carry two
REGISTRY=${REGISTRY%/}
INDEX=${INDEX%/}

REPORT_URL=""
notice "mc registry: $REGISTRY, repository $REPOSITORY, tag $TAG"

# ---- 2. let the Release become visible ----
# The `published` event arrives before the REST API answers about the release on
# some runs; a poll that arrives first sees no Release for the tag and skips it.
[ "$SETTLE" -gt 0 ] && sleep "$SETTLE"

# ---- 3. POST /poll ----
#
# The body is the repository's URL and nothing else. `-f` makes curl exit
# non-zero on a 4xx/5xx, and `-D -` gives us the headers we then read the status
# and `Location` out of -- so one request answers both questions.
started=$(date +%s)
poll_once() {
    curl -sS --proto "$REG_PROTO" --max-time 20 \
         -o /dev/null -D "$HDRS" -w '%{http_code}' \
         -X POST --data-urlencode "git_url=https://github.com/$REPOSITORY" \
         "$REGISTRY/poll" 2> "$CURLERR"
}

HDRS=$(mktemp)
CURLERR=$(mktemp)
trap 'rm -f "$HDRS" "$CURLERR"' EXIT

header_of() {
    # the LAST value of a header, folded to one line: a redirect would have
    # given curl two header blocks, and the one that counts is the last
    tr -d '\r' < "$HDRS" | grep -i "^$1:" | tail -1 | sed "s/^[^:]*: *//"
}

while :; do
    code=$(poll_once)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        die "the registry could not be reached: $(cat "$CURLERR")"
    fi
    case "$code" in
        202)
            break
            ;;
        429)
            wait_for=$(header_of "Retry-After")
            case "$wait_for" in
                ''|*[!0-9]*) wait_for=60 ;;
            esac
            now=$(date +%s)
            left=$((TIMEOUT - (now - started)))
            if [ "$left" -le "$wait_for" ]; then
                STATE=timeout
                die "the registry is rate-limiting this repository and the timeout is up (Retry-After: $wait_for)"
            fi
            notice "rate-limited by the registry; waiting ${wait_for}s"
            sleep "$wait_for"
            ;;
        404)
            die "$REPOSITORY is not registered: register it once on $REGISTRY/me, then re-run this job"
            ;;
        400)
            die "the registry refused the repository URL: only public GitHub repositories for now"
            ;;
        *)
            die "the registry answered $code to POST $REGISTRY/poll"
            ;;
    esac
done

location=$(header_of "Location")
case "$location" in
    /jobs/*) JOB=${location#/jobs/} ;;
    *) die "the registry queued a job and named it '$location'" ;;
esac
case "$JOB" in
    ''|*[!0-9]*) die "the registry named the job '$JOB', which is not an id" ;;
esac
REPORT_URL="$REGISTRY/jobs/$JOB"
out job "$JOB"
out report-url "$REPORT_URL"
notice "queued: $REPORT_URL"

if [ "$WAIT" != "true" ]; then
    STATE=queued
    out state "queued"
    notice "wait is false: the job is queued and this step is done"
    exit 0
fi

# ---- 4. read the job until it ends ----

BODY=$(mktemp)
trap 'rm -f "$HDRS" "$CURLERR" "$BODY"' EXIT

state=""
while :; do
    code=$(curl -sS --proto "$REG_PROTO" --max-time 20 \
                -o "$BODY" -D "$HDRS" -w '%{http_code}' \
                "$REPORT_URL" 2> "$CURLERR")
    if [ "$code" = "200" ]; then
        state=$(grep -m1 '^state: ' "$BODY" | sed 's/^state: //')
    else
        # A registry that is briefly unreachable is not a failed package: the
        # loop keeps its own clock and the timeout is what ends it.
        state=""
        notice "the job could not be read (HTTP $code); trying again"
    fi
    case "$state" in
        done|failed) break ;;
    esac
    now=$(date +%s)
    if [ $((now - started)) -ge "$TIMEOUT" ]; then
        STATE=timeout
        out state "timeout"
        err "the job did not end within ${TIMEOUT}s: $REPORT_URL"
        exit 1
    fi
    wait_for=$(header_of "Retry-After")
    case "$wait_for" in
        ''|*[!0-9]*) wait_for=5 ;;
    esac
    [ "$wait_for" -lt 1 ] && wait_for=1
    [ "$wait_for" -gt 30 ] && wait_for=30
    sleep "$wait_for"
done

# ---- 5. the report, in the log ----

group "registry report"
cat "$BODY"
endgroup

package=$(grep -m1 '^package: ' "$BODY" | sed 's/^package: //')

# ---- 6. a refusal fails the workflow ----

if [ "$state" = "failed" ]; then
    STATE=failed
    out state "failed"
    err "the mc registry refused this release: $REPORT_URL"
    exit 1
fi

# ---- 7. and a success has to be visible in the index ----
#
# The job being `done` says the worker finished, not that this tag became a
# version: a tag with no GitHub Release is skipped, and a commit that already
# failed is stepped over. The index is where a consumer looks, so it is what is
# asserted.

if [ -z "$package" ]; then
    STATE=failed
    out state "failed"
    err "the job ended without naming a package: $REPORT_URL"
    exit 1
fi

idx=$(mktemp)
trap 'rm -f "$HDRS" "$CURLERR" "$BODY" "$idx"' EXIT
code=$(curl -sS --proto "$IDX_PROTO" --max-time 20 -o "$idx" -w '%{http_code}' \
            "$INDEX/index/$package.toml" 2> "$CURLERR")
if [ "$code" != "200" ]; then
    STATE=failed
    out state "failed"
    err "the index answered $code for $INDEX/index/$package.toml"
    exit 1
fi
if grep -q "^version = \"$version\"\$" "$idx"; then
    STATE="done"
    out state "done"
    notice "published: $package $version -- $INDEX/index/$package.toml"
    exit 0
fi

STATE=failed
out state "failed"
err "the job ended but $version is not in the index (no Release for the tag, or the same commit failed before: re-tag, or ask \"Poll now\" on $REGISTRY/me) -- $REPORT_URL"
exit 1
