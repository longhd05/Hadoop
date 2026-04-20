#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
cd "$REPO_ROOT"

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
WAIT_TIMEOUT_SECONDS=${WAIT_TIMEOUT_SECONDS:-300}
WAIT_INTERVAL_SECONDS=${WAIT_INTERVAL_SECONDS:-5}

PASS_COUNT=0
EXPECTED_SERVICES=(kdc namenode datanode resourcemanager nodemanager1 historyserver)

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- docker compose ps ---" >&2
  compose ps >&2 || true
  echo "--- recent logs (kdc/namenode/resourcemanager) ---" >&2
  compose logs --tail=50 kdc namenode resourcemanager >&2 || true
  exit 1
}

wait_for_services_running() {
  local deadline now running svc
  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while :; do
    running="$(compose ps --services --status running | tr -d '\r')"
    local missing=()
    for svc in "${EXPECTED_SERVICES[@]}"; do
      if ! grep -qx "$svc" <<<"$running"; then
        missing+=("$svc")
      fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      pass "All required services are running: ${EXPECTED_SERVICES[*]}"
      return 0
    fi
    now=$(date +%s)
    if (( now >= deadline )); then
      fail "Timed out waiting for services to run. Missing: ${missing[*]}"
    fi
    sleep "$WAIT_INTERVAL_SECONDS"
  done
}

wait_for_kdc_ready() {
  local deadline now
  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while :; do
    if compose exec -T kdc bash -lc '
      set -euo pipefail
      test -f /etc/security/keytabs/longhd.user.keytab
      test -f /etc/security/keytabs/kido.user.keytab
      kadmin.local -q "listprincs" >/dev/null 2>&1
    '; then
      pass "KDC is ready and keytabs are present"
      return 0
    fi
    now=$(date +%s)
    if (( now >= deadline )); then
      fail "Timed out waiting for KDC readiness and keytabs"
    fi
    sleep "$WAIT_INTERVAL_SECONDS"
  done
}

wait_for_hdfs_ready() {
  local deadline now
  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while :; do
    if compose exec -T namenode bash -lc "hdfs dfsadmin -safemode get >/dev/null 2>&1"; then
      pass "NameNode/HDFS command path is responsive"
      return 0
    fi
    now=$(date +%s)
    if (( now >= deadline )); then
      fail "Timed out waiting for HDFS readiness"
    fi
    sleep "$WAIT_INTERVAL_SECONDS"
  done
}

echo "[1/7] wait for services"
wait_for_services_running
wait_for_kdc_ready
wait_for_hdfs_ready

echo "[2/7] kinit as longhd and upload file"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/longhd.user.keytab longhd@HADOOP.LAB
  echo "smoke test written by longhd" > /tmp/smoke_test_longhd.txt
  hdfs dfs -mkdir -p /secure-lab
  hdfs dfs -chmod 755 /secure-lab
  hdfs dfs -put -f /tmp/smoke_test_longhd.txt /secure-lab/smoke_test_longhd.txt
  hdfs dfs -chmod 644 /secure-lab/smoke_test_longhd.txt
'
pass "longhd created /secure-lab/smoke_test_longhd.txt"

echo "[3/7] verify owner is longhd"
owner=$(compose exec -T namenode bash -lc 'hdfs dfs -stat %u /secure-lab/smoke_test_longhd.txt' | tr -d '\r')
if [[ "$owner" != "longhd" ]]; then
  fail "Expected owner=longhd, got owner=${owner}"
fi
pass "Owner check passed (longhd)"

echo "[4/7] kinit as kido"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/kido.user.keytab kido@HADOOP.LAB
  klist
' >/dev/null
pass "kido Kerberos login succeeded"

echo "[5/7] verify kido can read when permissions allow"
read_value=$(compose exec -T namenode bash -lc 'hdfs dfs -cat /secure-lab/smoke_test_longhd.txt' | tr -d '\r')
if [[ "$read_value" != "smoke test written by longhd" ]]; then
  fail "kido read check failed. Expected file content not returned."
fi
pass "kido read allowed as expected"

echo "[6/7] verify kido cannot overwrite when permissions deny"
if compose exec -T namenode bash -lc 'echo "should fail overwrite" > /tmp/smoke_test_kido.txt && hdfs dfs -put -f /tmp/smoke_test_kido.txt /secure-lab/smoke_test_longhd.txt'; then
  fail "Unexpected success: kido overwrote longhd file"
fi
pass "kido overwrite denied as expected"

echo "[7/7] verify kido cannot delete when permissions deny"
if compose exec -T namenode bash -lc 'hdfs dfs -rm -f /secure-lab/smoke_test_longhd.txt'; then
  fail "Unexpected success: kido deleted longhd file"
fi
pass "kido delete denied as expected"

echo "PASS: Kerberos smoke test completed (${PASS_COUNT} checks passed)"
