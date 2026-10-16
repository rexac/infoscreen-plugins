'use strict';
import { readfile, writefile, rename, unlink } from 'fs';
const DIR = '/tmp/e5-ipv6-fix';
const BASE = '/etc/e5-infoscreen/plugins/ipv6-fix';
function plan(requested, lifetime) {
 // Whole wall-clock slots; round down so cron never exceeds the requested or safe interval.
 let cap = requested;
 if (lifetime > 0) {
  let margin = int(lifetime / 5);
  if (margin < 120) margin = 120;
  if (margin > 300) margin = 300;
  if (lifetime - margin < cap) cap = lifetime - margin;
 } else if (cap > 300) cap = 300; // Discover the lease before allowing a long interval.
 let minutes = 1;
 for (let n in [1,2,3,4,5,6,10,12,15,20,30,60,120,180,240,360,480,720])
  if (n * 60 <= cap) minutes = n;
 let expression = minutes < 60 ? (minutes == 1 ? '*' : '*/' + minutes) + ' * * * *' :
  '0 ' + (minutes == 60 ? '*' : '*/' + int(minutes / 60)) + ' * * *';
 return { requested, interval: minutes * 60, expression, lifetime: lifetime > 0 ? lifetime : null };
}
function configure(enabled, requested, lifetime) {
 let path = '/etc/crontabs/root', previous = readfile(path) ?? '';
 let lines = filter(split(previous, '\n'), l => length(l) && !match(l, /# e5-ipv6-fix[ \t]*$/));
 let p = plan(requested, lifetime);
 if (enabled) push(lines, p.expression + ' mkdir -p ' + DIR + ' && flock -n ' + DIR + '/lock timeout 55 /usr/bin/ucode ' + BASE + '/worker.uc cron >/dev/null 2>&1 # e5-ipv6-fix');
 let content = length(lines) ? join('\n', lines) + '\n' : '';
 if (content != previous) {
  if (writefile(path + '.ipv6-fix', content) == null || !rename(path + '.ipv6-fix', path)) return null;
  // OpenWrt's crond reads this notification without restarting unrelated cron jobs.
  if (!writefile('/etc/crontabs/cron.update', 'root\n')) return null;
 }
 if (enabled) {
  if (!writefile(DIR + '/cron.json', sprintf('%J\n', p))) return null;
 } else unlink(DIR + '/cron.json');
 return p;
}
function current(requested) {
 let lines = filter(split(readfile('/etc/crontabs/root') ?? '', '\n'), l => match(l, /# e5-ipv6-fix[ \t]*$/));
 if (length(lines) != 1) return null;
 let fields = split(lines[0], /[ \t]+/), minutes = 0;
 if (fields[1] == '*') {
  if (fields[0] == '*') minutes = 1;
  else if (fields[0] == '0') minutes = 60;
  else if (match(fields[0], /^\*\/[0-9]+$/)) minutes = int(substr(fields[0], 2));
 } else if (fields[0] == '0' && match(fields[1], /^\*\/[0-9]+$/)) minutes = int(substr(fields[1], 2)) * 60;
 if (minutes < 1 || minutes > 720) return null;
 return { requested, interval:minutes * 60, expression:join(' ',slice(fields,0,5)) };
}
function wait(p, now) {
 let local = localtime(now), minutes = int(p.interval / 60);
 let elapsed = (minutes < 60 ? local.min % minutes : (local.hour % int(minutes / 60)) * 60 + local.min) * 60 + local.sec;
 return p.interval - elapsed;
}
return { plan, configure, current, wait };
