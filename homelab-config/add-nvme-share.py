with open('docker-compose.yml') as f:
    lines = f.readlines()

target = '-s "homelab;/home/di0__0ib/homelab;yes;no;no;${SAMBA_USER}"'
idx = None
indent = None
for i, line in enumerate(lines):
    if target in line:
        idx = i
        indent = line[:len(line) - len(line.lstrip())]
        break

if idx is None:
    print('ERROR: marker not found, nothing changed')
else:
    new_line = f'{indent}-s "nvme1tb;/mnt/nvme1tb;yes;no;no;${{SAMBA_USER}}"\n'
    lines.insert(idx + 1, new_line)
    with open('docker-compose.yml', 'w') as f:
        f.writelines(lines)
    print('Inserted successfully, matched indent:', repr(indent))
