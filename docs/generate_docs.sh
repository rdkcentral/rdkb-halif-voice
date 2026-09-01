#!/usr/bin/env bash

# *
# * If not stated otherwise in this file or this component's LICENSE file the
# * following copyright and licenses apply:
# *
# * Copyright 2023 RDK Management
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# * http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *

# WHAT THIS SCRIPT ENFORCES, stated because a developer running it should be able to read
# what it refuses and why. Every check below ends in a message on stderr and a non-zero
# exit status - never a warning, never a fallback - and nothing is generated when one
# fails. Seven controls, each closing a way this build could otherwise be turned into
# arbitrary code execution or a disclosure:
#
#   1. INPUT. PROJECT_VERSION comes from `git describe --tags`, which is repository data
#      rather than a trusted constant. make expands a command-line variable RECURSIVELY
#      and exports it into every recipe's shell, so a tag named `v$(SSH_PRIVATE_KEY)` or
#      `v$(shell touch /tmp/x)` is expanded or executed by make rather than printed, and
#      shell quoting does not prevent it because make re-expands the value after the shell
#      has finished with it. `git check-ref-format` accepts both of those tag names, so
#      they are valid input rather than malformed input. The version and the site title are
#      therefore accepted only from the character set a version and a title need, bounded
#      in length, refused when they begin with '-', and passed to make quoted.
#   2. PROVENANCE. The generator checkout must come from the official repository, decided
#      by remote HOST AND PATH rather than by equality with one spelling of the URL: a
#      substring or suffix comparison also accepts
#      https://evil.example.com/rdkcentral/hal-doxygen, which is a different project, while
#      a single-string comparison rejects the equivalent https:// and ssh:// spellings of
#      the real one. A local filesystem origin is refused, because a path authenticates
#      nothing about the content behind it.
#   3. IDENTITY. The pin names a tag, and a tag is a movable label, so resolving the name
#      proves nothing on its own: a checkout carrying a tag of the same name over other
#      content resolves it happily. The commit that tag must resolve to is recorded beside
#      the pin and asserted, and the checkout is then required to be DETACHED at exactly
#      that commit, so no branch tip can move underneath a later run.
#   4. INTEGRITY. `git checkout` keeps non-conflicting local modifications and untracked
#      additions, so a tampered Makefile, Doxyfile.cfg or header.html executes while HEAD
#      still reports the expected commit. The checkout must therefore be clean with
#      untracked files included; its git directory must be the ordinary directory inside
#      it, not a gitdir redirect pointing somewhere unverified; it must carry no local
#      configuration key or hook that lets git run a program of the checkout's choosing;
#      and no index entry may be marked assume-unchanged or skip-worktree, which would make
#      a modified tracked file report clean.
#   5. CONTAINMENT. ./build and ./output must both be real directories inside this docs/
#      directory. The generator's Doxyfile.cfg sets OUTPUT_DIRECTORY to ../output resolved
#      from ./build, so Doxygen writes the entire generated site through ./output, and a
#      symlink there - at its root or at any depth beneath it - redirects every one of
#      those writes out of the repository.
#   6. TIME OF CHECK VERSUS TIME OF USE. Containment, revision and cleanliness are
#      asserted again immediately before make, with nothing between them and the build, so
#      a concurrent writer cannot substitute a different tree between verification and use.
#   7. DIAGNOSTICS. Every URL this script prints passes through redact_url, so a remote
#      configured with credentials in its userinfo - https://user:token@host/path - is
#      reported by host and path and the credential does not reach a terminal or a build
#      log. For the same reason no refusal echoes the version string it rejected: that
#      string is attacker-chosen data, and a log is a place other tools read.
#
# Nothing is fetched, and nothing outside ./output is written, when ./build is already the
# pinned generator: an established checkout builds with no network access at all.

set -o pipefail
set -o nounset

# Every refusal goes through here, so a caller - a developer or a CI job - always learns
# why the documentation was not generated, on stderr, with a non-zero status.
die() {
    echo "generate_docs.sh: refusing to build: $*" >&2
    exit 1
}

