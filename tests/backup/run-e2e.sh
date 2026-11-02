#!/usr/bin/env bash
# Disposable local test cluster; never uses the caller's current kubecontext.
set -euo pipefail
cd "$(dirname "$0")/../.."
export BACKUP_EVIDENCE_DIR="${BACKUP_EVIDENCE_DIR:-$PWD/_output/backup-evidence}"
mkdir -p "$BACKUP_EVIDENCE_DIR"
run_name="psql-backup-e2e-$(date +%s)"
run_dir="$(mktemp -d)"
export KUBECONFIG="$run_dir/kubeconfig"
cleanup() {
  kind export logs --name "$run_name" "${BACKUP_EVIDENCE_DIR:-$run_dir}/kind-logs" >/dev/null 2>&1 || true
  kind delete cluster --name "$run_name"
  rm -rf "$run_dir"
}
trap cleanup EXIT
kind create cluster --name "$run_name" --kubeconfig "$KUBECONFIG" --wait 120s
# Some Docker proxies report a 0.0.0.0 endpoint; the kind certificate covers localhost.
python3 -c 'import os,pathlib; p=pathlib.Path(os.environ["KUBECONFIG"]); p.write_text(p.read_text().replace("https://0.0.0.0:", "https://127.0.0.1:"))'
python3 tests/backup/e2e.py "kind-$run_name"
