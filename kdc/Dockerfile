FROM debian:12-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      krb5-kdc \
      krb5-admin-server \
      krb5-user \
      bash \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/security/keytabs /etc/krb5kdc /var/lib/krb5kdc

COPY start.sh /start.sh
COPY bootstrap-principals.sh /bootstrap-principals.sh
RUN chmod +x /start.sh /bootstrap-principals.sh

EXPOSE 88 749

CMD ["/start.sh"]
