'use strict';
// Prüfungen und Bereinigung für Eingaben in der Oberfläche. Jede Funktion liefert
// { value, errors, warnings, infos }. Gespeichert wird nur, wenn errors leer ist.

// Unsichtbare Zeichen, die beim Kopieren aus Portalen, Mails oder Teams gern mitkommen
const INVISIBLE = /[​-‍⁠﻿­]/g;

function cleanText(raw) {
  return String(raw ?? '')
    .replace(INVISIBLE, '')
    .replace(/[  -   　]/g, ' ')  // geschützte und typografische Leerzeichen
    .replace(/[‘’‚‛“”„‟]/g, '"');
}

function result(value) { return { value, errors: [], warnings: [], infos: [] }; }

// --- Tenant-ID ---------------------------------------------------------------
const GUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

function checkTenantId(raw) {
  const r = result('');
  let s = cleanText(raw).trim();
  if (!s) { r.errors.push('Bitte die Tenant-ID eintragen.'); return r; }
  const stripped = s.replace(/^["'{(\[]+|["'})\]]+$/g, '').trim();
  if (stripped !== s) r.infos.push('Anführungszeichen bzw. Klammern entfernt.');
  s = stripped;
  const found = [...new Set((s.match(GUID_RE) || []).map(g => g.toLowerCase()))];
  if (found.length > 1) { r.errors.push('Der Text enthält mehrere IDs. Bitte nur die Tenant-ID einfügen.'); return r; }
  if (found.length === 1) {
    if (found[0] !== s.toLowerCase()) r.infos.push('Die ID wurde aus dem eingefügten Text herausgelöst.');
    if (found[0] === '00000000-0000-0000-0000-000000000000') { r.errors.push('Das ist die Platzhalter-ID aus der Vorlage, nicht die echte Tenant-ID.'); return r; }
    r.value = found[0];
    return r;
  }
  // Typische Fehler genauer benennen
  const compact = s.replace(/[\s-]/g, '');
  if (/^[0-9a-f]{32}$/i.test(compact)) {
    r.value = compact.toLowerCase().replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
    r.infos.push('Bindestriche bzw. Leerzeichen korrigiert.');
    return r;
  }
  if (/[g-z]/i.test(compact) && /^[0-9a-z]+$/i.test(compact)) {
    const bad = [...new Set(compact.replace(/[0-9a-f]/gi, '').toUpperCase())].join(', ');
    r.errors.push(`Enthält Zeichen, die in einer ID nicht vorkommen (${bad}). Häufig ist ein O statt einer 0 oder ein l statt einer 1.`);
    return r;
  }
  if (s.includes('.')) { r.errors.push('Das sieht nach einer Domäne aus. Hier gehört die Tenant-ID hin, die Domäne kommt ins Feld darunter.'); return r; }
  r.errors.push(`Keine gültige ID. Erwartet werden 36 Zeichen im Format 11111111-2222-3333-4444-555555555555, eingegeben wurden ${compact.length} Zeichen ohne Bindestriche.`);
  return r;
}

// --- Microsoft-Domäne (xxx.onmicrosoft.com) ----------------------------------
function checkMsDomain(raw) {
  const r = result('');
  let s = cleanText(raw).trim().toLowerCase();
  if (!s) { r.errors.push('Bitte die Microsoft-Domäne eintragen.'); return r; }
  const before = s;
  s = s.replace(/^["'<(]+|[">)]+$/g, '').replace(/^[a-z]+:\/\//, '').replace(/[/?#].*$/, '').replace(/\.$/, '').trim();
  if (s.includes('@')) s = s.split('@').pop();
  if (/\s/.test(s)) { r.errors.push('Die Domäne enthält Leerzeichen.'); return r; }
  if (s !== before) r.infos.push('Adresse bereinigt (Protokoll, Pfad oder Benutzerteil entfernt).');
  if (!s.includes('.')) {
    r.errors.push(`Unvollständig. Gemeint ist vermutlich ${s}.onmicrosoft.com.`);
    r.suggestion = `${s}.onmicrosoft.com`;
    return r;
  }
  if (/\.mail\.onmicrosoft\.com$/.test(s)) {
    r.errors.push('Das ist die Routing-Domäne von Exchange Online. Gebraucht wird die Domäne ohne „.mail“.');
    r.suggestion = s.replace('.mail.onmicrosoft.com', '.onmicrosoft.com');
    return r;
  }
  if (/\.onmicrosoft\.(us|de)$/.test(s) || /\.partner\.onmschina\.cn$/.test(s)) {
    r.errors.push('Das ist eine Domäne aus einer souveränen Cloud (z. B. GCC High, China). Der Deployer unterstützt nur die weltweite Microsoft-Cloud.');
    return r;
  }
  if (!/\.onmicrosoft\.com$/.test(s)) {
    r.errors.push('Das ist eine eigene Domäne. Gebraucht wird die Microsoft-Domäne, die auf .onmicrosoft.com endet. Sie ändert sich nie und steht in jedem Tenant.');
    return r;
  }
  const label = s.slice(0, -'.onmicrosoft.com'.length);
  if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) {
    r.errors.push('Vor .onmicrosoft.com sind nur Buchstaben, Ziffern und Bindestriche erlaubt, ohne Bindestrich am Anfang oder Ende.');
    return r;
  }
  r.value = s;
  return r;
}

// --- Benutzerprinzipalnamen ---------------------------------------------------
function checkUpnList(text) {
  const r = result([]);
  const parts = cleanText(text).split(/[\n,;]+/).map(s => s.trim().replace(/^["'<]+|[">]+$/g, '')).filter(Boolean);
  for (const p of parts) {
    if (/\s/.test(p)) { r.errors.push(`„${p}“ enthält Leerzeichen.`); continue; }
    if (!/^[^@]+@[^@]+\.[^@]+$/.test(p)) { r.errors.push(`„${p}“ ist kein Anmeldename im Format name@domäne.`); continue; }
    r.value.push(p.toLowerCase());
  }
  const unique = [...new Set(r.value)];
  if (unique.length < r.value.length) r.infos.push('Doppelte Einträge entfernt.');
  r.value = unique;
  return r;
}

// --- Gruppennamen -------------------------------------------------------------
const NAME_TOKENS = ['{Persona}', '{persona}', '{PERSONA}'];

function checkGroupPattern(raw) {
  const r = result('');
  const s = cleanText(raw);
  const t = s.trim();
  if (t !== s) r.infos.push('Leerzeichen am Anfang bzw. Ende entfernt.');
  if (!t) { r.errors.push('Das Schema ist leer.'); return r; }
  const tokens = t.match(/\{[^{}]*\}/g) || [];
  const unknown = tokens.filter(x => !NAME_TOKENS.includes(x));
  if (unknown.length) { r.errors.push(`Unbekannter Platzhalter ${unknown.join(', ')}. Erlaubt sind {Persona}, {persona} und {PERSONA}.`); return r; }
  if (/[{}]/.test(t.replace(/\{[^{}]*\}/g, ''))) { r.errors.push('Eine geschweifte Klammer ist nicht geschlossen.'); return r; }
  if (!tokens.length) { r.errors.push('Ohne {Persona} bekämen alle Gruppen denselben Namen.'); return r; }
  r.value = t;
  return r;
}

function checkName(raw, what) {
  const r = result('');
  const s = cleanText(raw);
  const t = s.trim();
  if (t !== s) r.infos.push('Leerzeichen am Anfang bzw. Ende entfernt.');
  if (!t) { r.errors.push(`${what} ist leer.`); return r; }
  if (/[\u0000-\u001F\u007F]/.test(t)) { r.errors.push(`${what} enthält Steuerzeichen, etwa einen Tabulator oder Zeilenumbruch.`); return r; }
  if (t.length > 256) { r.errors.push(`${what} ist ${t.length} Zeichen lang, erlaubt sind 256.`); return r; }
  if (/\s{2,}/.test(t)) r.warnings.push(`${what} enthält doppelte Leerzeichen.`);
  if (/[^\x20-\x7E]/.test(t)) r.warnings.push(`${what} enthält Umlaute oder Sonderzeichen. Im technischen Kurznamen (mailNickname) fallen sie weg.`);
  r.value = t;
  return r;
}

// --- IP-Bereiche für Named Locations -------------------------------------------
function parseV4(s) {
  const p = s.split('.');
  if (p.length !== 4) return null;
  let n = 0n;
  for (const o of p) {
    if (!/^\d{1,3}$/.test(o) || (o.length > 1 && o[0] === '0') || Number(o) > 255) return null;
    n = (n << 8n) + BigInt(o);
  }
  return n;
}
function parseV6(s) {
  if (!/^[0-9a-f:]+$/i.test(s)) return null;
  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  if (halves.length === 1 && head.length !== 8) return null;
  if (halves.length === 2 && head.length + tail.length > 7) return null;
  const groups = [...head, ...Array(halves.length === 2 ? 8 - head.length - tail.length : 0).fill('0'), ...tail];
  let n = 0n;
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/i.test(g)) return null;
    n = (n << 16n) + BigInt(parseInt(g, 16));
  }
  return n;
}
function fmtV4(n) { return [24n, 16n, 8n, 0n].map(sh => String((n >> sh) & 255n)).join('.'); }
function fmtV6(n) {
  const g = [];
  for (let i = 7; i >= 0; i--) g.push(Number((n >> BigInt(i * 16)) & 0xFFFFn));
  let bestS = -1, bestL = 0;
  for (let i = 0; i < 8;) {
    if (g[i] !== 0) { i++; continue; }
    let j = i; while (j < 8 && g[j] === 0) j++;
    if (j - i > bestL && j - i > 1) { bestS = i; bestL = j - i; }
    i = j;
  }
  const hex = g.map(x => x.toString(16));
  if (bestS < 0) return hex.join(':');
  return hex.slice(0, bestS).join(':') + '::' + hex.slice(bestS + bestL).join(':');
}
const maskOf = (bits, prefix) => ((1n << BigInt(bits)) - 1n) ^ ((1n << BigInt(bits - prefix)) - 1n);