# Decode the percent-escapes in a URL component, so a decision about its content is made on
# what git would use rather than on its encoded spelling: `git%3Atoken@host` carries a
# credential exactly as `git:token@host` does. Only well-formed %XX triplets are decoded,
# anything else is copied through unchanged, and the input is bounded because this runs on
# data of unknown length.
hal_percent_decode() {
    local input="${1:0:256}" out=""
    while [ -n "${input}" ]; do
        case "${input}" in
            %[0-9A-Fa-f][0-9A-Fa-f]*)
                out="${out}$(printf '%b' "\\x${input:1:2}")"
                input="${input:3}"
                ;;
            *)
                out="${out}${input:0:1}"
                input="${input:1}"
                ;;
        esac
    done
    printf '%s' "${out}"
}

# Render a URL safe to print. A remote may be configured with credentials in its userinfo,
# and this script names the remote it found whenever it refuses one, so without this a
# rejection message is itself a credential disclosure into whatever captured the output.
#
#   scheme://[userinfo@]host/path - the userinfo is removed unconditionally. No form of it
#       is safe to echo and no reader needs it.
#   [user@]host:path, the scp-like spelling git uses for SSH - the user portion is kept
#       only while it is a plain login name, so the conventional `git@github.com:` stays
#       legible; a user portion carrying a ':' or a percent-escape is a credential pair
#       rather than a login name, and is removed.
#
# The host and the path always survive, because they are what a reader needs in order to
# understand the refusal.
redact_url() {
    local url="${1:-}" scheme rest authority path userinfo host decoded
    case "${url}" in
        *://*)
            scheme="${url%%://*}"
            rest="${url#*://}"
            authority="${rest%%/*}"
            if [ "${authority}" = "${rest}" ]; then
                path=""
            else
                path="/${rest#*/}"
            fi
            case "${authority}" in
                *@*)
                    host="${authority##*@}"
                    printf '%s://<redacted>@%s%s' "${scheme}" "${host}" "${path}"
                    ;;
                *)
                    printf '%s' "${url}"
                    ;;
            esac
            ;;
        *@*:*)
            userinfo="${url%%@*}"
            rest="${url#*@}"
            decoded="$(hal_percent_decode "${userinfo}")"
            case "${decoded}" in
                "" | *[!A-Za-z0-9._-]*)
                    printf '<redacted>@%s' "${rest}"
                    ;;
                *)
                    printf '%s' "${url}"
                    ;;
            esac
            ;;
        *)
            printf '%s' "${url}"
            ;;
    esac
}

# git reads configuration from the environment as well as from files, and several of those
# variables name a program git will then execute. This script runs git inside ./build, a
# directory it has not yet established anything about, so a caller's environment must not
# be able to decide what runs there. They are refused rather than unset: a caller who set
# one meant something by it, and ignoring the request silently would be worse than
# stopping. GIT_CONFIG_COUNT= is a parse error to git rather than "no keys", so an empty
# value is refused too.
#
# GIT_SSH and GIT_SSH_COMMAND are deliberately NOT in this list. This script clones over
# SSH, and selecting a deploy key through them is the documented way to do that on a build
# host. Unlike the variables below they inject no configuration into the untrusted checkout
# and can only influence the transport - and the commit assertion of control 3 is what
# makes the transport unable to substitute content, because no remote, hostile or
# otherwise, can produce a different tree at a given commit id.
hal_refuse_hostile_git_env() {
    local variable
    for variable in GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM \
        GIT_CONFIG_GLOBAL GIT_PROXY_COMMAND GIT_EXTERNAL_DIFF GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
        if [ -n "${!variable+set}" ]; then
            die "'${variable}' is set in the environment, and it can redirect where git reads configuration or objects from; this build is refused rather than run under it"
        fi
    done
    while IFS= read -r variable; do
        [ -n "${variable}" ] || continue
        die "'${variable}' is set in the environment, and it injects a git configuration key into every git invocation; this build is refused rather than run under it"
    done <<< "$(env | sed -n 's/^\(GIT_CONFIG_KEY_[0-9]*\)=.*/\1/p'
                env | sed -n 's/^\(GIT_CONFIG_VALUE_[0-9]*\)=.*/\1/p')"
}
hal_refuse_hostile_git_env

