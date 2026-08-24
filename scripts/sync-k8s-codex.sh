#!/bin/bash

set -euo pipefail

# Lightweight remote Codex support: mirror a pod's Codex logs into a local
# directory that PokeTokenBar can consume via its existing custom scan root.

pod="${POKETOKENBAR_REMOTE_POD:-$(id -un)-0}"
namespace="${POKETOKENBAR_REMOTE_NAMESPACE:-}"
container="${POKETOKENBAR_REMOTE_CONTAINER:-workspace}"
context="${POKETOKENBAR_REMOTE_CONTEXT:-}"
remote_codex_home="${POKETOKENBAR_REMOTE_CODEX_HOME:-/root/.codex}"
interval="${POKETOKENBAR_REMOTE_INTERVAL:-120}"
cache_base="${POKETOKENBAR_REMOTE_CACHE:-$HOME/Library/Application Support/PokeTokenBar/RemoteUsage}"
watch=false
configure=false

usage() {
    cat <<'EOF'
Usage: scripts/sync-k8s-codex.sh [OPTIONS] [POD [NAMESPACE [CONTAINER]]]

Mirrors POD:/root/.codex into PokeTokenBar's local application-support folder.
The default pod is <local-user>-0, the namespace comes from the current kubectl
context, and the default container is workspace.

Options:
  --pod NAME          Kubernetes pod (default: <local-user>-0).
  --namespace NAME    Kubernetes namespace (default: current context).
  --container NAME    Pod container (default: workspace).
  --context NAME      kubectl context (default: current context).
  --remote-home PATH  Codex home in the container (default: /root/.codex).
  --cache PATH        Local mirror base directory.
  --interval SECONDS  Watch interval (default: 120).
  --watch             Sync continuously.
  --configure         Register the mirror as PokeTokenBar's Codex scan root.
  -h, --help          Show this help.

Environment overrides:
  POKETOKENBAR_REMOTE_CONTEXT, POKETOKENBAR_REMOTE_POD,
  POKETOKENBAR_REMOTE_NAMESPACE, POKETOKENBAR_REMOTE_CONTAINER,
  POKETOKENBAR_REMOTE_CODEX_HOME, POKETOKENBAR_REMOTE_CACHE,
  POKETOKENBAR_REMOTE_INTERVAL, KUBECTL_BIN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pod|--namespace|--container|--context|--remote-home|--cache|--interval)
            if [[ $# -lt 2 ]]; then
                echo "$1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --pod) pod="$2" ;;
                --namespace) namespace="$2" ;;
                --container) container="$2" ;;
                --context) context="$2" ;;
                --remote-home) remote_codex_home="$2" ;;
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
destination="$cache_base/$context_dir/$namespace/$pod/$container/codex"

configure_scan_root() {
    local domain key existing
    if [[ "$(uname -s)" != "Darwin" ]] || ! command -v defaults >/dev/null; then
        echo "--configure requires macOS and the defaults command" >&2
        return 1
    fi
    domain="io.github.chattymin.poketokenbar"
    key="customScanRoots.codex"
    existing="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && ! grep -Fqx -- "$destination" <<< "$existing"; then
        defaults write "$domain" "$key" "$existing"$'\n'"$destination"
    elif [[ -z "$existing" ]]; then
        defaults write "$domain" "$key" "$destination"
    fi
    echo "Configured PokeTokenBar Codex scan root: $destination"
}

sync_once() {
    local parent staging marker last_success since remote_files local_files stale_files
    parent="$(dirname "$destination")"
    mkdir -p "$parent" "$destination"
    staging="$(mktemp -d "$parent/.codex-sync.XXXXXX")"
    mkdir -p "$staging/sessions" "$staging/archived_sessions"
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

    if ! "$kubectl_bin" --context "$context" exec -n "$namespace" "$pod" -c "$container" -- \
        sh -c 'cd "$1" && find sessions archived_sessions -type f -name "*.jsonl" -newermt "@$2" -print0 | tar --null -T - -cf -' \
        sh "$remote_codex_home" "$since" \
        | tar -xf - -C "$staging"; then
        rm -rf "$staging"
        return 1
    fi

    # Only recently changed files cross the cluster boundary after the first sync.
    rsync -a "$staging/sessions" "$staging/archived_sessions" "$destination/"

    # Reconcile removed/moved sessions so a local stale copy cannot be counted twice.
    if ! "$kubectl_bin" --context "$context" exec -n "$namespace" "$pod" -c "$container" -- \
        sh -c 'cd "$1" && find sessions archived_sessions -type f -name "*.jsonl" -print | LC_ALL=C sort' \
        sh "$remote_codex_home" > "$remote_files"; then
        rm -rf "$staging"
        return 1
    fi
    (cd "$destination" && find sessions archived_sessions -type f -name '*.jsonl' -print | LC_ALL=C sort) \
        > "$local_files"
    comm -23 "$local_files" "$remote_files" > "$stale_files"
    while IFS= read -r stale; do
        [[ -n "$stale" && "$stale" != /* && "$stale" != *..* ]] || continue
        rm -f "$destination/$stale"
    done < "$stale_files"
    find "$destination/sessions" "$destination/archived_sessions" -depth -type d -empty -delete

    date +%s > "$marker"
    rm -rf "$staging"
    echo "$(date '+%Y-%m-%d %H:%M:%S') synced $namespace/$pod:$remote_codex_home -> $destination"
}

if [[ "$watch" == true ]]; then
    did_configure=false
    while true; do
        if sync_once; then
            if [[ "$configure" == true && "$did_configure" == false ]]; then
                configure_scan_root
                did_configure=true
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') sync failed; retrying in ${interval}s" >&2
        fi
        sleep "$interval"
    done
else
    sync_once
    if [[ "$configure" == true ]]; then
        configure_scan_root
    fi
fi
