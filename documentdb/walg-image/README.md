# documentdb + wal-g image

Neither upstream image can complete an object-storage PITR alone:

| | `documentdb-local:pg17-0.109.0` | `postgres-archiver:v0.27.0_17.2-bookworm` |
| --- | :---: | :---: |
| `wal-g` | MISSING | `/usr/bin/wal-g` |
| documentdb extension libs | yes | **none** |

`restore_command = 'wal-g wal-fetch %f %p'` needs wal-g on the PATH of the *recovering* Postgres,
and that Postgres must also load `pg_documentdb`. One image needs both.

## Build and push

```bash
docker build -t sabnaj/documentdb-walg:pg17-0.109.0 .

# verify BEFORE pushing — the two bases are different Debian releases
docker run --rm --entrypoint bash sabnaj/documentdb-walg:pg17-0.109.0 -lc \
  'ldd /usr/bin/wal-g; wal-g --version; ls /usr/lib/postgresql/17/lib/ | grep documentdb'
# expect: "not a dynamic executable"  (wal-g is a static Go binary)

docker push docker.io/sabnaj/documentdb-walg:pg17-0.109.0
```

## Use it

```bash
kubectl apply -f documentdbversion-walg.yaml
# then set  spec.version: 'pg17-0.109.0-walg'  on the DocumentDB CR
```

Changing `spec.version` updates the PetSet template but does **not** roll the pod — delete it to
force the roll, or the CR will report `Ready` while still running the old image.

Full procedure: `../../documentdb-walg-backup-command.md`.
