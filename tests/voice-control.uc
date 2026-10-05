// Runs against mock ModemManager replies only. No shell call can reach a modem.
'use strict';
let source = ARGV[0] ?? '/src/plugins/phone';
let factory = loadfile(source + '/voice.uc')();
let commands = [], failure = null;
let entries = {
 '0': { number:'10099', direction:'outgoing', state:'--' },
 '1': { number:'10099', direction:'outgoing', state:'terminated' },
 '2': { number:'10099', direction:'outgoing', state:'active', 'sim-slot':'1' },
 '3': { number:'10099', direction:'incoming', state:'ringing-in', 'sim-slot':'2' }
};
let listkey = 'modem.voice.call';
let ctx = {
 sh: function(command) {
  push(commands, command);
  if (match(command, /--voice-list-calls/)) {
   let j = {}; j[listkey] = map(keys(entries), id => '/org/freedesktop/ModemManager1/Call/' + id);
   return sprintf('%J\n__E5_VOICE_RC__0\n', j);
  }
  if (failure && match(command, failure)) return 'modem rejected request\n__E5_VOICE_RC__1\n';
  if (match(command, /--voice-create-call=/)) return 'Successfully created new call: /org/freedesktop/ModemManager1/Call/42\n__E5_VOICE_RC__0\n';
  return 'operation successful\n__E5_VOICE_RC__0\n';
 },
 sh_json: function(command) {
  push(commands,command);
  let m = match(command, /Call\/([0-9]+)/);
  return m ? { call:{ properties:entries[m[1]] } } : null;
 }
};
let voice = factory(ctx);
assert(voice.dial('10099').ok, 'dial failed');
assert(length(commands) == 2 && match(commands[0], /--voice-create-call=/) && match(commands[1], /Call\/42.*--start/), 'create must start the same call');
commands=[];
assert(voice.dial('10099',1).ok && match(commands[0], /sim-slot=2/), 'selected SIM must be passed to CreateCall');
commands=[];assert(!voice.dial('10099',2).ok && length(commands)==0, 'invalid SIM must not run a command');
assert(!voice.dial('bad;touch /tmp/pwned').ok && length(commands) == 0, 'invalid number must not run a command');
failure=/--voice-create-call=/;
assert(voice.dial('10099').stage == 'create' && length(commands) == 1, 'create failure must stop before start');
commands=[]; failure=/--start/;
let r = voice.dial('10099');
assert(!r.ok && r.stage == 'start' && r.id == '42' && match(r.error, /modem rejected/), 'start errors must survive');
commands=[]; failure=null;
assert(voice.action('2', 'accept').ok && match(commands[0], /--accept/) && !match(commands[0], /--voice-accept/), 'accept must use Call.Accept');
assert(voice.action('2', 'hangup').ok && match(commands[1], /--hangup/) && !match(commands[1], /--voice-delete-call/), 'hangup must use Call.Hangup');
commands=[];
assert(!voice.action('2;echo bad', 'hangup').ok && length(commands)==0, 'invalid ID must not execute');
for(let key in ['modem.voice.call','modem.voice.calls']) {
 listkey=key; commands=[];
 let states=voice.list().calls;
 assert(length(states)==2 && states[0].state=='active' && states[1].state=='ringing-in', 'only live calls should be shown');
 assert(states[0].card==0 && states[1].card==1 && states[1].sim=='SIM2','call origin SIM missing');
 assert(!match(join(' ', commands), /--start|--accept|--hangup|--voice-delete-call/), 'polling must never control calls');
}
print('Voice control checks passed\n');
