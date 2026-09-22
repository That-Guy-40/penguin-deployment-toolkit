#!/bin/bash
# usage: shot.sh <name>  -> scratchpad/vm/<name>.png via QEMU monitor screendump
S=/tmp/claude-1000/-home-sqs-scripts-Windows-install-via-Linux/db333f61-18fb-420a-8c91-36dad1f2e3d0/scratchpad
MP=$(awk '{print $3}' $S/vm/monport)
printf 'screendump %s/vm/%s.ppm\n' "$S" "$1" | socat -t 2 - TCP:127.0.0.1:$MP >/dev/null
sleep 1
python3 -c "from PIL import Image; im=Image.open('$S/vm/$1.ppm'); im.save('$S/vm/$1.png'); print(im.size)"
