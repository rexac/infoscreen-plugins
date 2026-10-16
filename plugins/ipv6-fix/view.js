'use strict';
const RouteView = (() => {
 function lease(state, age) {
  if (state == null) return { kind: 'loading', percent: 0 };
  if (age > 15) return { kind: 'stale', percent: 0 };
  if (state.route_count > 1) return { kind: 'ambiguous', percent: 0 };
  if (!state.route) return { kind: 'missing', percent: 0 };
  if (state.expires == null) return { kind: 'static', percent: 0 };
  const seconds = Math.max(0, Math.floor(state.expires - age));
  return { kind: seconds > 0 ? 'expiring' : 'expired', seconds,
   percent: state.ra_lifetime > 0 ? Math.min(100, Math.max(0, seconds / state.ra_lifetime * 100)) : 0 };
 }
 function duration(seconds, english) {
  const h = Math.floor(seconds / 3600), m = Math.floor(seconds % 3600 / 60), s = seconds % 60;
  return english ? `${h}h ${m}m ${s}s` : `${h}时 ${m}分 ${s}秒`;
 }
 return { lease, duration };
})();
