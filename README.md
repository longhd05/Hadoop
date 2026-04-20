# Hadoop Docker (Kerberized multi-user lab)

This fork keeps the original docker-compose flow and adds a full Hadoop secure-mode lab:
- Kerberos for Hadoop RPC/service auth
- HTTP SPNEGO for Hadoop web UIs and WebHDFS
- HDFS permissions enforcement
- per-user HDFS ownership based on Kerberos identity
- hostname/FQDN-based access for browser SPNEGO

## Quick Start

```bash
docker compose up -d --build
```

Then verify the cluster and multi-user ownership behavior:

```bash
./scripts/verify-multiuser-hdfs.sh
```

The verification script also checks effective runtime values for:
- `hadoop.security.authentication=kerberos`
- `hadoop.security.authorization=true`
- `dfs.permissions.enabled=true`
- unauthenticated WebHDFS `user.name=` access is rejected (`401`)

## Hostnames to add in `/etc/hosts`

Use the host/IP your browser reaches for published Docker ports:
- native Linux Docker on VM: use the VM IP (example: `10.10.10.156`)
- Docker Desktop: use `127.0.0.1` or the Desktop-exposed host/IP for published ports

Add the same mapping on:
1. the Ubuntu VM running Docker
2. the client machine/browser

```text
10.10.10.156 namenode.hadoop.lab
10.10.10.156 datanode.hadoop.lab
10.10.10.156 resourcemanager.hadoop.lab
10.10.10.156 nodemanager.hadoop.lab
10.10.10.156 historyserver.hadoop.lab
10.10.10.156 kdc.hadoop.lab
```

If you run Docker Desktop instead of native Linux Docker, use the IP/hostname that your browser can route to the published ports (not container-internal IPs).

## Web UI endpoints (FQDN-based)

- NameNode: `http://namenode.hadoop.lab:9870/dfshealth.html#tab-overview`
- HistoryServer: `http://historyserver.hadoop.lab:8188/applicationhistory`
- DataNode: `http://datanode.hadoop.lab:9864/`
- NodeManager: `http://nodemanager.hadoop.lab:8042/node`
- ResourceManager: `http://resourcemanager.hadoop.lab:8088/`

## Kerberos principals and keytabs

A lab KDC container bootstraps realm `HADOOP.LAB` and writes keytabs into a shared Docker volume mounted at `/etc/security/keytabs`.

Generated service principals:
- `nn/namenode.hadoop.lab@HADOOP.LAB`
- `dn/datanode.hadoop.lab@HADOOP.LAB`
- `rm/resourcemanager.hadoop.lab@HADOOP.LAB`
- `nm/nodemanager.hadoop.lab@HADOOP.LAB`
- `jhs/historyserver.hadoop.lab@HADOOP.LAB`
- `HTTP/<service-fqdn>@HADOOP.LAB` for SPNEGO

Generated user principals:
- `usera@HADOOP.LAB`
- `userb@HADOOP.LAB`

## `kinit` examples (userA/userB)

From inside a Hadoop container (example: NameNode):

```bash
docker compose exec namenode kinit -kt /etc/security/keytabs/usera.user.keytab usera@HADOOP.LAB
docker compose exec namenode klist

docker compose exec namenode kinit -kt /etc/security/keytabs/userb.user.keytab userb@HADOOP.LAB
docker compose exec namenode klist
```

## Firefox SPNEGO setup

In `about:config` set:

- `network.negotiate-auth.trusted-uris` = `.hadoop.lab`
- `network.negotiate-auth.delegation-uris` = `.hadoop.lab` (optional for delegation)
- `network.negotiate-auth.allow-non-fqdn` = `false`

Authenticate on the client first (`kinit usera@HADOOP.LAB`), then open the FQDN UI URLs.

## WebHDFS/UI auth checks

With Kerberos ticket in the client shell:

```bash
kinit usera@HADOOP.LAB
curl --negotiate -u : "http://namenode.hadoop.lab:9870/webhdfs/v1/?op=LISTSTATUS"
```

For browser checks, open NameNode/ResourceManager/HistoryServer FQDN URLs and confirm they challenge/accept SPNEGO rather than static web user auth.

Negative check (must fail if not authenticated):

```bash
curl -i "http://namenode.hadoop.lab:9870/webhdfs/v1/?op=GETHOMEDIRECTORY&user.name=usera"
```

Expected: `401 Unauthorized` (not an authenticated userA response).

## Verify HDFS owner/group/permissions

Create a file as `usera` and check owner/group/permissions:

