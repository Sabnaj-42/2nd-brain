import re, glob, sys

anchor = re.compile(r"^(\s*)\{ echo 'local\s+all\s+all\s+trust'; \} >>\s*/tmp/pg_hba\.conf")
added = 0
files = 0
for f in glob.glob("extract/tmp/**/*.sh", recursive=True):
    with open(f) as fh:
        lines = fh.readlines()
    out = []
    changed = False
    for ln in lines:
        out.append(ln)
        m = anchor.match(ln)
        if m:
            ind = m.group(1)
            # co-located gateway/coordinator reach Postgres over localhost; trust it
            out.append(f"{ind}{{ echo 'host       all             all             127.0.0.1/32            trust'; }} >>/tmp/pg_hba.conf\n")
            out.append(f"{ind}{{ echo 'host       all             all             ::1/128                 trust'; }} >>/tmp/pg_hba.conf\n")
            changed = True
            added += 1
    if changed:
        with open(f, "w") as fh:
            fh.writelines(out)
        files += 1
        print("patched:", f)
print(f"files={files} anchors_patched={added}")