# Every git invocation in this script goes through this wrapper. The system and global
# configuration scopes are neutralised, the hook path is pointed at something that cannot
# hold hooks, the filesystem monitor is cleared, and the `ext` transport - which runs a
# command named inside a URL - is forbidden. Without this, `git clone`, `git status` or
# `git checkout` in an untrusted checkout runs whatever that checkout's configuration names
# (CWE-829). The local scope lives inside the untrusted tree and cannot be neutralised from
# outside, which is why a checkout carrying an executing key is refused outright below
# rather than merely overridden here.
hal_git() {
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    git -c core.hooksPath=/dev/null \
        -c core.fsmonitor= \
        -c protocol.ext.allow=never \
        -c advice.detachedHead=false \
        "$@"
}

# ---------------------------------------------------------------- the build parameters

# The generator repository. This is both what a first run clones and the provenance every
# later run is checked against. The SSH spelling is the corpus convention and is kept; the
# host-and-path check below also accepts the equivalent https:// and ssh:// spellings,
# because a checkout provisioned over either is the same project.
HAL_GENERATOR_URL="git@github.com:rdkcentral/hal-doxygen.git"

# The only host and repository path that is the generator. Held separately from the URL
# above so that one spelling of it is never mistaken for the identity (control 2).
HAL_GENERATOR_HOST="github.com"
HAL_GENERATOR_PATH="rdkcentral/hal-doxygen"

# In the future this should moved to a fixed verison
HAL_GENERATOR_VERSION=1.2.0

# The commit that tag must resolve to, read from the authoritative remote with
# `git ls-remote https://github.com/rdkcentral/hal-doxygen.git refs/tags/1.2.0`. The tag
# name above remains the declared pin - it is what the plan pins and what the project's
# tooling reads - and this is the assertion that makes the pin name one immutable tree: a
# tag can be created or moved onto other content in any checkout, so a name alone
# authenticates nothing (CWE-829). Change the two together, never one alone.
HAL_GENERATOR_COMMIT="cfd03653d1bbdb88efa6cf47277aa9eeba4f5fae"

# The generator checkout and the generated site, both relative to this docs/ directory.
HAL_GENERATOR_DIR="./build"
HAL_OUTPUT_DIR="./output"

# The generated site's title. Checked below for the same reason the version is, and passed
# to make quoted: make re-expands a command-line variable in every recipe's shell.
PROJECT_NAME="RDK-B Telco Voice HAL"

# ----------------------------------------------- run from this script's own directory
# Everything the generator does is written relative to docs/: the make invocation below
# names the build directory relative to this one, and the Doxyfile's INPUT paths and its
# OUTPUT_DIRECTORY resolve from here as well. Run from anywhere
# else, this script would clone the generator into an unrelated directory and the
# containment checks below would describe a path that is not the one being built. The
# directory is therefore established rather than assumed; the documented invocation,
# `cd docs && ./generate_docs.sh`, behaves exactly as before.
hal_docs_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd -P)" ||
    die "this script's own directory cannot be resolved, so the generator location cannot be established"
cd -- "${hal_docs_dir}" ||
    die "'${hal_docs_dir}' cannot be entered"

# ------------------------------------------------------------ control 1: the input strings

# This will look up the last tag in the git repo, depending on the project this may require modification
# The pipeline of the original one-liner is split so that both commands can be checked
# separately: with the two joined, a `git describe` failure was reported by nothing and the
# build continued with an empty version.
hal_describe_output="$(hal_git describe --tags)" ||
    die "'git describe --tags' failed, so this repository's version cannot be determined"
# `git describe` emits exactly one line, so more than one is an anomaly rather than a
# version with extra detail. Taking the first line and discarding the rest would silently
# accept whatever produced the extra lines; the run stops instead.
case "${hal_describe_output}" in
    *$'\n'*)
        die "'git describe --tags' produced more than one line, which it does not do for a single repository revision; refusing rather than using part of it" ;;
esac
PROJECT_VERSION="$(printf '%s\n' "${hal_describe_output}" | head -n1)" ||
    die "the first line of 'git describe --tags' could not be read"

