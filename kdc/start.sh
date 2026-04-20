#!/usr/bin/env bash
set -euo pipefail

REALM=${REALM:-HADOOP.LAB}
KDC_DB_PASSWORD=${KDC_DB_PASSWORD:-masterpw}

if [ ! -f /var/lib/krb5kdc/principal ]; then
  kdb5_util create -s -r "$REALM" -P "$KDC_DB_PASSWORD"
fi

if [ ! -f /etc/security/keytabs/.bootstrapped ]; then
  /bootstrap-principals.sh
fi

krb5kdc -n &
KRB5KDC_PID=$!
kadmind -nofork &
KADMIND_PID=$!

cleanup() {
  kill "$KRB5KDC_PID" "$KADMIND_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

wait -n "$KRB5KDC_PID" "$KADMIND_PID"
exit $?