function parseCidr(s) {
  const [addr, pre] = s.split('/');
  const v6 = addr.includes(':');
  const n = v6 ? parseV6(addr) : parseV4(addr);
  if (n === null) return null;
  const bits = v6 ? 128 : 32;
  const prefix = pre === undefined ? bits : (/^\d{1,3}$/.test(pre) ? Number(pre) : NaN);
  return { v6, bits, n, prefix, hadPrefix: pre !== undefined };
}

// Bereiche, die Entra nie als Absender sieht, und solche, die nur Platzhalter sind
const SPECIAL = [
  ['10.0.0.0/8', 'privat (RFC 1918)'], ['172.16.0.0/12', 'privat (RFC 1918)'], ['192.168.0.0/16', 'privat (RFC 1918)'],
  ['127.0.0.0/8', 'Loopback'], ['169.254.0.0/16', 'Link-Local'], ['100.64.0.0/10', 'Carrier-Grade-NAT'], ['0.0.0.0/8', 'reserviert'],
  ['224.0.0.0/4', 'Multicast'], ['240.0.0.0/4', 'reserviert'],
  ['::1/128', 'Loopback'], ['fc00::/7', 'privat (Unique Local)'], ['fe80::/10', 'Link-Local'], ['ff00::/8', 'Multicast'], ['::/128', 'unspezifiziert']
].map(([c, why]) => ({ ...parseCidr(c), why }));
const DOCS = ['192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24', '2001:db8::/32'].map(parseCidr);

