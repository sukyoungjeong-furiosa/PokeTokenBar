#!/bin/bash

set -euo pipefail

# Lightweight remote usage support: mirror a pod's Codex and Claude Code logs
# into local directories that PokeTokenBar consumes via its per-provider custom
# scan roots (`customScanRoots.<provider>`). Both tools are synced on every run;
# a tool whose home directory is missing on the pod is skipped, not an error.

providers="codex claude_code"

pod="${POKETOKENBAR_REMOTE_POD:-$(id -un)-0}"
namespace="${POKETOKENBAR_REMOTE_NAMESPACE:-}"
container="${POKETOKENBAR_REMOTE_CONTAINER:-workspace}"
context="${POKETOKENBAR_REMOTE_CONTEXT:-}"
remote_codex_home="${POKETOKENBAR_REMOTE_CODEX_HOME:-/root/.codex}"
remote_claude_home="${POKETOKENBAR_REMOTE_CLAUDE_HOME:-/root/.claude}"
interval="${POKETOKENBAR_REMOTE_INTERVAL:-120}"
cache_base="${POKETOKENBAR_REMOTE_CACHE:-$HOME/Library/Application Support/PokeTokenBar/RemoteUsage}"
watch=false
configure=false

usage() {
    cat <<'USAGE'
Usage: scripts/sync-k8s-usage.sh [OPTIONS] [POD [NAMESPACE [CONTAINER]]]

Mirrors a pod's Codex (/root/.codex/{sessions,archived_sessions}) and Claude Code
(/root/.claude/projects) logs into PokeTokenBar's local application-support
folder. Both tools are synced on every run; a tool whose directory is missing on
the pod is skipped. The default pod is <local-user>-0, the namespace comes from
the current kubectl context, and the default container is workspace.

Options:
  --pod NAME          Kubernetes pod (default: <local-user>-0).
  --namespace NAME    Kubernetes namespace (default: current context).
  --container NAME    Pod container (default: workspace).
  --context NAME      kubectl context (default: current context).
  --codex-home PATH   Codex home in the container (default: /root/.codex).
  --claude-home PATH  Claude Code home in the container (default: /root/.claude).
  --cache PATH        Local mirror base directory.
  --interval SECONDS  Watch interval (default: 120).
  --watch             Sync continuously.
  --configure         Register the mirrors as PokeTokenBar scan roots.
  -h, --help          Show this help.

Environment overrides:
  POKETOKENBAR_REMOTE_CONTEXT, POKETOKENBAR_REMOTE_POD,
  POKETOKENBAR_REMOTE_NAMESPACE, POKETOKENBAR_REMOTE_CONTAINER,
  POKETOKENBAR_REMOTE_CODEX_HOME, POKETOKENBAR_REMOTE_CLAUDE_HOME,
  POKETOKENBAR_REMOTE_CACHE, POKETOKENBAR_REMOTE_INTERVAL, KUBECTL_BIN
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pod|--namespace|--container|--context|--codex-home|--claude-home|--cache|--interval)
            if [[ $# -lt 2 ]]; then
                echo "$1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --pod) pod="$2" ;;
                --namespace) namespace="$2" ;;
                --container) container="$2" ;;
                --context) context="$2" ;;
                --codex-home) remote_codex_home="$2" ;;
                --claude-home) remote_claude_home="$2" ;;
                --cache) cache_base="$2" ;;
                --interval) interval="$2" ;;
            esac
            shift 2
            ;;
        --watch) watch=true; shift ;;
        --configure) configure=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

pod="${1:-$pod}"
namespace="${2:-$namespace}"
container="${3:-$container}"

kubectl_bin="${KUBECTL_BIN:-}"
if [[ -z "$kubectl_bin" ]]; then
    kubectl_bin="$(command -v kubectl || true)"
