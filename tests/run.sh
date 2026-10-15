#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/tests/test-lib.sh"
"$ROOT_DIR/tests/test-flow.sh"
"$ROOT_DIR/tests/test-crashloop.sh"

ruby -e '
    require "yaml"
    action = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    abort "not composite" unless action.dig("runs", "using") == "composite"
    abort "CrashLoopBackOff deletion must default on" unless action.dig("inputs", "delete-crashloopbackoff-pods", "default") == "true"
    names = action.dig("runs", "steps").map { |step| step["name"] }
    order = ["Pre-pull deployment images", "Delete CrashLoopBackOff pods", "Deploy manifests", "Remove temporary pre-pull resources"]
    abort "unexpected deployment step order" unless order.map { |name| names.index(name) }.each_cons(2).all? { |left, right| left < right }
' \
    "$ROOT_DIR/k8s-deploy/action.yml"

grep -q 'if:.*always()' "$ROOT_DIR/k8s-deploy/action.yml"
grep -q 'Azure/k8s-deploy@2f25f49dce3a648e1451f23f89fd73a2e1085123' "$ROOT_DIR/k8s-deploy/action.yml"
grep -q 'Delete CrashLoopBackOff pods' "$ROOT_DIR/k8s-deploy/action.yml"

printf 'All tests passed\n'
