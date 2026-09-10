with open('docker-compose.yml') as f:
    content = f.read()
with open('dnd-saves-api/service-block.yml') as f:
    block = f.read()
marker = '\nvolumes:\n'
idx = content.find(marker)
if idx == -1:
    print('ERROR: marker not found, nothing changed')
else:
    new_content = content[:idx+1] + block + content[idx+1:]
    with open('docker-compose.yml', 'w') as f:
        f.write(new_content)
    print('Inserted successfully')