```bash
docker compose exec namenode bash -lc 'kinit -kt /etc/security/keytabs/usera.user.keytab usera@HADOOP.LAB && echo hello >/tmp/u1.txt && hdfs dfs -put -f /tmp/u1.txt /secure-lab/u1.txt && hdfs dfs -ls /secure-lab'
```

Ownership should show `usera` as file owner.

Then verify `userb` cannot overwrite/delete unless permissions allow:

```bash
docker compose exec namenode bash -lc 'kinit -kt /etc/security/keytabs/userb.user.keytab userb@HADOOP.LAB && echo blocked >/tmp/u2.txt && hdfs dfs -put -f /tmp/u2.txt /secure-lab/u1.txt'
```

Expected: permission denied unless ACL/mode grants write.

Full end-to-end (recommended):

```bash
./scripts/verify-multiuser-hdfs.sh
```

## Non-obvious implementation notes

- The repo still uses env-to-XML mapping (`CORE_CONF_`, `HDFS_CONF_`, `YARN_CONF_`, `MAPRED_CONF_`); Kerberos/SPNEGO settings are provided through the same mechanism.
- `dfs.permissions.enabled` is set to `true`.
- `hadoop.security.authentication=kerberos` and `hadoop.http.authentication.type=kerberos` are both enabled so identity comes from Kerberos/SPNEGO, not simple-auth fallback.
- `hadoop.http.staticuser.user=nobody` is set to avoid accidental reliance on privileged static web identity.
- No reverse-proxy identity substitution is used as the source of truth for HDFS ownership.
- HTTP SPNEGO uses `HTTP/_HOST@HADOOP.LAB`; each service runs with a hostname/FQDN matching the generated principals.
- Never use raw IP URLs for SPNEGO endpoints; principal matching is hostname-based (`HTTP/<fqdn>@REALM`).
- KDC-generated keytabs are stored with restrictive permissions (`0700` dir, `0600` files); this is lab-grade, not production-grade secret handling.

## Likely runtime breakpoints and debugging

1. **KDC unhealthy / principals not created**
   - `docker compose logs -f kdc`
   - `docker compose exec kdc kadmin.local -q "listprincs"`
2. **Service keytab missing in Hadoop container**
   - `docker compose exec namenode ls -l /etc/security/keytabs`
3. **Principal/hostname mismatch (`Server not found in Kerberos database`)**
   - `docker compose exec namenode hostname -f`
   - `docker compose exec namenode klist -k /etc/security/keytabs/nn.service.keytab`
4. **FQDN not resolvable from VM/client**
   - `getent hosts namenode.hadoop.lab`
   - ensure `/etc/hosts` entries exist on both VM and client
5. **SPNEGO browser login loop**
   - verify Firefox `network.negotiate-auth.trusted-uris=.hadoop.lab`
   - ensure URL is FQDN, not IP/localhost alias mismatch
6. **WebHDFS accepts `user.name` without Kerberos (unexpected)**
   - `curl -i "http://namenode.hadoop.lab:9870/webhdfs/v1/?op=GETHOMEDIRECTORY&user.name=usera"`
   - should be `401`; if not, inspect `core-site.xml` and `hdfs-site.xml`
7. **HDFS owner not mapped to short name**
   - `docker compose exec namenode hdfs dfs -stat %u /path/file`
   - `docker compose exec namenode klist`
8. **Permissions not enforced**
   - `docker compose exec namenode hdfs getconf -confKey dfs.permissions.enabled`
   - rerun `./scripts/verify-multiuser-hdfs.sh`
9. **Compose v3/swarm startup waits on wrong ports**
   - confirm v3 preconditions use NameNode `9870` and DataNode `9864`
10. **Cluster build fails before runtime (base image)**
    - `make build` currently fails on upstream Debian stretch apt repositories (`404`); use compose runtime with available images or update base image lineage separately.

## Configure Environment Variables mapping

Example:

```text
CORE_CONF_fs_defaultFS=hdfs://namenode.hadoop.lab:9000
```

`CORE_CONF` corresponds to `core-site.xml`. To define dash inside a configuration parameter, use triple underscore, such as:

```text
YARN_CONF_yarn_log___aggregation___enable=true
```

The available configuration prefixes are:
- `/etc/hadoop/core-site.xml` → `CORE_CONF`
- `/etc/hadoop/hdfs-site.xml` → `HDFS_CONF`
- `/etc/hadoop/yarn-site.xml` → `YARN_CONF`
- `/etc/hadoop/httpfs-site.xml` → `HTTPFS_CONF`
- `/etc/hadoop/kms-site.xml` → `KMS_CONF`
- `/etc/hadoop/mapred-site.xml` → `MAPRED_CONF`
