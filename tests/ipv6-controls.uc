'use strict';
import { readfile } from 'fs';
let source=replace(readfile(ARGV[0] ?? 'plugins/ipv6-fix/backend.uc'), "import { readfile, writefile, rename, unlink } from 'fs';", '');
let files={}, calls=[], values={interval:'3600'}, cache={};
let prefix='/tmp/e5-ipv6-fix', route='default via fe80::1 dev sipa_eth0 proto ra metric 1024 expires 123sec pref medium';
let env={
 readfile:path=>files[path],
 writefile:(path,data)=>{files[path]=data;return length(data);},
 rename:(from,to)=>{files[to]=files[from];delete files[from];return true;},
 unlink:path=>{delete files[path];return true;}
};
let cronSource=replace(readfile(ARGV[1] ?? 'plugins/ipv6-fix/cron.uc'), "import { readfile, writefile, rename, unlink } from 'fs';", '');
let cron=loadstring('return function(env){let readfile=env.readfile,writefile=env.writefile,rename=env.rename,unlink=env.unlink;'+cronSource+'};',{raw_mode:true})()(env);
let ctx={
 ubus:()=>({up:true,l3_device:'sipa_eth0'}),modem:()=>({operator:'CHINA UNICOM'}),
 sh:cmd=>index(cmd,'ip -6 route show')==0?route:'bundled',
 run:cmd=>{push(calls,cmd);return 0;},
 state_get:key=>cache[key],state_put:(key,value)=>{cache[key]=value;},
 uci:()=>({get:(config,section,option)=>option?values[option]:'settings',set:(config,section,option,value)=>{values[option]=value;return true;},delete:(config,section,option)=>{delete values[option];return true;},commit:()=>true})
};
env.cron=cron;
let factory=loadstring('return function(env) { let readfile=env.readfile,writefile=env.writefile,rename=env.rename,unlink=env.unlink,loadfile=()=>()=>env.cron;\n'+source+'\n};',{raw_mode:true})()(env);
let routes=factory(ctx), status=routes['GET /status']({});
assert(status.expires==123 && status.device=='sipa_eth0','expiry or interface parsing failed');
assert(status.ra_lifetime==null,'unknown RA lifetime fabricated');
files[prefix+'/lease.json']=sprintf('%J',{device:'sipa_eth0',gateway:'fe80::1',lifetime:3600,time:time()});
assert(routes['GET /status']({}).ra_lifetime==3600,'real RA lifetime not shown');
files[prefix+'/lease.json']=sprintf('%J',{device:'sipa_eth1',gateway:'fe80::1',lifetime:3600,time:time()});
assert(routes['GET /status']({}).ra_lifetime==null,'another interface lease leaked');
assert(status.operator=='CHINA UNICOM' && status.ping6.ok,'operator or ping missing');
assert(!status.enabled,'scheduler started without runtime marker');
assert(routes['POST /delete-route']({body:{}}).status==400,'delete accepted without confirmation');
assert(routes['POST /interval']({body:{interval:61}}).status==400,'non-minute interval accepted');
assert(routes['POST /interval']({body:{interval:'300'}}).status==400,'string interval accepted');
assert(routes['POST /interval']({body:{interval:300}}).ok && values.interval=='300','interval not saved');
files['/etc/crontabs/root']='15 4 * * * echo unrelated\n* * * * * obsolete # e5-ipv6-fix\n';
assert(routes['POST /schedule']({body:{enabled:true}}).ok,'scheduler start failed');
assert(index(files['/etc/crontabs/root'],'15 4 * * * echo unrelated')>=0,'unrelated cron entry lost');
assert(index(files['/etc/crontabs/root'],'obsolete')<0,'legacy cron not replaced');
assert(index(files['/etc/crontabs/root'],'*/5 * * * * flock')>=0,'five minute cron missing');
assert(files[prefix+'/schedule']!=null,'runtime marker missing');
assert(routes['GET /status']({}).enabled,'running scheduler not shown');
files[prefix+'/lease.json']=sprintf('%J',{device:'sipa_eth0',gateway:'fe80::1',lifetime:3600,time:time()});
assert(routes['POST /interval']({body:{interval:1800}}).ok,'interval change rejected');
let st=routes['GET /status']({});
assert(st.cron_expression=='*/30 * * * *' && st.effective_interval==1800,'30-minute cron missing');
assert(st.next_refresh_in>0 && st.next_refresh_in<=1800,'next wall-clock slot invalid');
assert(routes['POST /interval']({body:{interval:21600}}).ok,'long interval rejected');
st=routes['GET /status']({});
assert(st.interval==21600 && st.effective_interval==1800,'short RA did not cap long interval');
let original=files['/etc/crontabs/root'];
assert(routes['POST /schedule']({body:{enabled:true}}).ok,'duplicate start failed');
assert(files['/etc/crontabs/root']==original,'duplicate start changed cron');
assert(routes['POST /schedule']({body:{enabled:false}}).ok,'scheduler stop failed');
assert(files[prefix+'/schedule']==null && index(files['/etc/crontabs/root'],'# e5-ipv6-fix')<0,'stop left scheduler enabled');
files[prefix+'/schedule']='1\n';
assert(!routes['GET /status']({}).enabled,'marker alone incorrectly reports running');
route=replace(route,/expires [0-9]+sec /,'');
assert(routes['GET /status']({}).expires==null,'static route has a fabricated expiry');
assert(routes['POST /log-clear']({body:{}}).ok,'log clear rejected');
let clearCommand=calls[length(calls)-1];
assert(index(clearCommand,'timeout 3 flock ')>=0 && index(clearCommand,'flock -w')<0,'unsupported BusyBox flock option used');
files[prefix+'/log.txt']='not cleared';
assert(routes['POST /log-clear']({body:{}}).status==500,'failed truncation falsely reported success');

assert(routes['GET /status']({}).next_refresh_in==null,'stopped scheduler has next refresh');
print('IPv6 status, confirmation, interval, log and runtime scheduler checks passed\n');

for (let fixture in [[300,3600,300,'*/5 * * * *'],[900,3600,900,'*/15 * * * *'],[1800,3600,1800,'*/30 * * * *'],[3600,7200,3600,'0 * * * *'],[7200,20000,7200,'0 */2 * * *'],[21600,65535,21600,'0 */6 * * *'],[21600,null,300,'*/5 * * * *'],[420,3600,360,'*/6 * * * *']]) {
 let p=cron.plan(fixture[0],fixture[1]);
 assert(p.interval==fixture[2] && p.expression==fixture[3],sprintf('bad cron plan: %J',p));
}
files['/etc/crontabs/root']='*/30 * * * * example # e5-ipv6-fix\n';
assert(cron.configure(false,1800,3600)!=null && files['/etc/crontabs/root']=='','cannot remove final cron entry');
print('Cron slots, RA caps, custom intervals and empty crontab checks passed\n');
