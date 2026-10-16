'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const context=vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../plugins/ipv6-fix/view.js'),'utf8'),context);
function lease(state,age=0){context.fixture=state;context.age=age;return JSON.parse(vm.runInContext('JSON.stringify(RouteView.lease(fixture, age))',context));}
assert.equal(lease(null).kind,'loading');
assert.equal(lease({route_count:0}).kind,'missing');
assert.equal(lease({route_count:2}).kind,'ambiguous');
assert.deepEqual(lease({route:'default via fe80::1',expires:null}),{kind:'static',percent:0});
assert.equal(lease({route:'default',expires:1800,ra_lifetime:3600}).percent,50);
assert.equal(lease({route:'default',expires:4000,ra_lifetime:3600}).percent,100);
assert.equal(lease({route:'default',expires:10},2.2).seconds,7);
assert.equal(lease({route:'default',expires:0}).kind,'expired');
assert.equal(lease({route:'default',expires:-5}).percent,0);
assert.equal(lease({route:'default',expires:5},6).seconds,0);
assert.equal(lease({route:'default',expires:65535},16).kind,'stale');
assert.equal(vm.runInContext('RouteView.duration(3661,false)',context),'1时 1分 1秒');
assert.equal(vm.runInContext('RouteView.duration(3661,true)',context),'1h 1m 1s');
assert.equal(lease({route:'default',expires:1800}).percent,0);
console.log('14 IPv6 lifetime/view checks passed');

(async()=>{
 const source=fs.readFileSync(path.join(__dirname,'../plugins/ipv6-fix/app.js'),'utf8');
 const action=source.slice(source.indexOf('async function action('),source.indexOf("$('refresh').onclick"));
 let refreshed=0;const message={textContent:''};
 const sandbox=vm.createContext({busy:false,document:{querySelectorAll:()=>[]},$:()=>message,
  t:zh=>zh,e5:{api:async()=>({error:'Confirmation required'})},load:async()=>{refreshed++;},loadLog:async()=>{}});
 vm.runInContext(action,sandbox);
 await vm.runInContext("action('/delete-route', {})",sandbox);
 assert.equal(message.textContent,'Confirmation required');
 assert.equal(refreshed,0,'an error returned with HTTP 200 was treated as success');
 console.log('Legacy HTTP-200 error response handling passed');
 const loads=source.slice(source.indexOf('async function load()'),source.indexOf("$('refresh').onclick"));
 let pendingLog, pendingStatus, displayed='old history';
 const race=vm.createContext({busy:false,loading:false,logLoading:false,logEpoch:0,state:{log:'old history'},oldLog:'old history',receivedAt:0,
  document:{querySelectorAll:()=>[]},$:()=>message,t:zh=>zh,performance:{now:()=>0},paint:()=>{},
  drawLog:text=>{displayed=text;},e5:{api:async path=>{
   if(path==='/log') return new Promise(resolve=>{pendingLog=resolve;});
   if(path==='/status') return new Promise(resolve=>{pendingStatus=resolve;});
   return {ok:true};
  }}});
 vm.runInContext(loads,race);
 const oldStatus=vm.runInContext('load()',race), oldLog=vm.runInContext('loadLog()',race);
 await vm.runInContext("action('/log-clear', {})",race);
 assert.equal(displayed,'','successful clear did not immediately empty the page');
 pendingLog({log:'old history'});pendingStatus({log:'old history'});
 await Promise.all([oldStatus,oldLog]);
 assert.equal(displayed,'','stale log request refilled cleared history');
 assert.equal(vm.runInContext('state.log',race),'','stale status request refilled cleared history');
 console.log('Clear-log polling race checks passed');

})().catch(error=>{console.error(error);process.exitCode=1;});
