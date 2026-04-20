#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
cd "$REPO_ROOT"

compose() {
  docker compose "$@"
}

echo "[1/4] kinit as usera and create HDFS file"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/usera.user.keytab usera@HADOOP.LAB
  echo "owned by usera" > /tmp/usera.txt
  hdfs dfs -mkdir -p /secure-lab
  hdfs dfs -chmod 755 /secure-lab
  hdfs dfs -put -f /tmp/usera.txt /secure-lab/usera.txt
'

echo "[2/4] verify owner is usera"
owner=$(compose exec -T namenode bash -lc 'hdfs dfs -stat %u /secure-lab/usera.txt' | tr -d '\r')
if [[ "$owner" != "usera" ]]; then
  echo "Expected owner usera but got: $owner"
  exit 1
fi

echo "[3/4] kinit as userb and attempt unauthorized overwrite/delete"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/userb.user.keytab userb@HADOOP.LAB
  echo "owned by userb" > /tmp/userb.txt
  if hdfs dfs -put -f /tmp/userb.txt /secure-lab/usera.txt; then
    echo "Unexpected: userb overwrote usera file"
    exit 1
  fi
  if hdfs dfs -rm -f /secure-lab/usera.txt; then
    echo "Unexpected: userb deleted usera file"
    exit 1
  fi
'

echo "[4/4] permission check passed: userb blocked as expected"
