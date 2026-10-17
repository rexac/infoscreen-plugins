// Verify host theme changes and the legacy/standalone fallback without router writes.
'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
async function check() {
 const plugin = 'ipv6-fix';
 const source = fs.readFileSync(`plugins/${plugin}/theme.js`, 'utf8');
 function page(theme, standalone = false) {
  const root = {dataset:{}}, host = {body:{dataset:theme ? {theme} : {}}, documentElement:{dataset:{}}};
  const events = {}, timers = [], observers = []; let reads = 0, response;
  const document = {documentElement:root, hidden:false, addEventListener:(name,fn)=>{events[name]=fn;}};
  const window = {parent: {document:host}, addEventListener:(name,fn)=>{events[name]=fn;}};
  if (standalone) window.parent = window;
  vm.runInNewContext(source, {document,window,MutationObserver:class {constructor(fn){this.fn=fn;observers.push(this);}observe(){}disconnect(){this.disconnected=true;}},setInterval:fn=>{timers.push(fn);return 1;},clearInterval:()=>{timers.length=0;},e5:{core:()=>{reads++;return new Promise(resolve=>{response=resolve;});}}});
  return {root,host,events,timers,observers,get reads(){return reads;},reply:value=>response(value)};
 }
 const p=page('light');assert.equal(p.root.dataset.theme,'light');assert.equal(p.reads,0);
 p.host.body.dataset.theme='dark';p.observers[0].fn();assert.equal(p.root.dataset.theme,'dark');
 await p.timers[0]();assert.equal(p.reads,0,'current host must not incur API polling');
 p.host.body.dataset.theme='light';p.observers[0].fn();assert.equal(p.root.dataset.theme,'light');
 p.events.pagehide();assert.equal(p.timers.length,0);
 const legacy=page();assert.equal(legacy.reads,1);legacy.reply({screen:{ui_theme:'light'}});await new Promise(setImmediate);assert.equal(legacy.root.dataset.theme,'light');
 const race=page();race.host.body.dataset.theme='light';race.observers[0].fn();race.reply({screen:{ui_theme:'dark'}});await new Promise(setImmediate);assert.equal(race.root.dataset.theme,'light','late API response overwrote live host');
 const solo=page(null,true);solo.reply({screen:{ui_theme:'light'}});await new Promise(setImmediate);assert.equal(solo.root.dataset.theme,'light');
 solo.root.dataset.theme='dark';solo.events.visibilitychange();solo.reply({screen:{ui_theme:'light'}});await new Promise(setImmediate);assert.equal(solo.root.dataset.theme,'light');
 console.log(`${plugin}: theme switching, legacy fallback, standalone and stale response checks passed`);
}
(async()=>{await check();})().catch(e=>{console.error(e);process.exit(1);});
