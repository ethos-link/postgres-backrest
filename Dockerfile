ARG POSTGRES_VERSION=18.1
FROM postgres:${POSTGRES_VERSION}

# ensure setpriv works as expected
RUN set -eux; \
         \
        echo 'testing setpriv:' ; \
        setpriv --reuid=nobody --regid=nogroup --clear-groups id

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest gettext-base ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    rm /usr/local/bin/gosu 

RUN mkdir -p /etc/postgresql/conf.d \
 && chmod 750 /etc/postgresql \
 && mkdir -p -m 770 /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest /etc/pgbackrest/conf.d \
 && chown -R postgres:postgres /etc/postgresql /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest

USER postgres

COPY entrypoint.sh /usr/local/bin/pg-entrypoint.sh
COPY conf/postgresql.conf /etc/postgresql/postgresql.conf
COPY conf/pg_hba.conf /etc/postgresql/pg_hba.conf
COPY pgbackrest.conf.template /usr/local/share/pgbackrest/pgbackrest.conf.template

ENTRYPOINT ["pg-entrypoint.sh"]
CMD ["postgres"]