fi
if [[ -z "$kubectl_bin" ]]; then
    for candidate in /opt/homebrew/bin/kubectl /usr/local/bin/kubectl; do
        if [[ -x "$candidate" ]]; then
            kubectl_bin="$candidate"
            break
        fi
    done
fi
if [[ -z "$kubectl_bin" ]]; then
    echo "kubectl not found" >&2
    exit 1
fi

context="${context:-$($kubectl_bin config current-context)}"
if [[ -z "$namespace" ]]; then
    namespace="$($kubectl_bin --context "$context" config view --minify -o 'jsonpath={..namespace}')"
    namespace="${namespace:-default}"
fi
context_dir="${context//\//_}"
context_dir="${context_dir//../_}"

# Per-provider layout. Only the log subdirectories cross the cluster boundary:
# ~/.claude also holds .credentials.json and history.jsonl, which must stay on
# the pod (the former is a secret, the latter is not a usage log but ends in
# .jsonl and would be parsed).
provider_home() {
    case "$1" in
        codex) printf '%s\n' "$remote_codex_home" ;;
        claude_code) printf '%s\n' "$remote_claude_home" ;;
    esac
}

provider_subdirs() {
    case "$1" in
        codex) printf '%s\n' "sessions archived_sessions" ;;
        claude_code) printf '%s\n' "projects" ;;
    esac
}

