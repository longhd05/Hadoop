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

krb5kdc
exec kadmind -nofork