const inside = (a, b) => a.v6 === b.v6 && a.prefix >= b.prefix && (a.n & maskOf(a.bits, b.prefix)) === b.n;

function checkIpRanges(text) {
  const r = result([]);
  // "1.2.3.4 - 1.2.3.10" zu einem Token zusammenziehen, damit es als Ganzes gemeldet wird
  const joined = cleanText(text).replace(/([0-9a-f.:]+)\s*[-–]\s*([0-9a-f.:]+)/gi, '$1-$2');
  const tokens = joined.split(/[\s,;]+/).map(t => t.replace(/^["'(\[]+|["')\]]+$/g, '')).filter(Boolean);
  const seen = new Set();
  for (const tok of tokens) {
    if (/^[0-9a-f.:]+[-–][0-9a-f.:]+$/i.test(tok)) {
      r.errors.push(`„${tok}“: Von-bis-Bereiche nimmt Entra nicht an. Bitte in CIDR-Schreibweise angeben, z. B. 203.0.113.0/24.`);
      continue;
    }
    const c = parseCidr(tok);
    if (!c) {
      const addr = tok.split('/')[0];
      const octets = addr.split('.');
      if (!addr.includes(':') && /^[\d.]+$/.test(addr)) {
        if (octets.length !== 4) r.errors.push(`„${tok}“: Eine IPv4-Adresse hat vier Zahlenblöcke, hier sind es ${octets.length}.`);
        else if (octets.some(o => o.length > 1 && o[0] === '0')) r.errors.push(`„${tok}“: Führende Nullen sind nicht erlaubt (z. B. 10 statt 010).`);
        else if (octets.some(o => Number(o) > 255)) r.errors.push(`„${tok}“: Jeder Block einer IPv4-Adresse liegt zwischen 0 und 255.`);
        else r.errors.push(`„${tok}“ ist keine gültige IP-Adresse.`);
      }
      else r.errors.push(`„${tok}“ ist keine gültige IP-Adresse.`);
      continue;
    }
    if (Number.isNaN(c.prefix) || c.prefix > c.bits) { r.errors.push(`„${tok}“: Das Präfix muss zwischen /9 und /${c.bits} liegen.`); continue; }
    if (c.prefix <= 8) { r.errors.push(`„${tok}“: Entra nimmt nur Präfixe größer als /8 an.`); continue; }
    const net = c.n & maskOf(c.bits, c.prefix);
    const norm = { ...c, n: net };
    const out = `${c.v6 ? fmtV6(net) : fmtV4(net)}/${c.prefix}`;
    if (!c.hadPrefix) r.infos.push(`${tok} als Einzeladresse übernommen (${out}).`);
    else if (net !== c.n) r.infos.push(`${tok} enthält Host-Bits, übernommen als Netz ${out}.`);
    const special = SPECIAL.find(s => inside(norm, s) || inside(s, norm));
    if (special) { r.errors.push(`${out}: ${special.why}. Entra sieht nur die öffentliche Adresse, über die das Netz ins Internet geht.`); continue; }
    if (DOCS.some(d => inside(norm, d))) r.warnings.push(`${out} liegt in einem Dokumentationsbereich und ist nur ein Platzhalter.`);
    if (seen.has(out)) { r.infos.push(`${out} doppelt, einmal übernommen.`); continue; }
    seen.add(out);
    r.value.push(out);
  }
  if (r.value.length > 2000) r.errors.push(`${r.value.length} Bereiche. Eine Named Location fasst höchstens 2000.`);
  // Überlappungen nur melden, Entra nimmt sie an
  const parsed = r.value.map(v => ({ s: v, ...parseCidr(v) }));
  for (const a of parsed) for (const b of parsed) {
    if (a !== b && inside(a, b) && a.s !== b.s) r.warnings.push(`${a.s} liegt schon in ${b.s}.`);
  }
  return r;
}

// --- Länder ------------------------------------------------------------------
const COUNTRY_CODES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ ' +
  'CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR ' +
  'GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP ' +
  'KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT ' +
  'MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW ' +
  'SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG ' +
  'UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');
const COUNTRY_GROUPS = {
  'EU': 'AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK'.split(' '),
  'DACH': ['DE', 'AT', 'CH']
};
const regionNames = (() => { try { return new Intl.DisplayNames(['de'], { type: 'region' }); } catch { return null; } })();
function countryName(code) { try { return (regionNames && regionNames.of(code)) || code; } catch { return code; } }
