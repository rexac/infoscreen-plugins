'use strict';
import { readfile, writefile, rename, unlink } from 'fs';
return function(ctx) {
 const BASE = '/etc/e5-infoscreen/plugins/ipv6-fix';
 const DIR = '/tmp/e5-ipv6-fix';
 const JOB = '/usr/bin/ucode ' + BASE + '/worker.uc';
 const LOCKED = 'flock -n ' + DIR + '/lock ';
 const MARKER = DIR + '/schedule';
 function fail(message, code) { return { status: code ?? 500, type: 'application/json', body: sprintf('%J', { error: message }) }; }
 function saved(path) { try { return json(readfile(path) ?? 'null'); } catch(e) { return null; } }
 function logs() { return join('\n', slice(split(readfile(DIR + '/log.txt') ?? '', '\n'), -41)); }
 function interval() {
  let n = int(ctx.uci().get('e5-plugin-ipv6-fix', 'settings', 'interval') ?? '3600');
  return n >= 60 && n <= 43200 ? n : 3600;
 }
 function running() {
  let heartbeat = saved(DIR + '/scheduler.json');
  return readfile(MARKER) != null && heartbeat && time() - heartbeat.time < 70 &&
   ctx.run('flock -n ' + DIR + '/scheduler.lock true >/dev/null 2>&1') == 1;
 }
 function status() {
  let wan = ctx.ubus('network.interface.wan', 'status', {}) ?? {};
  let device = match(wan.l3_device ?? '', /^sipa_eth[0-9]+$/) ? wan.l3_device : null;
  let routes = ctx.sh('ip -6 route show table all') ?? '';
  let candidates = device ? filter(split(routes, '\n'), line => match(line, /^default (from [^ ]+ )?via fe80:/) && index(line + ' ', ' dev ' + device + ' ') >= 0) : [];
  let route = length(candidates) == 1 ? candidates[0] : null;
  let lease = saved(DIR + '/lease.json');
  let gateway = match(route ?? '', / via ([0-9a-fA-F:]+) /);
  let lifetime = lease?.device == device && lease.gateway == (gateway ? gateway[1] : null) && lease.lifetime > 0 && time() - lease.time <= lease.lifetime ? lease.lifetime : null;
  let exp = match(route ?? '', /expires (-?[0-9]+)sec/);
  let ping = ctx.state_get('ping6', 10);
  if (!ping) {
   ping = { ok: ctx.run('timeout 3 ping -6 -c 1 -W 2 2400:3200::1 >/dev/null 2>&1') == 0, time: time() };
   ctx.state_put('ping6', ping);
  }
  let enabled = running(), last = saved(DIR + '/result.json');
  let remaining = exp ? int(exp[1]) : null;
  let margin = lifetime ? int(lifetime / 5) : 300;
  if (margin < 120) margin = 120;
  if (margin > 300) margin = 300;
  let wait = last ? (last.ok ? last.time + interval() - time() : last.time + 60 - time()) : 0;
  if (last?.ok && remaining != null && remaining - margin < wait) wait = remaining - margin;
  if (last?.ok && (remaining == null || !ping.ok)) wait = 0;
  if (wait < 0) wait = 0;
  return { enabled, next_refresh_in: enabled ? wait : null,
   interval: interval(), device, operator: ctx.modem()?.operator, route, route_count: length(candidates),
   expires: exp ? int(exp[1]) : null, ra_lifetime: lifetime, ping6: ping, time: time(),
   strategy: saved(DIR + '/strategy.json'), result: saved(DIR + '/result.json'),
   rdisc6: length(trim(ctx.sh('if [ "$(uname -m)" = aarch64 ] && [ -x ' + BASE + '/bin/rdisc6 ]; then echo bundled; else command -v rdisc6; fi') ?? '')) > 0,
   flock: ctx.run('command -v flock >/dev/null 2>&1') == 0, routes, log: logs() };
 }
 function schedule(enabled) {
  if (ctx.run('command -v flock >/dev/null 2>&1 && mkdir -p ' + DIR) != 0) return fail('Install the OpenWrt flock package first');
  // Migrate old installations without touching unrelated cron jobs.
  let path = '/etc/crontabs/root', previous = readfile(path) ?? '';
  let lines = filter(split(previous, '\n'), l => !match(l, /# e5-ipv6-fix[ \t]*$/));
  let cleaned = join('\n', lines);
  if (cleaned != previous && (!writefile(path + '.ipv6-fix', cleaned) || !rename(path + '.ipv6-fix', path))) return fail('Cannot remove old scheduler cron entry');
  if (enabled) {
   if (!writefile(MARKER, '1\n')) return fail('Cannot start scheduler');
   if (!running() && ctx.run('nohup flock -n ' + DIR + '/scheduler.lock /usr/bin/ucode ' + BASE + '/scheduler.uc </dev/null >/dev/null 2>&1 &') != 0)
    return fail('Cannot start scheduler');
  } else unlink(MARKER);
  let u = ctx.uci();
  if (u.get('e5-plugin-ipv6-fix', 'settings')) { u.delete('e5-plugin-ipv6-fix', 'settings', 'enabled'); u.commit('e5-plugin-ipv6-fix'); }
  return { ok: true };
 }
 function launch(mode) {
  if (ctx.run('command -v flock >/dev/null 2>&1 && mkdir -p ' + DIR) != 0) return fail('Install the OpenWrt flock package first');
  if (ctx.run(LOCKED + 'timeout 55 ' + JOB + ' ' + mode + ' >/dev/null 2>&1 &') != 0) return fail('Cannot start task');
  return { ok: true, queued: true };
 }
 return {
  'GET /status': () => status(),
  'GET /log': () => ({ log: logs() }),
  'POST /refresh': () => launch('manual'),
  'POST /delete-route': req => req.body?.confirm == 'DELETE' ? launch('delete') : fail('Confirmation required', 400),
  'POST /log-clear': function(req) {
   if (ctx.run('mkdir -p ' + DIR + ' && timeout 3 flock ' + DIR + '/lock sh -c ' + "': > " + DIR + "/log.txt'") != 0) return fail('Cannot clear log while a task is running', 409);
   if (length(readfile(DIR + '/log.txt') ?? '')) return fail('Log file was not cleared');
   return { ok: true };
  },
  'POST /schedule': req => type(req.body?.enabled) == 'bool' ? schedule(req.body.enabled) : fail('enabled must be boolean', 400),
  'POST /interval': function(req) {
   let n = req.body?.interval;
   if (type(n) != 'int' || n < 60 || n > 43200 || n % 60) return fail('Interval must be 60–43200 seconds in whole minutes', 400);
   if (readfile('/etc/config/e5-plugin-ipv6-fix') == null && !writefile('/etc/config/e5-plugin-ipv6-fix', '# IPv6 route repair\n')) return fail('Cannot create configuration');
   let u = ctx.uci();
   if (!u.get('e5-plugin-ipv6-fix', 'settings')) u.set('e5-plugin-ipv6-fix', 'settings', 'settings');
   u.set('e5-plugin-ipv6-fix', 'settings', 'interval', '' + n);
   if (!u.commit('e5-plugin-ipv6-fix')) return fail('Cannot save interval');
   return { ok: true };
  }
 };
};
