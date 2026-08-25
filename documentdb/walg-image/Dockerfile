# DocumentDB + wal-g
#
# Neither upstream image can complete an object-storage PITR on its own:
#   documentdb-local    has the pg_documentdb extension libraries, but no wal-g
#   postgres-archiver   has wal-g, but cannot start a DocumentDB data directory
#
# This combines them so a single container can run the recovering Postgres AND
# serve restore_command = 'wal-g wal-fetch %f %p'.

FROM ghcr.io/kubedb/postgres-archiver:v0.27.0_17.2-bookworm AS archiver

FROM ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0
USER root
COPY --from=archiver /usr/bin/wal-g /usr/bin/wal-g
RUN chmod 0755 /usr/bin/wal-g
USER documentdb