# The refusals below deliberately describe the version string without quoting it: it is
# attacker-chosen data at this point, and a build log is read by other tools.
case "${PROJECT_VERSION}" in
    "")
        die "'git describe --tags' produced an empty version string; the site would be labelled with nothing" ;;
    -*)
        die "'git describe --tags' produced a version string beginning with '-', which is indistinguishable from a command-line option wherever it is passed" ;;
    *[!A-Za-z0-9._+-]*)
        die "'git describe --tags' produced a version string containing a character outside [A-Za-z0-9._+-]; make would re-expand it in every recipe's shell, so it is refused rather than labelled onto the site" ;;
esac
if [ "${#PROJECT_VERSION}" -gt 256 ]; then
    die "'git describe --tags' produced a version string of ${#PROJECT_VERSION} characters; a version is a label, and a value this long is a payload aimed at an argument list or a log rather than a version"
fi

case "${PROJECT_NAME}" in
    "" | -*)
        die "PROJECT_NAME is empty or begins with '-', so the generated site would have no usable title" ;;
    *[!A-Za-z0-9\ ._+-]*)
        die "PROJECT_NAME carries a character make would re-expand in every recipe's shell" ;;
esac

# ------------------------------------------------------- control 5: ./build containment
# Asserted before anything is provisioned, and again immediately before make. A symlink
# here means the directory that was verified need not be the directory that runs.
hal_assert_build_contained() {
    local occasion="$1" build_real
    if [ -L "${HAL_GENERATOR_DIR}" ]; then
        die "'${HAL_GENERATOR_DIR}' is a symlink (${occasion}); the generator must be a real directory inside '${hal_docs_dir}', because a checkout that can be relocated between verification and use is not one this script can vouch for"
    fi
    if [ -e "${HAL_GENERATOR_DIR}" ] && [ ! -d "${HAL_GENERATOR_DIR}" ]; then
        die "'${HAL_GENERATOR_DIR}' exists and is not a directory (${occasion}), so it is not a generator checkout"
    fi
    if [ -d "${HAL_GENERATOR_DIR}" ]; then
        build_real="$(cd -- "${HAL_GENERATOR_DIR}" > /dev/null 2>&1 && pwd -P)" ||
            die "'${HAL_GENERATOR_DIR}' cannot be entered (${occasion}), so it cannot be verified"
        [ "${build_real}" = "${hal_docs_dir}/build" ] ||
            die "'${HAL_GENERATOR_DIR}' resolves to '${build_real}' rather than '${hal_docs_dir}/build' (${occasion}), so the tree that would execute is not the one inside this repository"
    fi
}
hal_assert_build_contained "before provisioning"

# ----------------------------------------------------- control 4: the checkout's git state
# The git directory has to be the ordinary directory inside the checkout. A `.git` symlink
# or gitdir redirect points HEAD, the refs and the hooks somewhere this script has not
# looked, so `git status` and `git rev-parse HEAD` would describe a different repository
# from the tree make reads.
hal_assert_generator_git_shape() {
    if [ -L "${HAL_GENERATOR_DIR}/.git" ]; then
        die "'${HAL_GENERATOR_DIR}/.git' is a symlink; the generator's git directory must be the real one inside the checkout, or HEAD and the clean-tree check describe a tree other than the one make builds"
    fi
    if [ ! -d "${HAL_GENERATOR_DIR}/.git" ]; then
        die "'${HAL_GENERATOR_DIR}/.git' is not a directory - a gitdir redirect pointing the generator's git directory elsewhere - so HEAD, the refs and the hooks would live where this script has not looked"
    fi
}

