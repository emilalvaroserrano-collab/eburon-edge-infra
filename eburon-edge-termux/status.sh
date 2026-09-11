#!/data/data/com.termux/files/usr/bin/bash
for u in '8850/health' '8851/health' '8852/' '8853/v1/health' '8854/v1/health';do echo "--- $u";curl -sS --max-time 4 "http://127.0.0.1:$u"||true;echo;done
