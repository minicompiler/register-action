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
# Without a `token` it carries no secret and needs no permission beyond the
# default `contents: read`: everything it sends is the repository's own public
# URL. With one -- an mc registry account token, `mcr_` + 43 characters, made on
# the registry's /me page -- the poll runs AS that account (the registry's spec,
# section 28): the token travels to `curl` on its standard input as a config
# line, never on an argument vector, and this script never prints it.
#
# There is no `set -e`: every command whose failure means something is checked
# where it runs, and a `curl` that fails in the middle of a poll loop is a
# retry, not the end of the job.
set -u
# No tracing, ever: a `sh -x` of this file would print the token where it is
# handed to curl. It is switched off before the token is read, not after.
set +x

REGISTRY=${MCA_REGISTRY:-https://minicompiler.dev}
INDEX=${MCA_INDEX:-https://pkg.minicompiler.dev}
REPOSITORY=${MCA_REPOSITORY:-}
TAG=${MCA_TAG:-}
WAIT=${MCA_WAIT:-true}
TIMEOUT=${MCA_TIMEOUT:-900}
EVENT_NAME=${MCA_EVENT_NAME:-}
EVENT_ACTION=${MCA_EVENT_ACTION:-}
RELEASE_DRAFT=${MCA_RELEASE_DRAFT:-}
TOKEN=${MCA_TOKEN:-}

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

# ---- 0. the token, when there is one ----
#
# Masked FIRST, before any line that could carry it: `::add-mask::` tells
# Actions to redact the value from the whole log from here on, and it is only
# printed where something parses it -- outside Actions (the gate) the line
# would be a plain print of a secret, so it is not printed there at all.
# Pasted secrets grow a trailing newline; that much is forgiven, nothing else.
# The shape is the registry's own (`mcr_` + 43 characters of base64url, its
# web/token.mc), and it is what makes the curl config line below safe: no byte
# of that alphabet can close the quoted value or start an option. A token that
# is not that shape is refused here WITHOUT being echoed -- the registry would
# answer 401 to it anyway, and this way it never leaves the runner.
if [ -n "$TOKEN" ]; then
    TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n')
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::add-mask::%s\n' "$TOKEN"
    fi
    if ! printf '%s' "$TOKEN" | grep -Eq '^mcr_[A-Za-z0-9_-]{43}$'; then
        die "the token is not an mc registry token (mcr_ + 43 characters): create one on ${REGISTRY%/}/me > Tokens"
    fi
fi

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
if [ -n "$TOKEN" ]; then
    notice "mc registry: $REGISTRY, repository $REPOSITORY, tag $TAG, as the token's account"
else
    notice "mc registry: $REGISTRY, repository $REPOSITORY, tag $TAG"
fi

# ---- 2. let the Release become visible ----
# The `published` event arrives before the REST API answers about the release on
# some runs; a poll that arrives first sees no Release for the tag and skips it.
[ "$SETTLE" -gt 0 ] && sleep "$SETTLE"

# ---- 3. POST /poll ----
#
# The body is the repository's URL and nothing else. `-D -` gives us the
# headers we then read the status and `Location` out of, and `-w` the status
# itself -- so one request answers both questions. The answer's body is kept
# only for a 403, which is the one status with two readings (below).
#
# With a token, the request also carries `Authorization: Bearer <token>`, and
# the header reaches curl as a CONFIG FILE on its standard input (`-K -`) -- one
# `header = "..."` line -- which is how the registry itself hands curl every
# credential it has: never on argv, where `ps` and a crash dump would show it.
# Without one the command is byte for byte what it always was.
started=$(date +%s)
poll_once() {
    if [ -n "$TOKEN" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl -sS --proto "$REG_PROTO" --max-time 20 -K - \
             -o "$PBODY" -D "$HDRS" -w '%{http_code}' \
             -X POST --data-urlencode "git_url=https://github.com/$REPOSITORY" \
             "$REGISTRY/poll" 2> "$CURLERR"
    else
        curl -sS --proto "$REG_PROTO" --max-time 20 \
             -o "$PBODY" -D "$HDRS" -w '%{http_code}' \
             -X POST --data-urlencode "git_url=https://github.com/$REPOSITORY" \
             "$REGISTRY/poll" 2> "$CURLERR"
    fi
}

HDRS=$(mktemp)
CURLERR=$(mktemp)
PBODY=$(mktemp)
trap 'rm -f "$HDRS" "$CURLERR" "$PBODY"' EXIT

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
        401)
            # Only a request that offered a credential can get this one: the
            # anonymous poll has no account and is never asked for one.
            [ -n "$TOKEN" ] || die "the registry answered $code to POST $REGISTRY/poll"
            die "the token was refused (revoked, expired, or not a token): make a new one on $REGISTRY/me > Tokens and update the secret"
            ;;
        403)
            # Two readings, told apart by the body: the account behind the
            # token owns none of the repository's packages, or it has a
            # registry document still to accept (the acceptance gate a session
            # meets, asked on this road too) -- the registry says which.
            [ -n "$TOKEN" ] || die "the registry answered $code to POST $REGISTRY/poll"
            if grep -qi 'accept' "$PBODY"; then
                die "the token's account has to accept the registry's documents first: $(head -1 "$PBODY") -- sign in on $REGISTRY/me"
            fi
            die "the token's account does not own this repository: the poll runs as the account that made the token, and $REPOSITORY is registered to another"
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
trap 'rm -f "$HDRS" "$CURLERR" "$PBODY" "$BODY"' EXIT

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
#
# Behind a two-space gutter, every line of it. The report is a stranger's text
# -- the worker's, the compiler's and the sandbox's words about a repository
# nobody audited -- and stdout here is a channel GitHub PARSES: a line that
# starts with `::` at column 0 is a workflow command, so `::error::` would raise
# an annotation nobody wrote, `::set-output` would set one of this action's own
# outputs, and `::stop-commands::<token>` would turn the rest of the log into
# data. Two spaces is all it takes, and it is this side's job whatever the
# registry does with its own copy (the review of mc-registry's PR #6).

group "registry report"
sed 's/^/  /' "$BODY"
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
trap 'rm -f "$HDRS" "$CURLERR" "$PBODY" "$BODY" "$idx"' EXIT
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
