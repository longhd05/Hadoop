#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
cd "$REPO_ROOT"

compose() {
  docker compose "$@"
}

echo "[1/6] verify effective runtime secure-mode config"
compose exec -T namenode bash -lc '
  set -euo pipefail
  test "$(hdfs getconf -confKey hadoop.security.authentication)" = "kerberos"
  test "$(hdfs getconf -confKey hadoop.security.authorization)" = "true"
  test "$(hdfs getconf -confKey dfs.permissions.enabled)" = "true"
'

echo "[2/6] verify WebHDFS does not accept unauthenticated user.name pseudo-auth"
if ! status=$(compose exec -T namenode bash -lc 'curl -sS -o /dev/null -w "%{http_code}" "http://namenode.hadoop.lab:9870/webhdfs/v1/?op=GETHOMEDIRECTORY&user.name=longhd"' | tr -d '\r'); then
  echo "WebHDFS connectivity/auth probe failed before receiving HTTP status"
  exit 1
fi
if [[ "$status" != "401" ]]; then
  echo "Expected HTTP 401 for unauthenticated WebHDFS user.name access, got: $status"
  exit 1
fi

echo "[3/6] kinit as longhd and create HDFS file"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/longhd.user.keytab longhd@HADOOP.LAB
  echo "owned by longhd" > /tmp/longhd.txt
  hdfs dfs -mkdir -p /secure-lab
  hdfs dfs -chmod 755 /secure-lab
  hdfs dfs -put -f /tmp/longhd.txt /secure-lab/longhd.txt
'

echo "[4/6] verify owner is longhd"
owner=$(compose exec -T namenode bash -lc 'hdfs dfs -stat %u /secure-lab/longhd.txt' | tr -d '\r')
if [[ "$owner" != "longhd" ]]; then
  echo "Expected owner longhd but got: $owner"
  exit 1
fi

echo "[5/6] kinit as kido and attempt unauthorized overwrite/delete"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/kido.user.keytab kido@HADOOP.LAB
  echo "owned by kido" > /tmp/kido.txt
  if hdfs dfs -put -f /tmp/kido.txt /secure-lab/longhd.txt; then
    echo "Unexpected: kido overwrote longhd file"
    exit 1
  fi
  if hdfs dfs -rm -f /secure-lab/longhd.txt; then
    echo "Unexpected: kido deleted longhd file"
    exit 1
  fi
'

echo "[6/6] permissions check passed: kido blocked as expected"
