#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # Resolve the library from the repository root.
source "$ROOT_DIR/k8s-deploy/scripts/lib.sh"

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        printf 'Expected command to fail: %s\n' "$*" >&2
        exit 1
    fi
}

parse_images $'x4bnet/x4b-site:git-abc\nregistry.example.test:5000/team/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
[[ "${#IMAGES[@]}" == 2 ]]
[[ "${IMAGES[0]}" == "x4bnet/x4b-site:git-abc" ]]
[[ "${IMAGES[1]}" == registry.example.test:* ]]

assert_fails validate_image_reference "x4bnet:latest"
assert_fails validate_image_reference "x4bnet/x4b-site"
assert_fails validate_image_reference "x4bnet/x4b-site:bad tag"
assert_fails parse_images $'  \n\t'

validate_node_selector '{"k8s.x4b.net/ready":"1"}'
assert_fails validate_node_selector '{}'
assert_fails validate_node_selector '[]'
assert_fails validate_node_selector '{"worker":1}'

validate_tolerations '[]'
validate_tolerations '[{"key":"dedicated","operator":"Exists"}]'
assert_fails validate_tolerations '{}'
assert_fails validate_tolerations '["invalid"]'

validate_rollout_timeout 5m
assert_fails validate_rollout_timeout 0m
assert_fails validate_rollout_timeout 300
validate_cleanup_timeout 600
assert_fails validate_cleanup_timeout 0

export PREPULL_RANDOM_SUFFIX=first
first_name="$(generate_resource_name)"
export PREPULL_RANDOM_SUFFIX=second
second_name="$(generate_resource_name)"
[[ "$first_name" != "$second_name" ]]
[[ "${#first_name}" -le 63 ]]

printf 'Library tests passed\n'
