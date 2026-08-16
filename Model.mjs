// Snooze's pure logic. Loaded by the QML engine (import "Model.mjs" as Model)
// and by node:test. Keep the JavaScript conservative — the QML engine parses
// less than Node (no spread, no flatMap, no optional chaining, no async);
// tests/qml-smoke.sh runs this file in the real Qt engine to catch drift.

export const BEGIN_MARK = "# >>> snooze >>>";
export const END_MARK = "# <<< snooze <<<";
export const MAX_DOMAINS = 500;

var DOMAIN_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

export function isValidDomain(s) {
  if (typeof s !== "string" || s.length > 253) return false;
  return DOMAIN_RE.test(s);
}

export function normalizeSite(s) {
  var t = String(s).trim().toLowerCase();
  t = t.replace(/^[a-z][a-z0-9+.-]*:\/\//, "");
  t = t.replace(/[/:?#].*$/, "");
  t = t.replace(/\.$/, "");
  return t;
}

export function expandSites(sites) {
  var out = [];
  var seen = {};
  for (var i = 0; i < sites.length; i++) {
    var d = normalizeSite(sites[i]);
    if (!isValidDomain(d)) continue;
    var variants = [d];
    if (d.split(".").length === 2) variants.push("www." + d);
    for (var j = 0; j < variants.length; j++) {
      if (!seen[variants[j]]) { seen[variants[j]] = true; out.push(variants[j]); }
    }
  }
  return out;
}

export function parseDuration(s) {
  var m = /^(?:(\d+)h)?(?:(\d+)m)?$/.exec(String(s).trim());
  if (!m || (m[1] === undefined && m[2] === undefined)) return null;
  var minutes = (m[1] ? parseInt(m[1], 10) * 60 : 0) + (m[2] ? parseInt(m[2], 10) : 0);
  return minutes > 0 ? minutes : null;
}

export function formatRemaining(seconds) {
  if (seconds === null || seconds === undefined) return "∞";
  var s = Math.max(0, Math.floor(seconds));
  var h = Math.floor(s / 3600);
  var m = Math.ceil((s - h * 3600) / 60);
  if (m === 60) { h += 1; m = 0; }
  return h > 0 ? h + "h " + m + "m" : m + "m";
}

export function buildBlock(until, domains) {
  var lines = [BEGIN_MARK + " until=" + until];
  for (var i = 0; i < domains.length; i++) lines.push("0.0.0.0 " + domains[i]);
  lines.push(END_MARK);
  return lines.join("\n");
}

export function parseHosts(text) {
  var lines = String(text).split("\n");
  var rest = [];
  var domains = [];
  var until = null;
  var inside = false;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.indexOf(BEGIN_MARK) === 0) {
      inside = true;
      var m = /until=(\d+)/.exec(line);
      until = m ? parseInt(m[1], 10) : 0;
      continue;
    }
    if (line.indexOf(END_MARK) === 0) { inside = false; continue; }
    if (inside) {
      var dm = /^0\.0\.0\.0[ \t]+(\S+)/.exec(line);
      if (dm) domains.push(dm[1]);
    } else {
      rest.push(line);
    }
  }
  return { rest: rest.join("\n"), until: until, domains: domains };
}

export function applyBlock(text, until, domains) {
  var base = parseHosts(text).rest.replace(/\s+$/, "");
  return base + "\n\n" + buildBlock(until, domains) + "\n";
}

export function validateGroups(obj) {
  if (!obj || obj.version !== 1 || !Array.isArray(obj.groups)) return false;
  for (var i = 0; i < obj.groups.length; i++) {
    var g = obj.groups[i];
    if (!g || typeof g.id !== "string" || !g.id || typeof g.name !== "string" || !g.name) return false;
    if (g.icon !== undefined && typeof g.icon !== "string") return false;
    if (!Array.isArray(g.sites)) return false;
    for (var j = 0; j < g.sites.length; j++) {
      if (typeof g.sites[j] !== "string") return false;
    }
  }
  return true;
}