# The local configuration a checkout carries, and its hooks, are refused before anything is
# fetched or checked out. hal_git stops those keys taking effect in THIS script's
# invocations; refusing them outright is what stops a checkout that carries them being
# treated as trustworthy at all, because make - and any tool it runs - runs unwrapped. The
# file is also read directly, so a configuration git itself cannot parse cannot hide a key
# by making `git config --list` fail.
hal_refuse_hostile_generator_config() {
    local keys key raw_keys raw_sections entry
    keys="$(hal_git -C "${HAL_GENERATOR_DIR}" config --list --local --name-only 2>/dev/null)" || keys=""
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        case "${key}" in
            core.hookspath | core.fsmonitor | core.sshcommand | core.pager | core.editor)
                die "'${HAL_GENERATOR_DIR}' configures '${key}', which lets git run a program of its own choosing during fetch, checkout or status" ;;
            filter.*)
                die "'${HAL_GENERATOR_DIR}' configures '${key}' - a content filter git executes while checking files out - so the files make reads need not be the files at the pinned commit" ;;
            credential.helper | credential.*.helper | remote.*.uploadpack | remote.*.receivepack)
                die "'${HAL_GENERATOR_DIR}' configures '${key}', which names an external program git invokes to talk to a remote" ;;
            protocol.allow | protocol.*.allow | url.* | alias.* | include.path | includeif.*)
                die "'${HAL_GENERATOR_DIR}' configures '${key}', which redirects where git fetches from or what a git subcommand means" ;;
            extensions.worktreeconfig)
                die "'${HAL_GENERATOR_DIR}' sets 'extensions.worktreeConfig', which turns on a configuration scope a local-scope scan does not read" ;;
        esac
    done <<< "${keys}"
    # A fresh clone of the generator never has a worktree-scoped configuration file, so its
    # existence alone is refused: it is a scope git honours and `config --list --local`
    # does not report.
    if [ -e "${HAL_GENERATOR_DIR}/.git/config.worktree" ]; then
        die "'${HAL_GENERATOR_DIR}' carries .git/config.worktree, a configuration scope git honours and a local-scope scan does not read; a fresh clone of the generator never has one"
    fi
    if [ -f "${HAL_GENERATOR_DIR}/.git/config" ]; then
        raw_keys="$(sed 's/#.*//' "${HAL_GENERATOR_DIR}/.git/config" | tr -d ' \t' |
            grep -iE '^(hooksPath|fsmonitor|sshCommand|pager|editor|clean|smudge|process|askPass|credentialHelper)=')" || raw_keys=""
        raw_sections="$(grep -iE '^\[(filter|diff|difftool|mergetool|url|credential)' "${HAL_GENERATOR_DIR}/.git/config")" || raw_sections=""
        [ -z "${raw_keys}" ] ||
            die "'${HAL_GENERATOR_DIR}/.git/config' sets a key git uses to run a program of its own choosing"
        [ -z "${raw_sections}" ] ||
            die "'${HAL_GENERATOR_DIR}/.git/config' declares a section git uses to run a program of its own choosing"
    fi
    if [ -d "${HAL_GENERATOR_DIR}/.git/hooks" ]; then
        for entry in "${HAL_GENERATOR_DIR}"/.git/hooks/*; do
            [ -e "${entry}" ] || continue
            case "${entry}" in *.sample) continue ;; esac
            if [ -x "${entry}" ]; then
                die "'${HAL_GENERATOR_DIR}' carries an executable hook, '${entry}'; git would run it during fetch or checkout, before this script has established that the checkout is clean"
            fi
        done
    fi
}

# Check if the common document configuration is present, if not clone it. A directory that
# is not a checkout - what an interrupted or failed clone leaves behind - is refused rather
# than built from, and the clone's own exit status decides whether the run continues.
if [ -e "${HAL_GENERATOR_DIR}/.git" ]; then
    hal_assert_generator_git_shape
elif [ -e "${HAL_GENERATOR_DIR}" ]; then
    die "'${HAL_GENERATOR_DIR}' exists but is not a git checkout, so its origin and its revision cannot be established; remove it and run this script again"
else
    echo "Cloning Common documentation generation"
    hal_git clone "${HAL_GENERATOR_URL}" build ||
        die "cloning the documentation generator from $(redact_url "${HAL_GENERATOR_URL}") failed"
    hal_assert_build_contained "after cloning"
    hal_assert_generator_git_shape
fi
hal_refuse_hostile_generator_config

# --------------------------------------------------------------- control 2: provenance
# Being at the right commit proves nothing if the object came from a different project, so
# the remote is authenticated before the revision is. The comparison is on host and path
# after the scheme, any userinfo, any port and one optional `.git` suffix have been
# removed, which is what distinguishes github.com/rdkcentral/hal-doxygen from
# evil.example.com/rdkcentral/hal-doxygen - a suffix or substring test accepts both.
hal_assert_official_remote() {
    local url="${1}" label="${2}" rest authority path host safe userinfo=""
    safe="$(redact_url "${url}")"
    [ -n "${url}" ] ||
        die "${label} is empty, so the generator's provenance cannot be established"
    case "${url}" in
        /* | ./* | ../* | ~* | file://*)
            die "${label} is the local path '${safe}'; a filesystem path authenticates nothing about the content behind it, so the generator must name the official remote" ;;
    esac
    rest="${url%/}"
    rest="${rest%.git}"
    case "${rest}" in
        https://* | ssh://*)
            rest="${rest#*://}"
            ;;
        *://*)
            die "${label} is '${safe}', whose URL scheme this script does not accept for the generator; use the https:// or the SSH spelling of ${HAL_GENERATOR_PATH}" ;;
        *:*)
            # The scp-like spelling, [user@]host:path. Its single ':' separator is
            # normalised to '/' so that one decomposition serves every accepted form.
            case "${rest}" in
                *@*)
                    userinfo="${rest%%@*}"
                    rest="${rest#*@}"
                    ;;
            esac
            rest="${rest/:/\/}"
            ;;
        *)
            die "${label} is '${safe}', which is not a URL form this script can authenticate" ;;
    esac
    authority="${rest%%/*}"
    if [ "${authority}" = "${rest}" ]; then
        path=""
    else
        path="${rest#*/}"
    fi
    case "${authority}" in
        *@*)
            userinfo="${authority%%@*}"
            authority="${authority##*@}"
            ;;
    esac
    # A remote that carries a credential in its userinfo is refused even when the host and
    # the path are the official ones. git keeps that URL in plain text in the checkout's
    # configuration and reproduces it in its own diagnostics, so the credential outlives
    # this script's redaction; and nothing here needs it, because the commit assertion of
    # control 3 - not an authenticated transport - is what establishes that the content is
    # the generator. The test is the same one redact_url uses to decide what to hide, so
    # anything this script would have to redact is refused instead of merely masked. The
    # conventional plain login name, `git@`, is unaffected.
    case "$(hal_percent_decode "${userinfo}")" in
        "") : ;;
        *[!A-Za-z0-9._-]*)
            die "${label} is '${safe}', which carries a credential in its userinfo; reconfigure the remote without embedded credentials (the pinned commit is what authenticates the generator's content, so none is needed to trust it)" ;;
    esac
    # The port, where the URL form allows one, is not part of the identity.
    host="${authority%%:*}"
    [ "${host}" = "${HAL_GENERATOR_HOST}" ] ||
        die "${label} names host '${host}' (in '${safe}'), not ${HAL_GENERATOR_HOST}; the same repository path under another host is a different project"
    [ "${path}" = "${HAL_GENERATOR_PATH}" ] ||
        die "${label} names repository path '${path}' (in '${safe}'), not ${HAL_GENERATOR_PATH}"
}

