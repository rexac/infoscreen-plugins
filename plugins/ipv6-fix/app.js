'use strict';
const $ = id => document.getElementById(id);
const t = (zh, en) => e5.t({zh, en});
let state = null, receivedAt = null, busy = false, loading = false, logLoading = false, deleteCount = 0, deleteTimer, oldLog = '';
const labels = {
 static: ['静态默认路由，需检查连通性', 'Static route; connectivity must be checked'],
 no_ra: ['未收到有效 RA，保留现有路由', 'No usable RA; existing route retained'],
 connectivity_failed: ['路由已更新，但 IPv6 连通检查失败', 'Route updated, but IPv6 connectivity failed'],
 no_route: ['未找到默认路由', 'No default route found'],
 nd_renew: ['标准 ND 续期（原地续期）', 'Standard ND renewal'],
 ra_discovered: ['已根据 RA 恢复默认路由', 'Default route restored from received RA'],
 ra_received: ['已收到上游 RA', 'Upstream RA received'],
 nd_rebuild: ['ND 重建原生路由', 'Native route rebuilt through ND'],
 route_available: ['RA 请求后路由已恢复', 'Route available after RA request'],
 ra_replace: ['RA 同构路由重建', 'RA route replaced'],
 ra_replace_min: ['RA 同构重建（最小参数）', 'RA route replaced (minimal attributes)'],
 deleted: ['已删除默认路由，可点立即刷新重建', 'Default route deleted; use Refresh now to rebuild'],
 delete_none: ['没有可删除的默认路由', 'No default route to delete'],
 delete_failed: ['删除路由失败', 'Could not delete route'],
 rs: ['正在请求 RA', 'Requesting RA'], fallback: ['完整属性失败，尝试最小参数', 'Retrying minimal attributes']
};
function describe(strategy, message) { const l = labels[strategy]; return l ? t(...l) : message || strategy; }
function timestamp(seconds) {
 if (!seconds) return '';
 return new Date(seconds * 1000 + e5.tzOffset * 1000).toISOString().slice(0, 10) + ' ' + e5.time(seconds * 1000);
}
function intervalText(seconds) { return seconds >= 3600 ? (seconds / 3600) + t(' 小时', ' h') : (seconds / 60) + t(' 分钟', ' min'); }
function drawLease() {
 const lease = RouteView.lease(state, receivedAt == null ? 0 : (performance.now() - receivedAt) / 1000);
 const texts = {
  loading: t('读取中…', 'Loading…'), stale: t('状态已过时，等待刷新', 'Stale; waiting for refresh'),
  ambiguous: t('多条默认路由，无法确定', 'Multiple default routes'), missing: t('无', 'None'),
  static: t('静态路由（无 expires），不代表连通', 'Static route (no expiry); connectivity unverified'),
  expired: t('已过期，等待下次调度刷新', 'Expired; waiting for scheduled renewal')
 };
 const text = lease.kind === 'expiring' ? RouteView.duration(lease.seconds, e5.lang === 'en') + `（${lease.seconds}s）` : texts[lease.kind];
 $('rra-exp').textContent = text;
 const tone = lease.kind === 'expiring' ? 'good' : ['missing', 'expired'].includes(lease.kind) ? 'bad' : 'neutral';
 $('rra-exp').className = tone;
 $('rra-bar').style.width = lease.percent + '%';
 $('rra-bar').style.background = tone === 'good' ? '#4caf50' : tone === 'bad' ? '#f44336' : '#9e9e9e';
 $('rra-progress').setAttribute('aria-valuenow', String(Math.round(lease.percent)));
 $('rra-progress').setAttribute('aria-valuetext', text);
 $('progress-note').textContent = lease.kind === 'expiring' ? (state?.ra_lifetime > 0 ? t('上游 RA 有效期：', 'Advertised RA lifetime: ') + state.ra_lifetime + 's' : t('尚无对应的 RA 有效期，进度条暂不显示比例。', 'RA lifetime unknown; percentage unavailable.')) : '';
}
function paint() {
 $('title').textContent = t('IPv6 路由修复', 'IPv6 route repair');
 for (const [id, zh, en] of [
  ['operator-label','运营商：','Operator: '],['device-label','数据口：','Interface: '],['ping-label','IPv6 连通：','IPv6: '],
  ['watch-label','调度器：','Scheduler: '],['strategy-label','上次刷新策略：','Last successful strategy: '],
  ['route-label','当前路由：','Current route: '],['expiry-label','剩余有效期：','Remaining lifetime: '],
  ['refresh','立即刷新','Refresh now'],['reload','刷新状态','Reload status'],['start','启动调度','Start scheduler'],['stop','停止调度','Stop scheduler'],
  ['delete-route','删除当前路由','Delete current route'],['interval-label','最长刷新间隔','Maximum interval'],
  ['result-title','最近一次运行结果','Latest run result'],['routes-title','全部 IPv6 路由','All IPv6 routes'],
  ['log-title','历史运行日志','Run history'],['log-refresh','刷新日志','Refresh log'],['log-clear','清空日志','Clear log']
 ]) $(id).textContent = t(zh, en);
 $('rra-op').textContent = state?.operator || t('未知', 'Unknown');
 $('rra-iface').textContent = state?.device || '—';
 $('rra-ping').textContent = state?.ping6 ? (state.ping6.ok ? t('正常', 'OK') : t('不通', 'Failed')) : '—';
 $('rra-ping').className = state?.ping6 ? (state.ping6.ok ? 'good' : 'bad') : 'neutral';
 $('rra-watch').textContent = state?.enabled ? t('运行中', 'Running') : t('已停止', 'Stopped');
 $('rra-watch').className = state?.enabled ? 'good' : 'neutral';
 $('rra-interval').textContent = '（' + intervalText(Number(state?.interval || 3600)) + '）';
 $('rra-rd').textContent = state?.rdisc6 ? t('已内置，可用', 'Bundled, ready') : t('不可用', 'Unavailable');
 $('rra-strategy').textContent = state?.strategy ? describe(state.strategy.strategy, state.strategy.message) + ' · ' + timestamp(state.strategy.time) : t('暂无（尚未刷新过）', 'None yet');
 $('rra-route').textContent = state?.route || (state?.route_count > 1 ? t('多条候选路由，请查看全部路由', 'Multiple candidates; see all routes') : t('未找到默认路由（可能已到期被删）', 'No default route found (possibly expired)'));
 $('principle').textContent = t('按真实 RA 有效期续期；临近到期或 IPv6 不通时提前刷新，不人为延长有效期。', 'Renews using the advertised RA lifetime, earlier near expiry or on connectivity loss.');
 $('runtime-note').textContent = t('调度只在本次开机期间有效；关闭页面后继续运行。删除路由需在 2 秒内连续按 3 次，会短暂中断 IPv6。', 'Scheduling lasts until reboot and continues with this page closed. Press Delete 3 times within 2 seconds; IPv6 will be interrupted.');
 $('log-hint').textContent = t('只显示最近 40 行；旧失败不代表当前故障。', 'Last 40 lines; past failures do not indicate a current fault.');
 $('result').textContent = state?.result ? (state.result.ok ? '✓ ' : '⚠ ') + describe(state.result.strategy, state.result.message) + '\n' + timestamp(state.result.time) : t('尚未运行', 'Not run yet');
 $('routes').textContent = state?.routes || '';
 $('interval-value').textContent = intervalText(Number(state?.interval || 3600));
 $('interval-picker-title').textContent = t('最长刷新间隔', 'Maximum refresh interval');
 $('interval-cancel').textContent = t('取消', 'Cancel');
 drawLease(); drawLog();
}
function drawLog(text) {
 if (text !== undefined) oldLog = text;
 const rendered = oldLog.trim().split('\n').filter(Boolean).map(line => {
  const m = line.match(/^(\d+) ([a-z_]+): (.*)$/);
  return m ? timestamp(Number(m[1])) + ' ' + describe(m[2], m[3]) + (['nd_renew','nd_rebuild','ra_replace','ra_replace_min','route_available','ra_discovered'].includes(m[2]) ? '\n' + m[3] : '') : line;
 }).join('\n\n');
 if ($('log').textContent !== rendered) { $('log').textContent = rendered; $('log').scrollTop = $('log').scrollHeight; }
}
async function load() {
 if (loading) return;
 loading = true;
 try { state = await e5.api('/status'); receivedAt = performance.now(); oldLog = state.log || ''; paint(); }
 catch(e) { $('message').textContent = e.data?.error || e.message; }
 finally { loading = false; }
}
async function loadLog() {
 if (logLoading) return;
 logLoading = true;
 try { drawLog((await e5.api('/log')).log || ''); }
 catch(e) { $('message').textContent = e.message; }
 finally { logLoading = false; }
}
async function action(path, body) {
 if (busy) return;
 busy = true;
 document.querySelectorAll('button, select').forEach(b => { b.disabled = true; });
 try { const reply = await e5.api(path, {body}); if (reply?.error || reply?.ok === false) throw new Error(reply.error || t('操作失败', 'Operation failed')); $('message').textContent = ['/refresh','/delete-route'].includes(path) ? t('任务已提交，请查看运行结果与日志', 'Task queued; see result and log') : t('操作完成', 'Done'); await load(); await loadLog(); }
 catch(e) { $('message').textContent = e.data?.error || e.message; }
 finally { busy = false; document.querySelectorAll('button, select').forEach(b => { b.disabled = false; }); }
}
$('refresh').onclick = () => action('/refresh', {});
$('start').onclick = () => action('/schedule', {enabled:true});
$('stop').onclick = () => action('/schedule', {enabled:false});
$('reload').onclick = load;
$('log-refresh').onclick = loadLog;
$('log-clear').onclick = () => action('/log-clear', {});
function closeIntervalPicker() {
 $('interval-picker').hidden = true;
 $('interval').setAttribute('aria-expanded', 'false');
 $('interval').focus();
}
function openIntervalPicker() {
 if (busy) return;
 const chosen = Number(state?.interval || 3600);
 const choices = [...new Set([300, 900, 1800, 3600, 7200, 21600, chosen])].sort((a,b) => a-b);
 const options = $('interval-options');
 options.replaceChildren();
 choices.forEach(value => {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = intervalText(value);
  button.setAttribute('aria-pressed', String(value === chosen));
  button.onclick = () => { closeIntervalPicker(); if (value !== chosen) action('/interval', {interval:value}); };
  options.appendChild(button);
 });
 $('interval-picker').hidden = false;
 $('interval').setAttribute('aria-expanded', 'true');
 options.querySelector('[aria-pressed="true"]').focus();
}
$('interval').onclick = openIntervalPicker;
$('interval-cancel').onclick = closeIntervalPicker;
$('interval-picker').onclick = event => { if (event.target === $('interval-picker')) closeIntervalPicker(); };
document.addEventListener('keydown', event => {
 if (event.defaultPrevented || $('interval-picker').hidden) return;
 const controls = Array.from($('interval-picker').querySelectorAll('button'));
 const current = controls.indexOf(document.activeElement);
 if (event.key === 'Escape') { event.preventDefault(); closeIntervalPicker(); }
 else if (['Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
  event.preventDefault();
  const direction = event.key === 'ArrowUp' || event.key === 'ArrowLeft' || (event.key === 'Tab' && event.shiftKey) ? -1 : 1;
  controls[(current + direction + controls.length) % controls.length].focus();
 }
});
$('delete-route').onclick = () => {
 clearTimeout(deleteTimer);
 deleteTimer = setTimeout(() => { deleteCount = 0; }, 2000);
 if (++deleteCount < 3) { $('message').textContent = t(`会中断 IPv6！再按 ${3-deleteCount} 次确认删除`, `IPv6 will be interrupted! Press ${3-deleteCount} more times to delete`); return; }
 deleteCount = 0; action('/delete-route', {confirm:'DELETE'});
};
e5.onLang(paint);
e5.onKey(k => {
 if (!$('interval-picker').hidden && k.kind === 'back') { closeIntervalPicker(); return true; }
 const controls = Array.from(document.querySelectorAll($('interval-picker').hidden ? 'button, summary, #log' : '#interval-picker button')).filter(el => !el.closest('[hidden]'));
 let i = controls.indexOf(document.activeElement), current = controls[i];
 if (['up', 'down', 'left', 'right'].includes(k.kind)) {
  if (current?.id === 'log' && ['up','down'].includes(k.kind)) { current.scrollTop += k.kind === 'up' ? -80 : 80; return true; }
  i = (i + (k.kind === 'up' || k.kind === 'left' ? -1 : 1) + controls.length) % controls.length;
  controls[i].focus(); controls[i].scrollIntoView({block:'nearest'}); return true;
 }
 if (k.kind === 'ok') { if (!busy) { if (current?.tagName==='SUMMARY') current.parentElement.open=!current.parentElement.open; else e5.press(current || controls[0]); } return true; }
 return false;
});
paint(); load();
const statusTimer = setInterval(load, 5000), logTimer = setInterval(loadLog, 2000), countdownTimer = setInterval(drawLease, 1000);
window.addEventListener('pagehide', () => { clearInterval(statusTimer); clearInterval(logTimer); clearInterval(countdownTimer); clearTimeout(deleteTimer); });
