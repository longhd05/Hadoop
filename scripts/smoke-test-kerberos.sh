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
    if compose exec -T kdc bash -lc "test -f /etc/security/keytabs/usera.user.keytab && test -f /etc/security/keytabs/userb.user.keytab && kadmin.local -q 'listprincs' >/dev/null 2>&1"; then
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

echo "[2/7] kinit as usera and upload file"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/usera.user.keytab usera@HADOOP.LAB
  echo "smoke test written by usera" > /tmp/smoke_test_usera.txt
  hdfs dfs -mkdir -p /secure-lab
  hdfs dfs -chmod 755 /secure-lab
  hdfs dfs -put -f /tmp/smoke_test_usera.txt /secure-lab/smoke_test_usera.txt
  hdfs dfs -chmod 644 /secure-lab/smoke_test_usera.txt
'
pass "usera created /secure-lab/smoke_test_usera.txt"

echo "[3/7] verify owner is usera"
owner=$(compose exec -T namenode bash -lc 'hdfs dfs -stat %u /secure-lab/smoke_test_usera.txt' | tr -d '\r')
if [[ "$owner" != "usera" ]]; then
  fail "Expected owner=usera, got owner=${owner}"
fi
pass "Owner check passed (usera)"

echo "[4/7] kinit as userb"
compose exec -T namenode bash -lc '
  set -euo pipefail
  kdestroy >/dev/null 2>&1 || true
  kinit -kt /etc/security/keytabs/userb.user.keytab userb@HADOOP.LAB
  klist
' >/dev/null
pass "userb Kerberos login succeeded"

echo "[5/7] verify userb can read when permissions allow"
read_value=$(compose exec -T namenode bash -lc 'hdfs dfs -cat /secure-lab/smoke_test_usera.txt' | tr -d '\r')
if [[ "$read_value" != "smoke test written by usera" ]]; then
  fail "userb read check failed. Expected file content not returned."
fi
pass "userb read allowed as expected"

echo "[6/7] verify userb cannot overwrite when permissions deny"
if compose exec -T namenode bash -lc 'echo "should fail overwrite" > /tmp/smoke_test_userb.txt && hdfs dfs -put -f /tmp/smoke_test_userb.txt /secure-lab/smoke_test_usera.txt'; then
  fail "Unexpected success: userb overwrote usera file"
fi
pass "userb overwrite denied as expected"

echo "[7/7] verify userb cannot delete when permissions deny"
if compose exec -T namenode bash -lc 'hdfs dfs -rm -f /secure-lab/smoke_test_usera.txt'; then
  fail "Unexpected success: userb deleted usera file"
fi
pass "userb delete denied as expected"

echo "PASS: Kerberos smoke test completed (${PASS_COUNT} checks passed)"