hal_generator_origin="$(hal_git -C "${HAL_GENERATOR_DIR}" config --get remote.origin.url)" ||
    die "'${HAL_GENERATOR_DIR}' has no 'origin' remote, so it cannot be identified as the documentation generator"
hal_assert_official_remote "${hal_generator_origin}" "the origin of '${HAL_GENERATOR_DIR}'"
hal_generator_origin_safe="$(redact_url "${hal_generator_origin}")"

# ---------------------------------------------------------- control 3: the exact revision
# The pinned tag has to be present locally and has to resolve to the recorded commit.
# Fetching is the means and never the end: when the tag is already present nothing leaves
# this machine, and when it cannot be made present the build is refused rather than run at
# an unknown revision.
hal_generator_tag_commit="$(hal_git -C "${HAL_GENERATOR_DIR}" rev-parse --verify --quiet "refs/tags/${HAL_GENERATOR_VERSION}^{commit}")" ||
    hal_generator_tag_commit=""
if [ -z "${hal_generator_tag_commit}" ]; then
    hal_git -C "${HAL_GENERATOR_DIR}" fetch --quiet --tags origin ||
        die "fetching tags from ${hal_generator_origin_safe} failed, so generator ${HAL_GENERATOR_VERSION} cannot be resolved"
    hal_generator_tag_commit="$(hal_git -C "${HAL_GENERATOR_DIR}" rev-parse --verify --quiet "refs/tags/${HAL_GENERATOR_VERSION}^{commit}")" ||
        hal_generator_tag_commit=""
    [ -n "${hal_generator_tag_commit}" ] ||
        die "generator ${HAL_GENERATOR_VERSION} does not exist in ${hal_generator_origin_safe}"
