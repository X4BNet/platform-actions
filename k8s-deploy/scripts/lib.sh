#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC2034 # Consumed by prepull.sh after this library is sourced.
readonly PREPULL_HELPER_IMAGE="docker.io/curlimages/curl@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6"

die() {
    printf 'Error: %s\n' "$*" >&2
    return 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_image_reference() {
    local image="$1"
    local repository
    local final_component
    local tag

    if [[ "$image" == *[[:space:]]* ]]; then
        die "image reference contains whitespace: $image"
        return 1
    fi
    if [[ "$image" != */* ]]; then
        die "image reference must include a repository and image name: $image"
        return 1
    fi

    if [[ "$image" == *@* ]]; then
        repository="${image%@*}"
        if [[ "$repository" != */?* ]]; then
            die "image reference has an incomplete repository: $image"
            return 1
        fi
        if [[ ! "$image" =~ @sha256:[0-9a-fA-F]{64}$ ]]; then
            die "image digest must be an explicit sha256 digest: $image"
            return 1
        fi
        return 0
    fi

    final_component="${image##*/}"
    if [[ "$final_component" != *:* ]]; then
        die "image reference must include an explicit tag or digest: $image"
        return 1
    fi
    tag="${final_component##*:}"
    if [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        die "image reference has an invalid tag: $image"
        return 1
    fi
    repository="${image%:*}"
    [[ "$repository" == */?* ]] || die "image reference has an incomplete repository: $image"
}

parse_images() {
    local input="$1"
    local line
    local image

    IMAGES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        image="$(trim "$line")"
        [[ -n "$image" ]] || continue
        validate_image_reference "$image" || return 1
        IMAGES+=("$image")
    done <<< "$input"

    ((${#IMAGES[@]} > 0)) || die "at least one complete image reference is required for deploy"
}

parse_image_pull_secrets() {
    local input="$1"
    local line
    local secret

    IMAGE_PULL_SECRETS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        secret="$(trim "$line")"
        [[ -n "$secret" ]] || continue
        if [[ "$secret" == *[[:space:]]* ]]; then
            die "image pull secret names cannot contain whitespace: $secret"
            return 1
        fi
        IMAGE_PULL_SECRETS+=("$secret")
    done <<< "$input"
}

validate_node_selector() {
    local selector="$1"

    jq -e '
        type == "object" and
        length > 0 and
        all(to_entries[]; (.key | length) > 0 and (.value | type) == "string" and (.value | length) > 0)
    ' <<< "$selector" >/dev/null || die "prepull-node-selector must be a non-empty JSON object with non-empty string values"
}

validate_tolerations() {
    local tolerations="$1"

    jq -e 'type == "array" and all(.[]; type == "object")' <<< "$tolerations" >/dev/null \
        || die "prepull-tolerations must be a JSON array of objects"
}

validate_rollout_timeout() {
    local timeout="$1"
    [[ "$timeout" =~ ^[1-9][0-9]*(s|m|h)$ ]] || die "prepull-timeout must be a positive duration ending in s, m, or h"
}

validate_cleanup_timeout() {
    local timeout="$1"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "prepull-cleanup-timeout-seconds must be a positive integer"
}

generate_resource_name() {
    local run_id="${GITHUB_RUN_ID:-local}"
    local attempt="${GITHUB_RUN_ATTEMPT:-1}"
    local random_suffix
    local name

    if [[ -n "${PREPULL_RANDOM_SUFFIX:-}" ]]; then
        random_suffix="$PREPULL_RANDOM_SUFFIX"
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        random_suffix="$(tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-10)"
    else
        random_suffix="${RANDOM}${RANDOM}"
    fi

    name="k8s-deploy-prepull-${run_id}-${attempt}-${random_suffix}"
    name="$(tr '[:upper:]_' '[:lower:]-' <<< "$name" | tr -cd 'a-z0-9.-' | cut -c1-63)"
    name="${name%.}"
    name="${name%-}"
    [[ -n "$name" ]] || die "could not generate a Kubernetes resource name"
    printf '%s' "$name"
}

json_array_from_lines() {
    if (($# == 0)); then
        printf '[]'
        return 0
    fi

    printf '%s\n' "$@" | jq -R . | jq -s .
}
