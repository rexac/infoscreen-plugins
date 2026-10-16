'use strict';
import { readfile } from 'fs';
let source = readfile(ARGV[0] ?? 'plugins/ipv6-fix/worker.uc');
source = replace(source, "import { readfile, writefile, popen } from 'fs';", '');
source = replace(source, "import { cursor } from 'uci';", '');
let start = index(source, 'function sh(cmd)'), end = index(source, 'function quote(s)');
source = substr(source, 0, start) + substr(source, end);
source = replace(source, /exit\(ok \? 0 : 1\);/, 'die(sprintf("%J", r));');
source = replace(source, /exit\(0\);/g, 'die("idle");');
let route = 'default via fe80::1 dev sipa_eth0 proto ra metric 1024 expires 120sec pref medium';
let reply = '\nRouter preference : medium\nRouter lifetime : 3600 (0x00000e10) seconds\n from fe80::1\n';
function scenario(name, before, options, expected, writes) {
 let commands = [], stored = options.stored ?? {}, current = before, requests = 0;
 let env = {
  ARGV: [options.mode ?? 'manual'], cursor: () => ({ get: () => '3600' }),
  readfile: path => stored[path], writefile: (path, data) => { stored[path] = data; return length(data); },
  sh: cmd => {
   if (index(cmd, 'LC_ALL=C timeout 10 ') == 0) {
    requests++;
    if (options.native) current = replace(route, '120sec', '3600sec');
    return options.reply ?? reply;
   }
   if (index(cmd, 'if [') == 0) return options.no_binary ? '' : '/etc/e5-infoscreen/plugins/ipv6-fix/bin/rdisc6';
   if (index(cmd, 'ubus ') == 0) return requests && options.wan_changed ? '{"up":true,"l3_device":"sipa_eth1"}' : '{"up":true,"l3_device":"sipa_eth0"}';
   if (index(cmd, 'ip -6 addr') == 0) return 'inet6 2408::1/64 scope global';
   if (index(cmd, 'ip -6 route show') == 0) return current;
   die('Unexpected read: ' + cmd);
  },
  system: cmd => {
   push(commands, cmd);
   if (index(cmd, 'timeout 4 ping ') == 0) return options.ping_fail ? 1 : 0;
   if (index(cmd, 'ip -6 route del') == 0) { current = ''; return 0; }
   if (index(cmd, 'ip -6 route replace') == 0 || index(cmd, 'ip -6 route add') == 0) {
    if (options.write_fail) return 1;
    let lifetime = match(cmd, /expires ([0-9]+)/), gateway = match(cmd, /via '([^']+)'/);
    current = replace(replace(route, '120sec', lifetime[1] + 'sec'), 'fe80::1', gateway[1]); return 0;
   }
   die('Unexpected command: ' + cmd);
  }
 };
 let result;
 try { loadstring('return function(env) { let cursor=env.cursor, readfile=env.readfile, writefile=env.writefile, sh=env.sh, system=env.system, ARGV=env.ARGV;\n' + source + '\n};', { raw_mode:true })()(env); }
 catch(e) { try { result=json(e.message ?? e); } catch(ignore) { result={strategy:e.message ?? e}; } }
 assert(result?.strategy == expected, name + ': ' + sprintf('%J', result));
 let mutations = filter(commands, c => index(c, 'ip -6 route ') == 0);
 assert(length(mutations) == writes, name + ': unexpected route writes');
 if (writes && options.mode != 'delete') {
  assert(index(mutations[0], 'expires ' + (options.lifetime ?? 3600)) >= 0, name + ': not using advertised lifetime');
  assert(index(mutations[0], 'route del') < 0, name + ': renewal deleted working route');
 }
 if (expected == 'ra_discovered' || expected == 'ra_replace') {
  assert(result.ok, name + ': connectivity was not verified');
  assert(json(stored['/tmp/e5-ipv6-fix/lease.json']).lifetime == (options.lifetime ?? 3600), 'advertised lifetime not stored');
 }
 if (options.ping_fail) assert(!result.ok, 'failed connectivity reported successful');
 print(name + ' passed\n');
}
scenario('fresh RA renews route', route, {}, 'ra_replace', 1);
scenario('static route converted from real RA', replace(route, 'expires 120sec ', ''), {}, 'ra_replace', 1);
scenario('missing route restored', '', {}, 'ra_discovered', 1);
scenario('native kernel renewal retained', route, {native:true}, 'nd_renew', 0);
scenario('ambiguous defaults untouched', route+'\n'+route, {}, 'skipped', 0);
scenario('source-specific route untouched', replace(route,'default via','default from 2408::/64 via'), {}, 'skipped', 0);
scenario('no reply retains current route', route, {reply:''}, 'no_ra', 0);
scenario('static without RA not treated as healthy', replace(route,'expires 120sec ',''), {reply:''}, 'no_ra', 0);
scenario('zero lifetime cannot renew', route, {reply:replace(reply,'3600','0')}, 'no_ra', 0);
scenario('missing sender cannot create route', '', {reply:replace(reply,' from fe80::1','')}, 'no_ra', 0);
scenario('non-link-local sender rejected', '', {reply:replace(reply,'fe80::1','2408::1')}, 'no_ra', 0);
scenario('WAN changed during RA', route, {wan_changed:true}, 'skipped', 0);
scenario('binary absent leaves route intact', route, {no_binary:true}, 'no_ra', 0);
scenario('installation failure reported', route, {write_fail:true}, 'failed', 1);
scenario('ping failure not success', route, {ping_fail:true}, 'connectivity_failed', 1);
scenario('explicit deletion', route, {mode:'delete'}, 'deleted', 1);
scenario('scheduler stopped', route, {mode:'auto'}, 'idle', 0);
let saved={ '/tmp/e5-ipv6-fix/schedule':'1', '/tmp/e5-ipv6-fix/result.json':sprintf('%J',{ok:true,time:time()}) };
scenario('healthy lease waits for interval', replace(route,'120sec','1800sec'), {mode:'auto',stored:saved}, 'idle', 0);
scenario('near expiry overrides one-hour interval', route, {mode:'auto',stored:saved}, 'ra_replace', 1);
saved['/tmp/e5-ipv6-fix/result.json']=sprintf('%J',{ok:false,time:time()});
scenario('failed refresh retried next cron tick', replace(route,'120sec','1800sec'), {mode:'auto',stored:saved}, 'ra_replace', 1);

scenario('changed upstream lifetime is honored', route, {reply:replace(reply,'3600','1800'),lifetime:1800}, 'ra_replace', 1);
saved['/tmp/e5-ipv6-fix/result.json']=sprintf('%J',{ok:true,time:time()});
scenario('lost connectivity overrides interval', replace(route,'120sec','1800sec'), {mode:'auto',stored:saved,ping_fail:true}, 'connectivity_failed', 1);