provider_destination() {
    printf '%s\n' "$cache_base/$context_dir/$namespace/$pod/$container/$1"
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# remote_sh SCRIPT ARG... — run SCRIPT with /bin/sh in the container, ARGs as $1..$n.
remote_sh() {
    "$kubectl_bin" --context "$context" exec -n "$namespace" "$pod" -c "$container" -- \
        sh -c "$1" sh "${@:2}"
}

configure_scan_root() {
    local provider="$1" destination="$2" domain key existing
    if [[ "$(uname -s)" != "Darwin" ]] || ! command -v defaults >/dev/null; then
        echo "--configure requires macOS and the defaults command" >&2
        return 1
    fi
    domain="io.github.chattymin.poketokenbar"
    key="customScanRoots.$provider"
    existing="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && ! grep -Fqx -- "$destination" <<< "$existing"; then
        defaults write "$domain" "$key" "$existing"$'\n'"$destination"
    elif [[ -z "$existing" ]]; then
        defaults write "$domain" "$key" "$destination"
    fi
    echo "Configured PokeTokenBar $provider scan root: $destination"
}

# Returns 0 on success, 2 when the tool is absent on the pod (skipped), 1 on failure.
sync_provider() {
    local provider="$1" remote_home subdirs destination present
    local parent staging marker last_success since remote_files local_files stale_files
    local dir local_dirs
    local -a sources
    remote_home="$(provider_home "$provider")"
    subdirs="$(provider_subdirs "$provider")"
    destination="$(provider_destination "$provider")"

    # Which log directories exist on the pod? The probe always exits 0 and reports
    # an absent home on stdout, so a missing tool is told apart from a kubectl
    # failure without kubectl printing "command terminated with exit code".
    # shellcheck disable=SC2086
    if ! present="$(remote_sh 'cd "$1" 2>/dev/null || { echo ABSENT; exit 0; }; shift; for d in "$@"; do [ -d "$d" ] && printf "%s\n" "$d"; done; exit 0' \
        "$remote_home" $subdirs)"; then
        echo "$(timestamp) $provider: probe of $namespace/$pod failed" >&2
        return 1
    fi
    if [[ "$present" == ABSENT ]]; then
        echo "$(timestamp) skipping $provider: $remote_home not found in $namespace/$pod" >&2
        return 2
    elif [[ -z "$present" ]]; then
        echo "$(timestamp) skipping $provider: no log directories under $remote_home in $namespace/$pod" >&2
        return 2
    fi
    present="$(tr '\n' ' ' <<< "$present")"

    parent="$(dirname "$destination")"
    mkdir -p "$parent" "$destination"
    staging="$(mktemp -d "$parent/.$provider-sync.XXXXXX")"
    sources=()
    for dir in $present; do
        mkdir -p "$staging/$dir"
        sources+=("$staging/$dir")
    done
    marker="$destination/.last-sync"
    remote_files="$staging/.remote-files"
    local_files="$staging/.local-files"
    stale_files="$staging/.stale-files"

    last_success=0
    if [[ -f "$marker" ]]; then
        read -r last_success < "$marker" || last_success=0
    fi
    [[ "$last_success" =~ ^[0-9]+$ ]] || last_success=0
    since=$((last_success > 300 ? last_success - 300 : 0))

    # shellcheck disable=SC2086
    if ! remote_sh 'cd "$1" && since="$2" && shift 2 && find "$@" -type f -name "*.jsonl" -newermt "@$since" -print0 | tar --null -T - -cf -' \
        "$remote_home" "$since" $present \
        | tar -xf - -C "$staging"; then
        echo "$(timestamp) $provider: transfer from $namespace/$pod:$remote_home failed" >&2
        rm -rf "$staging"
        return 1
    fi

    # Only recently changed files cross the cluster boundary after the first sync.
    rsync -a "${sources[@]}" "$destination/"

    # Reconcile removed/moved sessions so a local stale copy cannot be counted twice.
    # The local listing covers every subdirectory that exists locally, so a
    # directory that vanished on the pod is emptied here as well.
    # shellcheck disable=SC2086
    if ! remote_sh 'cd "$1" && shift && find "$@" -type f -name "*.jsonl" -print | LC_ALL=C sort' \
        "$remote_home" $present > "$remote_files"; then
        echo "$(timestamp) $provider: listing $namespace/$pod:$remote_home failed" >&2
        rm -rf "$staging"
        return 1
    fi
    local_dirs=""
    for dir in $subdirs; do
        if [[ -d "$destination/$dir" ]]; then
            local_dirs="$local_dirs $dir"
        fi
    done
    # shellcheck disable=SC2086
    (cd "$destination" && find $local_dirs -type f -name '*.jsonl' -print | LC_ALL=C sort) \
        > "$local_files"
    comm -23 "$local_files" "$remote_files" > "$stale_files"
    while IFS= read -r stale; do
        [[ -n "$stale" && "$stale" != /* && "$stale" != *..* ]] || continue
        rm -f "$destination/$stale"
    done < "$stale_files"
    for dir in $local_dirs; do
        find "$destination/$dir" -depth -type d -empty -delete
    done

    date +%s > "$marker"
    rm -rf "$staging"
    echo "$(timestamp) synced $provider $namespace/$pod:$remote_home -> $destination"
}

configured_codex=false
configured_claude_code=false

# Returns 0 when every tool present on the pod synced and at least one did.
# sync_provider runs as an `if` condition so errexit neither aborts the loop on a
# non-zero return nor exits the script from inside the function.
sync_all() {
    local provider status synced=0 failed=0 flag
    for provider in $providers; do
        if sync_provider "$provider"; then
            status=0
        else
            status=$?
        fi
        case $status in
            0)
                synced=$((synced + 1))
                flag="configured_$provider"
                if [[ "$configure" == true && "${!flag}" == false ]]; then
                    configure_scan_root "$provider" "$(provider_destination "$provider")"
                    printf -v "$flag" '%s' true
                fi
                ;;
            2) ;;
            *)
                echo "$(timestamp) $provider sync failed" >&2
                failed=$((failed + 1))
                ;;
        esac
    done
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    if [[ $synced -eq 0 ]]; then
        echo "$(timestamp) nothing to sync: neither Codex nor Claude Code found in $namespace/$pod" >&2
        return 1
    fi
    return 0
}

if [[ "$watch" == true ]]; then
    while true; do
        if ! sync_all; then
            echo "$(timestamp) sync failed; retrying in ${interval}s" >&2
        fi
        sleep "$interval"
    done
else
    sync_all
fi
