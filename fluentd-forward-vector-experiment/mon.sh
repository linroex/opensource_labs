#!/bin/bash
while true; do
  curl -s http://127.0.0.1:24220/api/plugins.json | python3 -c "
import sys,json,time
d=json.load(sys.stdin)
for p in d['plugins']:
    if p['type']=='forward' and p.get('output_plugin'):
        print(time.strftime('%H:%M:%S'),'queue_len=%s queued_MB=%.1f retry_count=%s num_errors=%s emit=%s'%(p['buffer_queue_length'],p['buffer_total_queued_size']/1048576,p['retry_count'],p.get('num_errors'),p.get('emit_count')),flush=True)
" 2>>logs/mon_err.log
  sleep 2
done
