'use strict';
import { readfile, writefile, popen } from 'fs';
import { cursor } from 'uci';
const DIR = '/tmp/e5-ipv6-fix';
function sh(cmd) { let p = popen(cmd, 'r'); if (!p) return ''; let s = p.read('all'); p.close(); return trim(s ?? ''); }
function quote(s) { return "'" + replace(s, /'/g, "'\\''") + "'"; }
function readjson(path) { try { return json(readfile(path) ?? 'null'); } catch(e) { return null; } }
let u = cursor(), last = readjson(DIR + '/result.json');
let interval = int(u.get('e5-plugin-ipv6-fix', 'settings', 'interval') ?? '3600');
if (interval < 60 || interval > 43200) interval = 3600;
if (ARGV[0] == 'auto' && readfile(DIR + '/schedule') == null) exit(0);
function log(strategy, message) {
 let previous = readfile(DIR + '/log.txt') ?? '';
 writefile(DIR + '/log.txt', substr(previous, -60000) + sprintf('%d %s: %s\n', time(), strategy, message));
}
function finish(ok, strategy, message) {
 if (ok && ARGV[0] != 'delete') {
  let connected = system('timeout 4 ping -6 -c 1 -W 3 2400:3200::1 >/dev/null 2>&1') == 0;
  if (!connected) { ok = false; strategy = 'connectivity_failed'; message = 'Route updated but IPv6 connectivity check failed'; }
 }
 let r = { ok, strategy, message, time: time() };
 writefile(DIR + '/result.json', sprintf('%J\n', r));
 if (ok && index(['nd_renew', 'nd_rebuild', 'ra_replace', 'ra_replace_min', 'route_available', 'ra_discovered'], strategy) >= 0)
  writefile(DIR + '/strategy.json', sprintf('%J\n', r));
 log(strategy, message);
 exit(ok ? 0 : 1);
}
function routes(dev) {
 return filter(split(sh('ip -6 route show table all'), '\n'), l => match(l, /^default (from [^ ]+ )?via fe80:/) && index(l + ' ', ' dev ' + dev + ' ') >= 0);
}
function expiry(line) { let m = match(line ?? '', /expires (-?[0-9]+)sec/); return m ? int(m[1]) : null; }
let wan;
try { wan = json(sh('ubus call network.interface.wan status')); } catch(e) {}
let dev = wan?.l3_device;
if (!wan?.up || !match(dev ?? '', /^sipa_eth[0-9]+$/)) finish(false, 'skipped', 'No active cellular WAN');
let before = routes(dev);
if (length(before) > 1) finish(false, 'skipped', 'Multiple default routes: refusing ambiguous replacement');
let route = before[0];
if (route && match(route, / from /)) finish(false, 'skipped', 'Source-specific default route: refusing broad replacement');
let gw = match(route ?? '', / via ([0-9a-fA-F:]+) /), metric = match(route ?? '', / metric ([0-9]+)/), table = match(route ?? '', / table ([a-zA-Z0-9_-]+)/), hop = match(route ?? '', / hoplimit ([0-9]+)/), pref = match(route ?? '', / pref (low|medium|high)/);
let selector = gw ? 'default via ' + quote(gw[1]) + ' dev ' + quote(dev) + ' table ' + quote(table ? table[1] : 'main') + (metric ? ' metric ' + int(metric[1]) : '') : '';
if (ARGV[0] == 'delete') {
 if (!route) finish(true, 'delete_none', 'No default route to delete');
 if (system('ip -6 route del ' + selector + ' >/dev/null 2>&1') != 0) finish(false, 'delete_failed', 'Cannot delete default route');
 finish(length(routes(dev)) == 0, 'deleted', 'Default route deleted; request RA to rebuild it');
}
let lease = readjson(DIR + '/lease.json');
let remaining = expiry(route);
let margin = lease?.device == dev && lease.gateway == (gw ? gw[1] : null) ? int(lease.lifetime / 5) : 300;
if (margin < 120) margin = 120;
if (margin > 300) margin = 300;
// The runtime scheduler checks every five seconds. Do not let the configured interval outlive RA.
let elapsed = last ? time() - last.time : interval;
let reason = !last ? 'initial' : !last.ok ? 'retry' : remaining == null ? 'missing_expiry' : remaining <= margin ? 'lease_expiring' : elapsed >= interval ? 'interval' : 'health_check';
if (ARGV[0] == 'auto') {
 if (last && !last.ok && elapsed < 60) exit(0);
 if (last?.ok && elapsed < interval && remaining != null && remaining > margin) {
  // Health probes need not run on every scheduler tick.
  let health = readjson(DIR + '/health.json');
  if (health && health.time <= time() && time() - health.time < 60 && health.ok) exit(0);
  let connected = system('timeout 4 ping -6 -c 1 -W 3 2400:3200::1 >/dev/null 2>&1') == 0;
  writefile(DIR + '/health.json', sprintf('%J\n', {ok:connected,time:time()}));
  if (connected) exit(0);
  reason = 'connectivity_failed';
 }
 log('schedule_due', sprintf('reason=%s interval=%ds elapsed=%ds remaining=%s', reason, interval, elapsed, remaining == null ? 'none' : '' + remaining));
}
let addresses = sh('ip -6 addr show dev ' + quote(dev) + ' scope global');
if (!length(addresses)) finish(false, 'skipped', 'No global IPv6 address on cellular WAN');
let rdisc6 = sh('if [ "$(uname -m)" = aarch64 ] && [ -x /etc/e5-infoscreen/plugins/ipv6-fix/bin/rdisc6 ]; then echo /etc/e5-infoscreen/plugins/ipv6-fix/bin/rdisc6; else command -v rdisc6; fi');
if (!length(rdisc6)) finish(false, 'no_ra', 'rdisc6 unavailable; existing route left intact');
log('rs', 'Requesting fresh RA without deleting the existing route');
let reply = sh('LC_ALL=C timeout 10 ' + quote(rdisc6) + ' -1 -n -r 2 -w 3000 ' + quote(dev) + ' 2>/dev/null');
let sender = match(reply, /\n from (fe80:[0-9a-fA-F:]+)[ \t]*(\n|$)/);
let lifetime = match(reply, /Router lifetime[ \t]*:[ \t]*([0-9]+)/);
let preference = match(reply, /Router preference[ \t]*:[ \t]*(low|medium|high)/);
if (!sender || !lifetime || int(lifetime[1]) <= 0 || int(lifetime[1]) > 65535)
 finish(false, 'no_ra', 'No positive-lifetime RA received; existing route left intact');
let advertised = { device: dev, gateway: sender[1], lifetime: int(lifetime[1]), time: time() };
let currentWan;
try { currentWan = json(sh('ubus call network.interface.wan status')); } catch(e) {}
let current = routes(dev);
if (!currentWan?.up || currentWan.l3_device != dev || length(current) > 1 || match(current[0] ?? '', / from /))
 finish(false, 'skipped', 'WAN or routes changed during RA discovery; retry refresh');
// Refuse to overwrite an unrelated route installed while the RS was in flight.
if (current[0] && current[0] != route && !match(current[0], / proto ra /))
 finish(false, 'skipped', 'Default route changed during RA discovery; retry refresh');
writefile(DIR + '/lease.json', sprintf('%J\n', advertised));
log('ra_received', sprintf('Received RA from %s on %s, lifetime %d seconds', advertised.gateway, dev, advertised.lifetime));
let currentGw = match(current[0] ?? '', / via ([0-9a-fA-F:]+) /), exp = expiry(current[0]);
// A genuine native renewal can be kept, provided its expiry matches this RA.
if ((currentGw ? currentGw[1] : null) == advertised.gateway && exp != null && exp > 0 && exp <= advertised.lifetime && exp >= advertised.lifetime - 5 && (remaining == null || exp > remaining))
 finish(true, 'nd_renew', current[0]);
// accept_ra=0 and static routes need userspace renewal. Keep table/metric; use only this fresh RA's lifetime.
let cmd = 'ip -6 route ' + (length(current) ? 'replace' : 'add') + ' default via ' + quote(advertised.gateway) + ' dev ' + quote(dev) + ' table ' + quote(table ? table[1] : 'main');
cmd += ' proto ra metric ' + (metric ? int(metric[1]) : 1024) + ' expires ' + advertised.lifetime;
if (hop) cmd += ' hoplimit ' + int(hop[1]);
cmd += ' pref ' + (preference ? preference[1] : 'medium');
if (system(cmd + ' >/dev/null 2>&1') != 0) finish(false, 'failed', 'Cannot install default route from fresh RA');
let after = routes(dev), newexp = expiry(after[0]), newgw = match(after[0] ?? '', / via ([0-9a-fA-F:]+) /);
finish(length(after) == 1 && (newgw ? newgw[1] : null) == advertised.gateway && newexp != null && newexp > 0 && newexp <= advertised.lifetime && newexp >= advertised.lifetime - 5,
 route ? 'ra_replace' : 'ra_discovered', after[0] ?? 'Route readback failed');