fi
[ "${hal_generator_tag_commit}" = "${HAL_GENERATOR_COMMIT}" ] ||
    die "in '${HAL_GENERATOR_DIR}' the generator tag ${HAL_GENERATOR_VERSION} resolves to ${hal_generator_tag_commit}, not the recorded ${HAL_GENERATOR_COMMIT}; the tag has moved, or this checkout carries a tag of its own over other content"

# Check the pin out only when the checkout is not already detached at it, then confirm the
# checkout actually moved. A checkout left on a branch is refused even when the branch tip
# is currently correct, because a branch can be advanced by anything that updates it - so
# the revision verified here would not be the revision a later run builds.
hal_assert_generator_revision() {
    local occasion="$1" head detached=0
    head="$(hal_git -C "${HAL_GENERATOR_DIR}" rev-parse --verify HEAD)" ||
        die "'${HAL_GENERATOR_DIR}' has no resolvable HEAD (${occasion})"
    hal_git -C "${HAL_GENERATOR_DIR}" symbolic-ref --quiet HEAD > /dev/null 2>&1 || detached=1
    [ "${head}" = "${HAL_GENERATOR_COMMIT}" ] ||
        die "'${HAL_GENERATOR_DIR}' is at ${head} (${occasion}), not generator ${HAL_GENERATOR_VERSION} (${HAL_GENERATOR_COMMIT})"
    [ "${detached}" -eq 1 ] ||
        die "'${HAL_GENERATOR_DIR}' has HEAD on a branch (${occasion}); the generator must be detached at ${HAL_GENERATOR_COMMIT}, because a branch tip can move underneath a later run"
}
hal_generator_head_commit="$(hal_git -C "${HAL_GENERATOR_DIR}" rev-parse --verify HEAD)" ||
    die "'${HAL_GENERATOR_DIR}' has no resolvable HEAD"
hal_generator_detached=0
hal_git -C "${HAL_GENERATOR_DIR}" symbolic-ref --quiet HEAD > /dev/null 2>&1 || hal_generator_detached=1
if [ "${hal_generator_head_commit}" != "${HAL_GENERATOR_COMMIT}" ] || [ "${hal_generator_detached}" -ne 1 ]; then
    hal_git -C "${HAL_GENERATOR_DIR}" checkout --quiet --detach "${HAL_GENERATOR_COMMIT}" ||
        die "checking generator ${HAL_GENERATOR_VERSION} (${HAL_GENERATOR_COMMIT}) out in '${HAL_GENERATOR_DIR}' failed"
fi
hal_assert_generator_revision "after checkout"

# ------------------------------------------------------------- control 4: the tree's state
# A modified or extended generator is not the generator the pin names, and `git checkout`
# keeps both kinds of change, so untracked files are included here. Ignored paths are not:
# the generator's own `doxygen_install.sh` writes into them by design, and its Makefile
# reads nothing from the ignored set - it runs `doxygen Doxyfile.cfg` and resolves `doxygen`
# through PATH. `git status` cannot see a tracked file whose index entry is marked
# assume-unchanged or skip-worktree, so those flags are refused separately: with one set, a
# tampered Makefile reports clean.
hal_assert_generator_clean() {
    local occasion="$1" dirt flags
    dirt="$(hal_git -C "${HAL_GENERATOR_DIR}" status --porcelain --untracked-files=all)" ||
        die "the state of '${HAL_GENERATOR_DIR}' could not be determined (${occasion})"
    [ -z "${dirt}" ] ||
        die "'${HAL_GENERATOR_DIR}' has local modifications or untracked files (${occasion}); restore it to generator ${HAL_GENERATOR_VERSION} and run this script again"
    flags="$(hal_git -C "${HAL_GENERATOR_DIR}" ls-files -v | grep -E '^([a-z]|S) ')" || flags=""
    [ -z "${flags}" ] ||
        die "'${HAL_GENERATOR_DIR}' has index entries marked assume-unchanged or skip-worktree (${occasion}), so git cannot report whether their content matches ${HAL_GENERATOR_COMMIT}"
}
hal_assert_generator_clean "after checkout"

