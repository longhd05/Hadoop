#!/usr/bin/env bash
set -euo pipefail

REALM=${REALM:-HADOOP.LAB}
KADMIN_PRINCIPAL=${KADMIN_PRINCIPAL:-admin/admin@${REALM}}
KADMIN_PASSWORD=${KADMIN_PASSWORD:-adminpw}
USERA_PASSWORD=${USERA_PASSWORD:-userapw}
USERB_PASSWORD=${USERB_PASSWORD:-userbpw}
KEYTAB_DIR=${KEYTAB_DIR:-/etc/security/keytabs}
umask 077

mkdir -p "$KEYTAB_DIR"
chmod 700 "$KEYTAB_DIR"

add_password_principal() {
  local principal=$1
  local password=$2
  if ! kadmin.local -q "getprinc ${principal}" >/dev/null 2>&1; then
    kadmin.local -q "addprinc -pw ${password} ${principal}"
  fi
}

add_service_principal() {
  local principal=$1
  if ! kadmin.local -q "getprinc ${principal}" >/dev/null 2>&1; then
    kadmin.local -q "addprinc -randkey ${principal}"
  fi
}

add_password_principal "$KADMIN_PRINCIPAL" "$KADMIN_PASSWORD"
add_password_principal "usera@${REALM}" "$USERA_PASSWORD"
add_password_principal "userb@${REALM}" "$USERB_PASSWORD"

services=(
  "nn/namenode.hadoop.lab@${REALM}:nn.service.keytab"
  "dn/datanode.hadoop.lab@${REALM}:dn.service.keytab"
  "rm/resourcemanager.hadoop.lab@${REALM}:rm.service.keytab"
  "nm/nodemanager.hadoop.lab@${REALM}:nm.service.keytab"
  "jhs/historyserver.hadoop.lab@${REALM}:jhs.service.keytab"
)

for entry in "${services[@]}"; do
  principal=${entry%%:*}
  keytab=${entry##*:}
  add_service_principal "$principal"
  rm -f "${KEYTAB_DIR}/${keytab}"
  kadmin.local -q "ktadd -k ${KEYTAB_DIR}/${keytab} ${principal}"
done

rm -f "${KEYTAB_DIR}/spnego.service.keytab"
for host in namenode.hadoop.lab datanode.hadoop.lab resourcemanager.hadoop.lab nodemanager.hadoop.lab historyserver.hadoop.lab; do
  principal="HTTP/${host}@${REALM}"
  add_service_principal "$principal"
  kadmin.local -q "ktadd -k ${KEYTAB_DIR}/spnego.service.keytab ${principal}"
done

rm -f "${KEYTAB_DIR}/usera.user.keytab"
rm -f "${KEYTAB_DIR}/userb.user.keytab"
kadmin.local -q "ktadd -k ${KEYTAB_DIR}/usera.user.keytab usera@${REALM}"
kadmin.local -q "ktadd -k ${KEYTAB_DIR}/userb.user.keytab userb@${REALM}"

if [ ! -f "${KEYTAB_DIR}/http-secret" ]; then
  head -c 32 /dev/urandom | base64 > "${KEYTAB_DIR}/http-secret"
fi

test -s "${KEYTAB_DIR}/http-secret"
chmod 600 "${KEYTAB_DIR}"/*.keytab "${KEYTAB_DIR}/http-secret"
touch "${KEYTAB_DIR}/.bootstrapped"
