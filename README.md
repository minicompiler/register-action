# register-action

Publish an [mc](https://github.com/minicompiler/mc) package from GitHub
Actions: when you publish a release, this action asks the mc package registry
to look at the tag, waits for the answer, prints the registry's report into the
job log, and fails the workflow if the release was refused or did not reach the
index.

It carries **no secret** unless you give it one. The whole request is your
repository's public URL; with an optional account token the same poll runs as
you (see [Per-account tokens](#per-account-tokens)).

## What it does

1. Refuses to run unless the tag is `v` + a SemVer version (`v1.2.0`,
   `v1.2.0-rc.1`) and the event is a **published, non-draft** release.
2. Waits ten seconds, so the release the registry is about to ask github.com
   about is visible to the API.
3. `POST <registry>/poll` with `git_url=https://github.com/<owner>/<repo>`.
   The registry queues one validation job and answers `202` with
   `Location: /jobs/<id>`. A `429` is retried, honouring `Retry-After`, until
   the timeout.
4. Reads `<registry>/jobs/<id>` until the job is `done` or `failed`.
5. Prints the report inside a `::group::registry report`, so what the sandbox
   refused -- `sandbox: refused: open /etc/shadow` and the like -- is in your
   log. Every line of it goes out behind a two-space gutter: the report is a
   stranger's text and stdout is a channel Actions parses, so a `::` in it is
   never at column 0 and can never be a workflow command.
6. Fails the workflow when the registry refused the release.
7. Otherwise reads `<index>/index/<package>.toml` and requires
   `version = "<the tag without its v>"` to be there. That is the only
   assertion about what a consumer of your package will actually see.

**The repository has to be registered once, by a person**, on
<https://minicompiler.dev/me>. This action never registers anything: a
registration binds a repository to an account that has accepted the registry's
documents, and an unauthenticated request has no account. After that one form,
every release is automatic.

## The workflow to copy

`.github/workflows/mc-publish.yml`:

```yaml
name: Publish to the mc registry
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag: {description: "Existing release tag", required: true, type: string}
permissions:
  contents: read
concurrency:
  group: mc-publish-${{ github.repository }}
  cancel-in-progress: false
jobs:
  publish:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: minicompiler/register-action@v1
        with:
          tag: ${{ inputs.tag || github.event.release.tag_name }}
```

No checkout, no secret, no permission beyond the default `contents: read`.

## Per-account tokens

The anonymous poll above is enough for a registered repository: the registry
validates the tag whoever asked. Two things it cannot do, because an anonymous
request has no account: poll a repository whose registration is still
`pending` (its first validation failed and the next release should be looked
at), and run as *you* -- charged to your own budget, recorded as your request,
rather than waiting for the scheduler.

An **account token** does both. On <https://minicompiler.dev/me> > Tokens,
make one: it is shown **once**, it is `mcr_` + 43 characters, and an account
holds at most 50 live ones. Store it as a repository secret -- Settings >
Secrets and variables > Actions, say `MC_REGISTRY_TOKEN` -- and pass it:

```yaml
      - uses: minicompiler/register-action@v1
        with:
          tag: ${{ inputs.tag || github.event.release.tag_name }}
          token: ${{ secrets.MC_REGISTRY_TOKEN }}
```

What it changes: the poll carries `Authorization: Bearer <token>` and the
registry answers for the account -- `401` if the token was revoked, has
expired, or is not one (the action says `the token was refused`), `403` if the
account does not own the repository (`the token's account does not own this
repository`) or still has a registry document to accept. What it does **not**
buy: a token's only scope is `poll`. It cannot register a repository, cannot
yank a version, and cannot do anything a person does on `/me` -- so a leaked
one is a nuisance, not a loss; revoke it on the same page.

How the action handles it: the value is masked in the job log first thing
(`::add-mask::`), checked for the registry's shape before anything else, and
handed to `curl` as a config line on its **standard input** (`-K -`) -- never
on a command line, where a process listing would show it, and never printed.
Without the input the request is byte for byte the anonymous one.

## Inputs

| input | default | meaning |
|---|---|---|
| `registry` | `https://minicompiler.dev` | where `POST /poll` and `GET /jobs/<id>` live |
| `index` | `https://pkg.minicompiler.dev` | where the proof is read |
| `repository` | `${{ github.repository }}` | `owner/repo` |
| `tag` | `${{ github.event.release.tag_name }}` | the release's tag |
| `wait` | `true` | wait for the job; with `false` the action queues it and stops |
| `timeout` | `900` | seconds to wait before giving up |
| `token` | (none) | an account token from `/me` > Tokens, passed from a secret; the poll runs as that account (see [Per-account tokens](#per-account-tokens)) |

## Outputs

| output | meaning |
|---|---|
| `job` | the job id the registry queued |
| `state` | `done`, `failed`, `timeout`, or `queued` when `wait` is `false` |
| `report-url` | `<registry>/jobs/<id>`, the public report |

## Pinning it

`@v1` is a moving tag, as GitHub's own actions use one: fixes move it. To pin
the exact bytes you reviewed, use a commit SHA instead --

```yaml
      - uses: minicompiler/register-action@0000000000000000000000000000000000000000
```

`git ls-remote https://github.com/minicompiler/register-action v1` prints the
SHA that `v1` currently names.

## What is in here

* `action.yml` -- a **composite** action: shell steps and `curl`. No node, no
  Docker, no third-party action.
* `register.sh` -- the whole of it, in POSIX `sh`.
* `test/stub.py` -- a registry that plays the roads the action has to handle:
  `queued -> running -> done`, `failed`, `404`, `429` with `Retry-After`, a job
  that never ends, a job that ends without putting the version in the index,
  and the token roads -- it records the `Authorization` header of every poll,
  answers `401` to a token it never issued and `403` to another account's.
* `test/run.sh` -- the gate: `make check` runs `shellcheck`, `sh -n` and the
  script against that stub, asserting the exit code and the message of each
  road.

## The registry's side

`POST /poll` and `GET /jobs/<id>` are the registry's own routes, specified in
section 19 of its spec (`minicompiler/mc-registry`, private) and served by
<https://minicompiler.dev>. A poll is bounded -- three an hour per repository, sixty an hour per address,
three hundred an hour in all -- it queues at most one job per repository at a
time, it records `origin = 'ci'` with no account, and it can neither register a
package nor yank a version. With an account token (section 28 of the spec) the
same route records `origin = 'user'` and the account, polls only the packages
of that repository the account owns, and charges the account's own budget
(sixty an hour) before the three above.

## Licence

MIT. See [LICENSE](LICENSE).
