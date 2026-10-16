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
let ctx={
 ubus:()=>({up:true,l3_device:'sipa_eth0'}),modem:()=>({operator:'CHINA UNICOM'}),
 sh:cmd=>index(cmd,'ip -6 route show')==0?route:'bundled',
 run:cmd=>{push(calls,cmd);return 0;},
 state_get:key=>cache[key],state_put:(key,value)=>{cache[key]=value;},
 uci:()=>({get:(config,section,option)=>option?values[option]:'settings',set:(config,section,option,value)=>{values[option]=value;return true;},delete:(config,section,option)=>{delete values[option];return true;},commit:()=>true})
};
let factory=loadstring('return function(env) { let readfile=env.readfile,writefile=env.writefile,rename=env.rename,unlink=env.unlink;\n'+source+'\n};',{raw_mode:true})()(env);
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
files['/etc/crontabs/root']='15 4 * * * echo unrelated\n';
assert(routes['POST /schedule']({body:{enabled:true}}).ok,'scheduler start failed');
assert(index(files['/etc/crontabs/root'],'15 4 * * * echo unrelated')>=0,'unrelated cron entry lost');
assert(files[prefix+'/schedule']!=null,'runtime marker missing');
assert(routes['GET /status']({}).enabled,'running scheduler not shown');
let launches=length(filter(calls,c=>index(c,'timeout 55')>=0));
assert(routes['POST /schedule']({body:{enabled:true}}).ok,'duplicate start failed');
assert(length(filter(calls,c=>index(c,'timeout 55')>=0))==launches,'duplicate start launched another task');
assert(routes['POST /schedule']({body:{enabled:false}}).ok,'scheduler stop failed');
assert(files[prefix+'/schedule']==null && index(files['/etc/crontabs/root'],'# e5-ipv6-fix')<0,'stop left scheduler enabled');
files[prefix+'/schedule']='1\n';
assert(!routes['GET /status']({}).enabled,'marker alone incorrectly reports running');
route=replace(route,'expires 123sec ','');
assert(routes['GET /status']({}).expires==null,'static route has a fabricated expiry');
assert(routes['POST /log-clear']({body:{}}).ok,'log clear rejected');
print('IPv6 status, confirmation, interval, log and runtime scheduler checks passed\n');
