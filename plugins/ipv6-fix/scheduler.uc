'use strict';
import { readfile, writefile } from 'fs';
// The launcher holds scheduler.lock for this process's lifetime. No boot service or cron entry.
const DIR = '/tmp/e5-ipv6-fix';
const BASE = '/etc/e5-infoscreen/plugins/ipv6-fix';
let next = 0;
while (readfile(DIR + '/schedule') != null && readfile(BASE + '/worker.uc') != null) {
 writefile(DIR + '/scheduler.json', sprintf('%J\n', {time:time()}));
 if (time() >= next) {
  system('flock -n ' + DIR + '/lock timeout 55 /usr/bin/ucode ' + BASE + '/worker.uc auto >/dev/null 2>&1');
  next = time() + 5;
 }
 system('sleep 1');
}