# ------------------------------------------------------ control 5: ./output containment
# The generator's Doxyfile.cfg sets OUTPUT_DIRECTORY to ../output, resolved from ./build,
# so every file of the generated site is written through this path - and docs/output is
# git-ignored, so nothing else in this repository constrains it. Containment is asserted
# before anything is created, and a link at any depth beneath the output root is refused
# too, because Doxygen writes through it just as readily as through the root itself. A file
# with more than one hard link is refused for the same reason: a write through it reaches a
# file outside the output tree.
hal_assert_output_contained() {
    local occasion="$1" nested multi out_real
    if [ -L "${HAL_OUTPUT_DIR}" ]; then
        die "'${HAL_OUTPUT_DIR}' is a symlink (${occasion}); Doxygen writes the whole generated site through that path, so a link there redirects every write out of this repository. Refusing without following or removing it"
    fi
    if [ -e "${HAL_OUTPUT_DIR}" ] && [ ! -d "${HAL_OUTPUT_DIR}" ]; then
        die "'${HAL_OUTPUT_DIR}' exists and is not a directory (${occasion}); refusing to build over it"
    fi
    if [ -d "${HAL_OUTPUT_DIR}" ]; then
        nested="$(find "${HAL_OUTPUT_DIR}" -type l -print 2> /dev/null | head -n 5)" || nested=""
        [ -z "${nested}" ] ||
            die "'${HAL_OUTPUT_DIR}' contains symlinks (${occasion}), and a link at any depth beneath the output root redirects the file Doxygen writes through it"
        multi="$(find "${HAL_OUTPUT_DIR}" -type f -links +1 -print 2> /dev/null | head -n 5)" || multi=""
        [ -z "${multi}" ] ||
            die "'${HAL_OUTPUT_DIR}' contains files with more than one hard link (${occasion}), so a write through one of them reaches a file outside the output tree"
    else
        mkdir -p "${HAL_OUTPUT_DIR}" ||
            die "'${HAL_OUTPUT_DIR}' could not be created, so the generated site has nowhere to go"
    fi
    out_real="$(cd -- "${HAL_OUTPUT_DIR}" > /dev/null 2>&1 && pwd -P)" ||
        die "'${HAL_OUTPUT_DIR}' cannot be entered (${occasion}), so it cannot be verified"
    [ "${out_real}" = "${hal_docs_dir}/output" ] ||
        die "'${HAL_OUTPUT_DIR}' resolves to '${out_real}' rather than '${hal_docs_dir}/output' (${occasion}); refusing to write a generated site outside this repository"
}
hal_assert_output_contained "before the build"

# ------------------------------- control 6: re-assert everything immediately before make
# Every check above was made at a point in time, and make runs after it. Between the two, a
# concurrent writer could move HEAD, edit a tracked file or replace a directory with a
# symlink. These are the same assertions with nothing between them and the build: the race
# is not eliminated - check and use are separate operations by two programs - but its width
# drops from the whole provisioning phase to the interval between this block and make's
# first read.
hal_assert_build_contained "immediately before the build"
hal_assert_generator_git_shape
hal_refuse_hostile_generator_config
hal_assert_generator_revision "immediately before the build"
hal_assert_generator_clean "immediately before the build"
hal_assert_output_contained "immediately before the build"

# Generate the site. Both make arguments are quoted, so neither the title nor the version
# can be split into further arguments or expanded by the shell; the character allowlists
# above are what stop make itself re-expanding them. Make's own exit status is propagated,
# so a caller sees the real failure rather than this script's.
echo "Generating documentation with generator ${HAL_GENERATOR_VERSION} (${HAL_GENERATOR_COMMIT}) from ${hal_generator_origin_safe}"
make -C ./build PROJECT_NAME="${PROJECT_NAME}" PROJECT_VERSION="${PROJECT_VERSION}"
hal_generator_make_status=$?
if [ "${hal_generator_make_status}" -ne 0 ]; then
    echo "generate_docs.sh: documentation generation failed: make exited ${hal_generator_make_status}" >&2
    exit "${hal_generator_make_status}"
fi
