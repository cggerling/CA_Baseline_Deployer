'use strict';

// ---------------------------------------------------------------------------
// Zugang und API
// ---------------------------------------------------------------------------
const hashToken = new URLSearchParams(location.hash.slice(1)).get('t');
if (hashToken) {
  sessionStorage.setItem('caToken', hashToken);
  history.replaceState(null, '', location.pathname);
}
const TOKEN = sessionStorage.getItem('caToken') || '';

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { 'X-CA-Token': TOKEN, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error((data && data.error) || res.statusText);
  return data;
}

// ---------------------------------------------------------------------------
// Kleine DOM-Helfer. Text kommt immer über textContent ins Dokument.
// ---------------------------------------------------------------------------
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'disabled' || k === 'value' || k === 'open') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
const note = (kind, ...c) => h('div', { class: `note ${kind}` }, ...c);
const badge = (kind, text) => h('span', { class: `badge ${kind || ''}` }, text);
const code = text => h('code', {}, text);

function field(label, input, hint) {
  return h('div', { class: 'field' }, h('label', {}, label), input, hint ? h('div', { class: 'small muted' }, hint) : null);
}
function textInput(value, onChange, placeholder) {
  return h('input', { type: 'text', value: value ?? '', placeholder, spellcheck: 'false', oninput: e => onChange(e.target.value) });
}
function listArea(values, onChange, placeholder) {
  return h('textarea', {
    placeholder,
    value: (values || []).join('\n'),
    oninput: e => onChange(e.target.value.split(/[\n,;]+/).map(s => s.trim()).filter(Boolean))
  });
}
function checkbox(label, checked, onChange, hint, disabled) {
  const id = 'c' + Math.random().toString(36).slice(2);
  return h('div', { class: 'check' },
    h('input', { type: 'checkbox', id, checked, disabled, onchange: e => onChange(e.target.checked) }),
    h('label', { for: id }, label, hint ? h('div', { class: 'small muted' }, hint) : null));
}
function radio(name, label, checked, onChange, hint) {
  const id = 'r' + Math.random().toString(36).slice(2);
  return h('div', { class: 'check' },
    h('input', { type: 'radio', name, id, checked, onchange: () => onChange() }),
    h('label', { for: id }, label, hint ? h('div', { class: 'small muted' }, hint) : null));
}
function copyButton(text) {
  return h('button', { class: 'ghost small', type: 'button', onclick: e => { navigator.clipboard.writeText(text); e.target.textContent = 'kopiert'; } }, 'Kopieren');
}
function help(summary, ...content) {
  return h('details', { class: 'help' }, h('summary', {}, summary), h('div', {}, ...content));
}

// Zeigt das Ergebnis einer Prüfung aus validate.js unter einem Feld an
function showCheck(target, r, okText) {
  target.textContent = '';
  for (const e of r.errors) target.append(h('div', { class: 'msg err' }, e));
  for (const w of r.warnings) target.append(h('div', { class: 'msg warn' }, w));
  for (const i of r.infos) target.append(h('div', { class: 'msg info' }, i));
  if (!r.errors.length && okText) target.append(h('div', { class: 'msg ok' }, okText));
}

// Eingabefeld mit Prüfung. Gespeichert wird nur ein fehlerfreier, bereinigter Wert.
// Beim Verlassen des Felds ersetzt der bereinigte Wert die Eingabe.
function checkedInput({ value, check, onValid, placeholder, okText, multiline }) {
  const msgs = h('div', { class: 'msgs' });
  const input = h(multiline ? 'textarea' : 'input', { type: multiline ? null : 'text', value: value ?? '', placeholder, spellcheck: 'false' });
  let last = null;
  const run = () => {
    last = check(input.value);
    showCheck(msgs, last, typeof okText === 'function' ? okText(last) : okText);
    if (!last.errors.length) onValid(last.value);
    if (last.suggestion) {
      msgs.append(h('button', { class: 'ghost small', type: 'button', onclick: () => { input.value = last.suggestion; run(); } }, `${last.suggestion} übernehmen`));
    }
    return last;
  };
  input.addEventListener('input', run);
  input.addEventListener('blur', () => {
    if (last && !last.errors.length) {
      const v = Array.isArray(last.value) ? last.value.join('\n') : last.value;
      if (input.value !== v) input.value = v;
    }
  });
  if (value) setTimeout(() => { last = check(input.value); showCheck(msgs, last, typeof okText === 'function' ? okText(last) : okText); });
  return { input, msgs, el: h('div', {}, input, msgs), run };
}

// ---------------------------------------------------------------------------
// Zustand
// ---------------------------------------------------------------------------
const S = {
  state: null, defs: null,
  cfgName: null, cfg: null,
  step: 0, check: null, prereq: null, saveTimer: null,
  validated: false, whatIf: false, lookup: null
};

const STEP_LABELS = {
  NamedLocations: 'Named Locations', AuthStrengths: 'Authentifizierungsstärken', Groups: 'Persona-Gruppen',
  Breakglass: 'Breakglass-Konten', AdminUnit: 'Restricted Management AU', AuthMethods: 'Authentifizierungsmethoden',
  ServicePrincipals: 'Service Principals', Policies: 'CA-Policies'
};

// Rollen und die Schritte, für die sie gebraucht werden (Least Privilege)
const ROLES = [
  ['Conditional Access Administrator', 'CA-Policies, Named Locations, Authentifizierungsstärken'],
  ['Authentication Policy Administrator', 'Authentifizierungsmethoden und Passkey-Profile'],
  ['Privileged Role Administrator', 'Persona-Gruppen (role-assignable) und deren Mitglieder, Restricted Management AU, Admin-Consent der Deployer-App'],
  ['User Administrator', 'Breakglass-Konten anlegen'],
  ['Cloud Application Administrator', 'Deployer-App anlegen, fehlende Service Principals registrieren']
];

function deepMerge(base, over) {
  if (Array.isArray(over)) return over.slice();
  if (over && typeof over === 'object') {
    const out = (base && typeof base === 'object' && !Array.isArray(base)) ? { ...base } : {};
    for (const [k, v] of Object.entries(over)) out[k] = deepMerge(out[k], v);
    return out;
  }
  return over === undefined ? base : over;
}

function cfgGet(path, dflt) {
  let n = S.cfg;
  for (const p of path.split('.')) { if (n == null || typeof n !== 'object' || !(p in n)) return dflt; n = n[p]; }
  return n ?? dflt;
}
function cfgSet(path, value) {
  const parts = path.split('.');
  let n = S.cfg;
  for (const p of parts.slice(0, -1)) { if (!n[p] || typeof n[p] !== 'object' || Array.isArray(n[p])) n[p] = {}; n = n[p]; }
  if (value === undefined) delete n[parts.at(-1)];
  else n[parts.at(-1)] = value;
  scheduleSave();
}

function scheduleSave() {
  if (!S.cfgName) return;
  S.validated = false; S.whatIf = false;
  setSaveState('Änderungen werden gespeichert …');
  clearTimeout(S.saveTimer);
  S.saveTimer = setTimeout(saveNow, 600);
}
async function saveNow() {
  if (!S.cfgName) return;
  clearTimeout(S.saveTimer);
  try {
    await api('PUT', `/api/config?name=${encodeURIComponent(S.cfgName)}`, S.cfg);
    setSaveState('gespeichert');
  } catch (e) { setSaveState('Speichern fehlgeschlagen: ' + e.message); }
  renderNav();
}
function setSaveState(t) { document.getElementById('save-state').textContent = t; }

// ---------------------------------------------------------------------------
// Auftrag starten und Ausgabe live anzeigen
// ---------------------------------------------------------------------------
function lineClass(l) {
  if (/^\[(angelegt|aktualisiert)\s*\]|^\[OK\]/.test(l)) return 'l-ok';
  if (/^\[warnung\s*\]|^\[WARNUNG\]|\[FEHLT\]|WARNING/i.test(l)) return 'l-warn';
  if (/^\[fehler\s*\]|^FEHLER|\[stderr\]|Exception/i.test(l)) return 'l-err';
  if (/^\[(würde anlegen|würde ändern)\s*\]/.test(l)) return 'l-plan';
  if (/^===|^Angemeldet|^\*\*\*|^\[INFO\]/.test(l)) return 'l-info';
  return '';
}

function jobPanel(title) {
  const status = badge('', 'bereit');
  const log = h('div', { class: 'log', role: 'log', 'aria-live': 'polite' });
  const stop = h('button', { class: 'secondary', type: 'button', disabled: true }, 'Abbrechen');
  const el = h('div', { class: 'card idle' }, h('div', { class: 'job-head' }, h('strong', {}, title), status, stop), log);
  return {
    el,
    async run(request, onDone) {
      el.classList.remove('idle');
      log.textContent = '';
      status.className = 'badge'; status.textContent = 'läuft';
      let id;
      try { id = (await api('POST', '/api/job', request)).id; }
      catch (e) { status.className = 'badge err'; status.textContent = 'nicht gestartet'; log.append(h('div', { class: 'l-err' }, e.message)); return; }
      stop.disabled = false;
      stop.onclick = () => api('POST', `/api/job/stop?id=${id}`);
      let from = 0;
      const lines = [];
      const tick = async () => {
        let r;
        try { r = await api('GET', `/api/job?id=${id}&from=${from}`); }
        catch (e) { status.textContent = 'Verbindung verloren'; return; }
        for (const l of r.lines) {
          lines.push(l);
          if (l.startsWith('##CABASELINE-RESULT## ')) continue;
          log.append(h('div', { class: lineClass(l) }, l || ' '));
        }
        from += r.lines.length;
        if (r.lines.length) log.scrollTop = log.scrollHeight;
        if (r.secrets && r.secrets.length) showSecrets(r.secrets);
        if (r.done) {
          stop.disabled = true;
          status.className = 'badge ' + (r.exitCode === 0 ? 'ok' : 'err');
          status.textContent = r.exitCode === 0 ? 'fertig' : `beendet mit Fehler (${r.exitCode})`;
          refreshState();
          if (onDone) onDone(r.exitCode, lines);
          return;
        }
        setTimeout(tick, 700);
      };
      tick();
    }
  };
}
const resultOf = lines => {
  const l = lines.find(x => x.startsWith('##CABASELINE-RESULT## '));
  try { return l ? JSON.parse(l.slice(22)) : null; } catch { return null; }
};

function showSecrets(secrets) {
  const root = document.getElementById('modal-root');
  const rows = secrets.map(s => h('tr', {},
    h('td', { class: 'secret' }, s.userPrincipalName),
    h('td', { class: 'secret' }, s.password),
    h('td', {}, h('button', { class: 'secondary', type: 'button', onclick: () => navigator.clipboard.writeText(s.password) }, 'Kopieren'))));
  const close = () => { root.textContent = ''; };
  root.append(h('div', { class: 'modal-back' }, h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' },
    h('h2', {}, 'Kennwörter der neuen Breakglass-Konten'),
    note('err', 'Die Kennwörter werden nur jetzt angezeigt. Der Server hat sie nach dem Abholen verworfen, und im Protokoll stehen sie nicht. Leg sie sofort im Tresor ab, bevor du dieses Fenster schließt.'),
    h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Konto'), h('th', {}, 'Kennwort'), h('th', {}, ''))), h('tbody', {}, rows)),
    h('div', { class: 'actions' }, h('button', { class: 'primary', type: 'button', onclick: close }, 'Kennwörter sind gesichert, schließen')))));
}

// Liest die Zeile "Protokoll: <Pfad>" und zeigt die Zusammenfassung des Laufs
async function summaryFromLines(lines, target) {
  const m = lines.map(l => /^Protokoll:\s*(.+)$/.exec(l)).filter(Boolean).at(-1);
  if (!m) return;
  const name = m[1].trim().split(/[\\/]/).pop();
  let entries;
  try { entries = await api('GET', `/api/log?name=${encodeURIComponent(name)}`); } catch { return; }
  entries = Array.isArray(entries) ? entries : [entries];
  const by = {};
  for (const e of entries) { by[e.Step] ??= {}; by[e.Step][e.Action] = (by[e.Step][e.Action] || 0) + 1; }
  const kinds = { angelegt: 'ok', aktualisiert: 'ok', warnung: 'warn', fehler: 'err' };
  const problems = entries.filter(e => e.Action === 'warnung' || e.Action === 'fehler');
  target.textContent = '';
  target.append(h('div', { class: 'card' },
    h('h3', {}, 'Zusammenfassung'),
    h('p', { class: 'small muted' }, `Protokoll: Logs/${name}`),
    h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Schritt'), h('th', {}, 'Ergebnis'))),
      h('tbody', {}, Object.entries(by).map(([step, acts]) => h('tr', {}, h('td', {}, step),
        h('td', {}, Object.entries(acts).map(([a, n]) => [badge(kinds[a], `${a}: ${n}`), ' '])))))),
    problems.length ? [h('h3', {}, 'Warnungen und Fehler'),
      h('table', {}, h('tbody', {}, problems.map(p => h('tr', {}, h('td', {}, badge(kinds[p.Action], p.Action)), h('td', {}, p.Object), h('td', { class: 'small' }, p.Detail)))))] : null));
}

// ---------------------------------------------------------------------------
// Bausteine für einzelne Schritte
// ---------------------------------------------------------------------------
function explain(what, does, before) {
  const list = items => h('ul', {}, items.map(i => h('li', {}, i)));
  return h('div', { class: 'explain' },
    h('div', {}, h('h4', {}, 'Worum es geht'), list(what)),
    h('div', {}, h('h4', {}, 'Was der Deployer macht'), list(does)),
    h('div', {}, h('h4', {}, 'Vorher erledigen'), list(before)));
}
const needsCfg = () => S.cfg ? null : note('warn', 'Bitte zuerst im Schritt „Tenant“ einen Tenant auswählen oder anlegen.');
const isGuid = v => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v || '');
const zeroGuid = '00000000-0000-0000-0000-000000000000';
const realGuid = v => isGuid(v) && v !== zeroGuid;
const tenantReady = () => S.cfg && realGuid(cfgGet('tenant.tenantId')) && checkMsDomain(cfgGet('tenant.primaryDomain', '')).errors.length === 0;

// Gibt es für diesen Tenant schon ein echtes Deployment?
function hasLiveDeployment() {
  const domain = String(cfgGet('tenant.primaryDomain', '')).replace(/[^\w.-]/g, '_');
  return ((S.state && S.state.logs) || []).some(l => !l.undo && l.name.toLowerCase().startsWith(domain.toLowerCase() + '-') && !/-(validate|whatif)\.json$/.test(l.name));
}

// Gleicht Tenant-ID und Domäne über den öffentlichen Discovery-Endpunkt von Microsoft ab
async function lookupTenant(target, force) {
  const domain = cfgGet('tenant.primaryDomain', '');
  const tid = cfgGet('tenant.tenantId', '');
  target.textContent = '';
  if (checkMsDomain(domain).errors.length) return;
  let r;
  if (!force && S.lookup && S.lookup.domain === domain && !S.lookup.offline) r = S.lookup;
  else {
    target.append(h('div', { class: 'msg info' }, 'Gleiche mit Microsoft ab …'));
    try { r = await api('GET', `/api/tenant-lookup?domain=${encodeURIComponent(domain)}`); }
    catch (e) { target.textContent = ''; target.append(h('div', { class: 'msg warn' }, 'Abgleich nicht möglich: ' + e.message)); return; }
    S.lookup = { domain, ...r };
  }
  target.textContent = '';
  if (!r.found) { target.append(h('div', { class: r.offline ? 'msg warn' : 'msg err' }, r.error || 'Domäne nicht gefunden.')); renderNav(); return; }
  if (!realGuid(tid)) {
    target.append(h('div', { class: 'msg info' }, `Zu ${domain} gehört die Tenant-ID ${r.tenantId}.`),
      h('button', { class: 'secondary small', type: 'button', onclick: () => { cfgSet('tenant.tenantId', r.tenantId); render(); } }, 'Tenant-ID übernehmen'));
  }
  else if (r.tenantId.toLowerCase() === tid.toLowerCase()) target.append(h('div', { class: 'msg ok' }, 'Tenant-ID und Domäne gehören zusammen (bestätigt durch Microsoft).'));
  else {
    target.append(h('div', { class: 'msg err' }, `Die Domäne gehört zu einem anderen Tenant (${r.tenantId}). Eine der beiden Angaben stimmt nicht.`),
      h('button', { class: 'secondary small', type: 'button', onclick: () => { cfgSet('tenant.tenantId', r.tenantId); render(); } }, `${r.tenantId} übernehmen`));
  }
  renderNav();
}

// Länderauswahl mit Suche
function countryPicker(selected, onChange, template) {
  const set = new Set((selected || []).map(c => String(c).toUpperCase()));
  const chips = h('div', { class: 'chips' });
  const list = h('div', { class: 'country-list' });
  let filter = '';
  const all = COUNTRY_CODES.map(c => ({ code: c, name: countryName(c) })).sort((a, b) => a.name.localeCompare(b.name, 'de'));
  const emit = () => { onChange([...set].sort()); drawChips(); };
  const drawChips = () => {
    chips.textContent = '';
    if (!set.size) chips.append(h('span', { class: 'muted small' }, 'Kein Land ausgewählt'));
    for (const c of [...set].sort((a, b) => countryName(a).localeCompare(countryName(b), 'de'))) {
      chips.append(h('button', { type: 'button', class: 'chip', title: 'Entfernen', onclick: () => { set.delete(c); emit(); drawList(); } }, `${countryName(c)} (${c}) ×`));
    }
  };
  const drawList = () => {
    list.textContent = '';
    const f = filter.trim().toLowerCase();
    for (const c of all) {
      if (f && !c.name.toLowerCase().includes(f) && c.code.toLowerCase() !== f) continue;
      list.append(checkbox(`${c.name} (${c.code})`, set.has(c.code), v => { v ? set.add(c.code) : set.delete(c.code); emit(); }));
    }
    if (!list.childElementCount) list.append(h('div', { class: 'muted small' }, 'Kein Land gefunden.'));
  };
  drawChips(); drawList();
  const group = (label, codes) => h('button', { class: 'ghost small', type: 'button', onclick: () => { codes.forEach(c => set.add(c)); emit(); drawList(); } }, `+ ${label}`);
  return h('div', { class: 'picker' },
    chips,
    h('div', { class: 'picker-tools' },
      h('input', { type: 'search', placeholder: 'Land suchen, z. B. Spanien oder ES', oninput: e => { filter = e.target.value; drawList(); } }),
      group('EU', COUNTRY_GROUPS.EU), group('DACH', COUNTRY_GROUPS.DACH),
      template ? h('button', { class: 'ghost small', type: 'button', onclick: () => { set.clear(); template.forEach(c => set.add(c)); emit(); drawList(); } }, 'Vorlage') : null,
      h('button', { class: 'ghost small', type: 'button', onclick: () => { set.clear(); emit(); drawList(); } }, 'Alle entfernen')),
    list);
}

// ---------------------------------------------------------------------------
// Schritte
// ---------------------------------------------------------------------------
const STEPS = [
  {
    id: 'start', title: 'Willkommen',
    status: () => disclaimerOk() ? 'done' : 'open',
    render() {
      return [
        h('h1', {}, 'Conditional Access Framework ausrollen'),
        h('p', {}, 'Mit diesem Assistenten bekommst du einen guten Startpunkt für Conditional Access in deinem Entra-ID-Tenant. Er rollt eine Sammlung von Einstellungen aus, die ein solides Fundament für deine weitere Arbeit mit Conditional Access bilden: Persona-Gruppen, Named Locations, Authentifizierungsstärken, Passkey-Profile, Breakglass-Konten und die CA-Policies selbst. Jeder Schritt erklärt dir, was passiert und was du vorher erledigen solltest.'),
        h('p', {}, 'Fertig ist dein Conditional Access damit nicht. Die Policies starten im Modus „Nur Bericht“, und welche Ausnahmen, Länder und Netze zu deiner Umgebung passen, entscheidest du danach selbst.'),
        explain(
          ['Persona-Gruppen, Named Locations, Authentifizierungsstärken, Passkey-Profile, Breakglass-Konten und CA-Policies', 'Neue Policies starten im Modus „Nur Bericht“'],
          ['Gleicht jeden Schritt mit dem Tenant ab und legt nichts doppelt an', 'Schreibt ein Protokoll, mit dem sich alles zurücknehmen lässt'],
          ['Erst in einem Testtenant ausprobieren', 'Funktionierende Notfallkonten einplanen', 'Den Haftungsausschluss lesen']),
        h('div', { class: 'card' },
          h('h2', {}, 'Haftungsausschluss'),
          h('p', {}, 'Du nutzt das Tool auf eigene Verantwortung. CA-Policies greifen direkt in die Anmeldung aller Benutzer ein, und eine falsch konfigurierte Policy kann Administratoren und Benutzer aussperren. Probier das Deployment deshalb zuerst in einem Testtenant aus, bevor du es produktiv einsetzt. Den vollständigen Text findest du in DISCLAIMER.md im Repository.'),
          checkbox('Ich habe den Haftungsausschluss gelesen und übernehme die Verantwortung für den Einsatz.',
            disclaimerOk(),
            v => { try { sessionStorage.setItem('caDisclaimer', v ? '1' : '0'); } catch { } S.disclaimer = v; render(); }),
          disclaimerOk() ? null : note('warn', 'Weiter geht es erst, wenn du den Haftungsausschluss bestätigt hast.'))
      ];
    }
  },
  {
    id: 'prereq', title: 'Voraussetzungen',
    status: () => S.prereq ? (S.prereq.failed ? 'warn' : 'done') : (S.state && S.state.graphModule ? 'open' : 'warn'),
    render() {
      const panel = jobPanel('Voraussetzungen auf diesem Rechner');
      const result = h('div');
      const showResult = () => {
        result.textContent = '';
        const r = S.prereq;
        if (!r) return;
        const kinds = { ok: ['ok', 'in Ordnung'], warn: ['warn', 'Hinweis'], err: ['err', 'fehlt'], info: ['', 'Info'] };
        result.append(h('div', { class: 'card' },
          h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Prüfung'), h('th', {}, 'Ergebnis'), h('th', {}, ''))),
            h('tbody', {}, r.checks.map(c => h('tr', {},
              h('td', {}, c.name),
              h('td', {}, c.detail, c.fix ? h('div', { class: 'fix' }, h('strong', {}, 'Lösung: '), c.fix, /^[A-Z][a-z]+-[A-Za-z]+ |^\[|^Get-|^Set-|^winget/.test(c.fix) ? copyButton(c.fix) : null) : null),
              h('td', {}, badge(kinds[c.status][0], kinds[c.status][1])))))),
          r.failed ? note('warn', `${r.failed} Voraussetzung(en) fehlen. Fehlende Module installiert „Fehlendes installieren“. Für alles andere steht die Lösung in der Tabelle.`)
                   : note('ok', 'Alle Voraussetzungen auf diesem Rechner sind erfüllt.')));
      };
      const start = mode => panel.run({ type: 'prereq', mode }, (c, lines) => { const r = resultOf(lines); if (r) { S.prereq = r; showResult(); renderNav(); } });
      showResult();
      if (!S.prereq && !S.prereqStarted) { S.prereqStarted = true; setTimeout(() => start('check')); }
      return [
        h('h1', {}, 'Voraussetzungen'),
        explain(
          ['Was dieser Rechner braucht: PowerShell 7 und das Modul Microsoft.Graph.Authentication', 'Welche Admin-Rollen im Tenant gebraucht werden', 'Lizenzen und Einstellungen im Tenant'],
          ['Prüft den Rechner beim Öffnen dieses Schritts automatisch', 'Installiert fehlende Module auf Wunsch, nur für den aktuellen Benutzer', 'Ändert keine Systemeinstellungen. Wo etwas nicht passt, nennt er den Befehl dafür.'],
          ['Nichts. Für die Installation sind keine Administratorrechte auf dem Rechner nötig.']),
        h('div', { class: 'card' },
          h('h2', {}, 'Dieser Rechner'),
          h('p', {}, 'Das Graph-Modul landet im Modulordner des angemeldeten Benutzers (Scope CurrentUser). Dafür braucht es keine lokalen Administratorrechte, nur Zugriff auf die PowerShell Gallery. Hinter einem Proxy oder einer Firewall mit TLS-Inspektion kann die Installation scheitern. Die Tabelle nennt dann Ursache und Lösung.'),
          h('div', { class: 'actions' },
            h('button', { class: 'secondary', type: 'button', onclick: () => start('check') }, 'Erneut prüfen'),
            h('button', { class: 'primary', type: 'button', onclick: () => start('install') }, 'Fehlendes installieren'))),
        panel.el, result,
        h('div', { class: 'card' },
          h('h2', {}, 'Admin-Rollen im Tenant'),
          h('p', {}, 'Wer das Deployment ausführt, braucht passende Entra-Rollen. Diese Rollen müssen während des Deployments aktiv sein. Es gibt zwei Wege:'),
          h('div', { class: 'two-col' },
            h('div', { class: 'option' },
              h('h3', {}, 'Einfach: Global Administrator'),
              h('p', {}, 'Deckt alle Schritte ab, auch das Anlegen der Deployer-App. Für einen Testtenant oder ein kurzes Projekt der schnellste Weg.')),
            h('div', { class: 'option' },
              h('h3', {}, 'Least Privilege: fünf Einzelrollen'),
              h('p', {}, 'Jede Rolle deckt nur ihren Teil ab. Empfohlen für produktive Tenants.'),
              h('table', {}, h('tbody', {}, ROLES.map(([r, w]) => h('tr', {}, h('td', {}, h('strong', {}, r)), h('td', { class: 'small' }, w))))))),
          h('p', { class: 'small muted' }, 'Fehlt eine Rolle, scheitert nur der zugehörige Schritt. Der Deployer meldet das im Protokoll, der Rest läuft weiter. Welche Rollen tatsächlich aktiv sind, zeigt später der Schritt „Anmeldung prüfen“.')),
        h('div', { class: 'card' },
          h('h2', {}, 'Im Tenant'),
          h('table', {}, h('tbody', {},
            h('tr', {}, h('td', {}, 'Entra ID P1'), h('td', {}, 'Conditional Access, dynamische Gastgruppe, role-assignable Groups, Restricted Management AU')),
            h('tr', {}, h('td', {}, 'Entra ID P2'), h('td', {}, 'nur für die risikobasierten Policies #008 bis #011, #102 und #103')),
            h('tr', {}, h('td', {}, 'Sicherheitsstandards aus'), h('td', {}, 'Solange die Sicherheitsstandards (Security Defaults) aktiv sind, lehnt Entra neue CA-Policies ab. Abschalten unter Entra ID > Übersicht > Eigenschaften > Sicherheitsstandards verwalten.')))))
      ];
    }
  },
  {
    id: 'tenant', title: 'Tenant',
    status: () => {
      if (!tenantReady()) return 'open';
      if (S.lookup && S.lookup.domain === cfgGet('tenant.primaryDomain') && S.lookup.found && S.lookup.tenantId !== cfgGet('tenant.tenantId')) return 'warn';
      return 'done';
    },
    render() {
      const configs = (S.state && S.state.configs) || [];
      const list = h('div', { class: 'card' },
        h('h2', {}, 'Gespeicherte Tenants'),
        configs.length
          ? h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'Microsoft-Domäne'), h('th', {}, 'Tenant-ID'), h('th', {}, 'Geändert'), h('th', {}, ''))),
              h('tbody', {}, configs.map(c => h('tr', { class: c.name === S.cfgName ? 'current' : '' },
                h('td', {}, c.name), h('td', {}, c.domain || '–'), h('td', { class: 'mono small' }, realGuid(c.tenantId) ? c.tenantId : '–'), h('td', { class: 'small' }, c.changed),
                h('td', {}, c.name === S.cfgName ? badge('ok', 'ausgewählt') : h('button', { class: 'secondary small', type: 'button', onclick: async () => { await loadConfig(c.name); render(); } }, 'Öffnen'))))))
          : h('p', { class: 'muted' }, 'Noch keine Tenants gespeichert.'),
        h('p', { class: 'small muted' }, 'Gespeichert unter config/tenants/. Der Ordner ist vom Git-Repository ausgeschlossen.'));

      // Neuer Tenant: Domäne und Tenant-ID gleich mit erfassen
      const fresh = { domain: '', tenantId: '' };
      const newMsgs = h('div', { class: 'msgs' });
      const nd = checkedInput({ check: checkMsDomain, onValid: v => { fresh.domain = v; }, placeholder: 'contoso.onmicrosoft.com', okText: 'Format passt' });
      const nt = checkedInput({ check: checkTenantId, onValid: v => { fresh.tenantId = v; }, placeholder: '11111111-2222-3333-4444-555555555555', okText: 'Format passt' });
      const create = async () => {
        const d = nd.run(), t = nt.run();
        if (d.errors.length || t.errors.length) return;
        let name = fresh.domain.replace(/\.onmicrosoft\.com$/, '');
        const taken = new Set(configs.map(c => c.name));
        for (let i = 2; taken.has(name); i++) name = `${fresh.domain.replace(/\.onmicrosoft\.com$/, '')}-${i}`;
        const dup = configs.find(c => (c.tenantId || '').toLowerCase() === fresh.tenantId);
        if (dup && !confirm(`Für diese Tenant-ID gibt es schon „${dup.name}“. Trotzdem einen weiteren Eintrag anlegen?`)) return;
        S.cfgName = name;
        S.cfg = structuredClone(S.defs.example);
        S.cfg.breakglassAccounts = [];
        S.cfg.tenant.primaryDomain = fresh.domain;
        S.cfg.tenant.tenantId = fresh.tenantId;
        S.cfg.tenant.deployerAppClientId = zeroGuid;
        S.check = null; S.lookup = null; S.validated = false; S.whatIf = false;
        localStorage.setItem('caLastConfig', name);
        await saveNow(); await refreshState(); render();
      };
      const newCard = h('div', { class: 'card' },
        h('h2', {}, 'Neuen Tenant anlegen'),
        h('div', { class: 'row' },
          field('Microsoft-Domäne', nd.el, 'Endet auf .onmicrosoft.com.'),
          field('Tenant-ID', nt.el)),
        newMsgs,
        h('div', { class: 'actions' }, h('button', { class: 'primary', type: 'button', onclick: create }, 'Tenant anlegen')));

      const whereToFind = help('Wo finde ich diese Angaben?',
        h('ol', {},
          h('li', {}, 'Im Entra Admin Center anmelden: ', h('a', { href: 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/TenantOverview.ReactView', target: '_blank', rel: 'noopener' }, 'entra.microsoft.com'), '.'),
          h('li', {}, h('strong', {}, 'Tenant-ID: '), 'Entra ID > Übersicht > Registerkarte „Übersicht“ > Feld „Mandanten-ID“ (englisch „Tenant ID“). Rechts daneben ist ein Kopiersymbol.'),
          h('li', {}, h('strong', {}, 'Microsoft-Domäne: '), 'Entra ID > Domänennamen. Gebraucht wird der Eintrag, der auf .onmicrosoft.com endet, nicht die eigene Domäne und nicht die Variante mit .mail.onmicrosoft.com. Im Microsoft 365 Admin Center steht sie unter Einstellungen > Domänen.'),
          h('li', {}, 'Kennst du nur die Domäne, reicht die. Nach dem Anlegen holt der Assistent die passende Tenant-ID bei Microsoft ab.')),
        h('p', { class: 'small muted' }, 'Warum die .onmicrosoft.com-Domäne? Sie gehört fest zum Tenant und lässt sich nicht löschen. Der Deployer bildet daraus die UPNs neuer Breakglass-Konten und die Namen der Protokolldateien.'));

      let current = null;
      if (S.cfg) {
        const lookupTarget = h('div', { class: 'msgs' });
        const cd = checkedInput({ value: cfgGet('tenant.primaryDomain', ''), check: checkMsDomain, onValid: v => { if (v !== cfgGet('tenant.primaryDomain')) { cfgSet('tenant.primaryDomain', v); S.lookup = null; renderNav(); } }, okText: 'Format passt' });
        const ct = checkedInput({ value: realGuid(cfgGet('tenant.tenantId')) ? cfgGet('tenant.tenantId') : '', check: checkTenantId, onValid: v => { if (v !== cfgGet('tenant.tenantId')) { cfgSet('tenant.tenantId', v); renderNav(); } }, okText: 'Format passt', placeholder: 'leer lassen, wenn unbekannt' });
        current = h('div', { class: 'card' },
          h('h2', {}, `Angaben für „${S.cfgName}“`),
          h('div', { class: 'row' }, field('Microsoft-Domäne', cd.el), field('Tenant-ID', ct.el)),
          h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: async () => { await saveNow(); lookupTenant(lookupTarget, true); } }, 'Mit Microsoft abgleichen')),
          lookupTarget,
          h('p', { class: 'small muted' }, 'Der Abgleich fragt den öffentlichen Anmeldedienst von Microsoft, zu welchem Tenant die Domäne gehört. Übertragen wird nur der Domänenname, eine Anmeldung ist nicht nötig.'));
        if (checkMsDomain(cfgGet('tenant.primaryDomain', '')).errors.length === 0) setTimeout(() => lookupTenant(lookupTarget));
      }

      return [
        h('h1', {}, 'Tenant'),
        explain(
          ['Die Angaben zu dem Tenant, in den das Framework ausgerollt wird', 'Für jeden Tenant entsteht eine eigene Config-Datei'],
          ['Prüft die Eingaben und bereinigt Kopierfehler wie Leerzeichen oder Anführungszeichen', 'Gleicht Tenant-ID und Domäne mit Microsoft ab', 'Speichert jede Änderung sofort'],
          ['Tenant-ID und Microsoft-Domäne bereithalten. Wo sie stehen, steht weiter unten.']),
        list, current, newCard, whereToFind
      ];
    }
  },
  {
    id: 'app', title: 'App-Registrierung',
    status: () => realGuid(cfgGet('tenant.deployerAppClientId')) ? 'done' : 'open',
    render() {
      if (needsCfg()) return [h('h1', {}, 'App-Registrierung'), needsCfg()];
      const panel = jobPanel('App-Registrierung anlegen');
      let users = [];
      let usersOk = true;
      const clientId = cfgGet('tenant.deployerAppClientId');
      const ready = tenantReady();
      const upn = checkedInput({ check: checkUpnList, multiline: true, placeholder: 'kollege@contoso.onmicrosoft.com', onValid: v => { users = v; }, okText: r => r.value.length ? `${r.value.length} Admin(s) werden zusätzlich zugewiesen` : null });
      upn.input.addEventListener('input', () => { usersOk = !checkUpnList(upn.input.value).errors.length; });
      const manual = checkedInput({ value: realGuid(clientId) ? clientId : '', check: checkTenantId, placeholder: '11111111-2222-3333-4444-555555555555', okText: 'Format passt', onValid: v => { if (v !== cfgGet('tenant.deployerAppClientId')) { cfgSet('tenant.deployerAppClientId', v); renderNav(); } } });
      return [
        h('h1', {}, 'App-Registrierung'),
        explain(
          ['Der Deployer meldet sich über eine eigene App-Registrierung im Tenant an', 'Du musst sie nicht selbst anlegen, das erledigt der Assistent'],
          ['Legt die App „CA Baseline Deployer“ an: nur für diesen Tenant, ohne Kennwort und ohne Zertifikat', 'Erteilt die Zustimmung (Admin-Consent) für die delegierten Graph-Rechte', 'Schaltet „Zuweisung erforderlich“ ein und weist dich zu', 'Trägt die Client-ID hier ein. Gibt es die App schon, übernimmt er sie.'],
          ['Global Administrator oder Cloud Application Administrator plus Privileged Role Administrator (für den Admin-Consent)']),
        realGuid(clientId) ? note('ok', `Die App ist eingerichtet. Client-ID: ${clientId}`) : null,
        h('div', { class: 'card' },
          h('h2', {}, realGuid(clientId) ? 'Erneut ausführen' : 'App anlegen'),
          h('p', {}, realGuid(clientId)
            ? 'Nur nötig, wenn weitere Admins zugelassen werden sollen. Der Assistent legt keine zweite App an, er ergänzt nur die Zuweisungen.'
            : 'Ein Klick genügt. Es öffnet sich die Microsoft-Anmeldung. Dort mit einem Admin des Tenants anmelden und die angefragten Berechtigungen bestätigen.'),
          ready ? null : note('warn', 'Erst Tenant-ID und Microsoft-Domäne im Schritt „Tenant“ eintragen.'),
          help('Weitere Admins zulassen (optional)',
            h('p', {}, 'Die App lässt nur Benutzer zur Anmeldung zu, die ihr zugewiesen sind. Das verhindert, dass beliebige Konten im Tenant den Deployer nutzen. Du selbst wirst immer zugewiesen.'),
            h('p', {}, 'Sollen später auch Kollegen das Deployment mit dieser App ausführen, trag ihre Anmeldenamen hier ein, einen pro Zeile. Sonst bleibt das Feld leer.'),
            upn.el),
          h('div', { class: 'actions' }, h('button', {
            class: 'primary', type: 'button', disabled: !ready, onclick: async () => {
              const u = checkUpnList(upn.input.value);
              if (u.errors.length) { upn.run(); return; }
              await saveNow();
              panel.run({ type: 'app', config: S.cfgName, assignUsers: u.value }, async c => { if (c === 0) { await loadConfig(S.cfgName); render(); } });
            }
          }, realGuid(clientId) ? 'Zuweisungen ergänzen' : 'App-Registrierung anlegen')),
          h('p', { class: 'small muted' }, 'Das Anmeldefenster von Microsoft erscheint über dem Konsolenfenster, in dem die Oberfläche läuft.')),
        panel.el,
        help('Die App gibt es schon / Client-ID von Hand eintragen',
          h('p', {}, 'Nur nötig, wenn die App außerhalb des Assistenten angelegt wurde. Die Client-ID steht in Entra ID > App-Registrierungen > CA Baseline Deployer > Übersicht unter „Anwendungs-ID (Client)“.'),
          field('Client-ID', manual.el)),
        h('p', { class: 'small muted' }, 'Nach Projektende die App mit tools/Remove-DeployerApp.ps1 deaktivieren oder löschen.')
      ];
    }
  },
  {
    id: 'roles', title: 'Anmeldung prüfen',
    status: () => {
      if (!S.check) return 'open';
      const missing = !S.check.globalAdministrator && S.check.roles.some(r => !r.active);
      return missing || S.check.securityDefaultsEnabled ? 'warn' : 'done';
    },
    render() {
      if (needsCfg()) return [h('h1', {}, 'Anmeldung prüfen'), needsCfg()];
      const panel = jobPanel('Anmeldung und Rollen prüfen');
      const result = h('div');
      const showResult = () => {
        result.textContent = '';
        const c = S.check;
        if (!c) return;
        const ga = c.globalAdministrator;
        result.append(h('div', { class: 'card' },
          h('p', {}, `Angemeldet als ${c.account}`),
          ga ? note('ok', 'Global Administrator ist aktiv und deckt alle Schritte ab.') : null,
          h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Rolle'), h('th', {}, 'Für die Schritte'), h('th', {}, 'Aktiv'))),
            h('tbody', {}, c.roles.map(r => h('tr', {}, h('td', {}, r.name), h('td', {}, r.steps.map(s => STEP_LABELS[s] || s).join(', ')),
              h('td', {}, r.active ? badge('ok', 'ja') : (ga ? badge('', 'über Global Admin') : badge('warn', 'nein'))))))),
          !ga && c.roles.some(r => !r.active) ? note('warn', 'Ohne die fehlenden Rollen scheitern die zugehörigen Schritte. Rolle zuweisen bzw. aktivieren lassen und danach erneut prüfen. Neu zugewiesene Rollen wirken oft erst nach ein paar Minuten.') : null,
          c.securityDefaultsEnabled ? note('err', 'Die Sicherheitsstandards sind eingeschaltet. Solange sie aktiv sind, lehnt Entra das Anlegen von CA-Policies ab.') : note('ok', 'Sicherheitsstandards sind aus.'),
          h('p', {}, `Passkey (FIDO2): ${c.fido2State}, Passkey-Profile: ${c.passkeyProfiles.length ? c.passkeyProfiles.join(', ') : 'noch nicht umgestellt'}`)));
      };
      showResult();
      return [
        h('h1', {}, 'Anmeldung prüfen'),
        explain(
          ['Ein Test, bevor sich etwas im Tenant ändert', 'Die App hat nur delegierte Rechte. Was geht, hängt an den Rollen des angemeldeten Admins.'],
          ['Meldet sich über die Deployer-App an und ändert nichts', 'Liest die aktiven Rollen, die Sicherheitsstandards und den Stand der Passkey-Profile'],
          ['App-Registrierung angelegt', 'Global Administrator oder die Rollen aus dem Schritt „Voraussetzungen“ sind aktiv']),
        h('div', { class: 'actions' },
          h('button', { class: 'primary', type: 'button', disabled: !realGuid(cfgGet('tenant.deployerAppClientId')), onclick: async () => {
            await saveNow();
            panel.run({ type: 'check', config: S.cfgName }, (code, lines) => {
              const r = resultOf(lines);
              if (r) { S.check = r; showResult(); renderNav(); }
            });
          } }, 'Anmeldung und Rollen prüfen')),
        realGuid(cfgGet('tenant.deployerAppClientId')) ? null : note('warn', 'Erst die App-Registrierung anlegen.'),
        panel.el, result
      ];
    }
  },
  {
    id: 'naming', title: 'Persona-Gruppen',
    status: () => {
      if (!S.cfg) return 'open';
      return personaNames().some(n => n.check.errors.length || n.dup) ? 'warn' : 'done';
    },
    render() {
      if (needsCfg()) return [h('h1', {}, 'Persona-Gruppen'), needsCfg()];
      const individual = S.namingMode ? S.namingMode === 'individual' : Object.keys(cfgGet('naming.groupNames', {}) || {}).length > 0;
      const preview = h('tbody');
      const fill = () => {
        preview.textContent = '';
        for (const n of personaNames()) {
          const r = n.check;
          preview.append(h('tr', {},
            h('td', {}, h('code', {}, n.name || '–'),
              r.errors.map(e => h('div', { class: 'msg err' }, e)), n.dup ? h('div', { class: 'msg err' }, 'Name kommt doppelt vor.') : null,
              r.warnings.map(w => h('div', { class: 'msg warn' }, w))),
            h('td', { class: 'small' }, n.persona.description),
            h('td', {}, roleAssignableOf(n.persona) ? badge('', 'role-assignable') : null, ' ', n.persona.dynamic ? badge('', 'dynamisch') : null, ' ', n.persona.extra ? badge('', n.persona.parent ? 'Sub-Persona' : 'zusätzlich') : null)));
        }
        renderNav();
      };

      let body;
      if (!individual) {
        const pat = checkedInput({
          value: cfgGet('naming.groupNamePattern', 'SG-CA-Persona-{Persona}'), check: checkGroupPattern, okText: 'Schema passt',
          onValid: v => { cfgSet('naming.groupNamePattern', v); fill(); }
        });
        const presets = ['SG-CA-Persona-{Persona}', 'CA-Persona-{Persona}', 'GRP_CA_{PERSONA}', 'sec-ca-{persona}', 'Entra CA - {Persona}'];
        const labels = cfgGet('naming.personaLabels', {}) || {};
        body = [
          h('div', { class: 'card' },
            h('h2', {}, 'Namensschema'),
            h('p', {}, 'Das Schema ist ein Mustername mit einem Platzhalter. Für jede Persona ersetzt der Deployer den Platzhalter durch ihre Bezeichnung.'),
            h('table', { class: 'compact' }, h('tbody', {},
              h('tr', {}, h('td', {}, code('{Persona}')), h('td', {}, 'Bezeichnung wie unten eingetragen'), h('td', {}, 'SG-CA-Persona-', h('strong', {}, 'Admins'))),
              h('tr', {}, h('td', {}, code('{persona}')), h('td', {}, 'in Kleinbuchstaben'), h('td', {}, 'sec-ca-', h('strong', {}, 'admins'))),
              h('tr', {}, h('td', {}, code('{PERSONA}')), h('td', {}, 'in Großbuchstaben'), h('td', {}, 'GRP_CA_', h('strong', {}, 'ADMINS'))))),
            h('div', { class: 'presets' }, h('span', { class: 'small muted' }, 'Beispiele: '), presets.map(p => h('button', { class: 'chip', type: 'button', onclick: () => { pat.input.value = p; pat.run(); } }, p))),
            field('Schema', pat.el)),
          h('div', { class: 'card' },
            h('h2', {}, 'Bezeichnung je Persona'),
            h('p', { class: 'small muted' }, 'Ersetzt {Persona} im Schema, z. B. „Administratoren“ statt „Admins“. Leer heißt: der englische Standardname.'),
            h('div', { class: 'grid-2' }, allPersonaEntries().map(p => {
              const ci = checkedInput({
                value: labels[p.key] || '', placeholder: p.key,
                check: raw => { const t = cleanText(raw).trim(); return t ? checkName(raw, 'Die Bezeichnung') : { value: '', errors: [], warnings: [], infos: [] }; },
                onValid: v => { const l = { ...(cfgGet('naming.personaLabels', {}) || {}) }; if (v) l[p.key] = v; else delete l[p.key]; cfgSet('naming.personaLabels', Object.keys(l).length ? l : undefined); fill(); }
              });
              return field(p.key, ci.el);
            })))
        ];
      }
      else {
        const names = cfgGet('naming.groupNames', {}) || {};
        body = [h('div', { class: 'card' },
          h('h2', {}, 'Jeden Namen einzeln festlegen'),
          h('p', { class: 'small muted' }, 'Jede Gruppe bekommt genau den Namen, der hier steht. Ein Schema gilt dann nicht mehr.'),
          allPersonaEntries().map(p => {
            const ci = checkedInput({
              value: names[p.key] || groupNameFromPattern(p.key, p.parent), check: raw => checkName(raw, 'Der Gruppenname'),
              onValid: v => { const g = { ...(cfgGet('naming.groupNames', {}) || {}) }; g[p.key] = v; cfgSet('naming.groupNames', g); fill(); }
            });
            return field(`${p.key}: ${p.description.replace(/^CA Persona:\s*/, '')}`, ci.el);
          }))];
        // Beim Umschalten sofort alle Namen festschreiben, damit die Vorschau stimmt
        const missing = allPersonaEntries().filter(p => !names[p.key]);
        if (missing.length) {
          const g = { ...names }; for (const p of missing) g[p.key] = groupNameFromPattern(p.key, p.parent);
          cfgSet('naming.groupNames', g);
        }
      }

      const au = checkedInput({ value: cfgGet('naming.administrativeUnitName', 'AU-CA-Persona-Restricted'), check: raw => checkName(raw, 'Der Name der AU'), onValid: v => cfgSet('naming.administrativeUnitName', v), okText: null });
      fill();
      return [
        h('h1', {}, 'Persona-Gruppen und Benennung'),
        explain(
          ['Jede Policy zielt auf eine Persona-Gruppe statt auf einzelne Benutzer', 'Bei role-assignable Gruppen kann nur ein Privileged Role Administrator die Mitglieder ändern'],
          ['Legt die sieben Persona-Gruppen mit den Namen aus der Vorschau an, Gäste als dynamische Gruppe', 'Legt zusätzliche Personas als einfache Sicherheitsgruppen an', 'Findet vorhandene Gruppen über den Namen und legt sie nicht doppelt an', 'Legt die Restricted Management AU leer an'],
          ['Namen festlegen und dann nicht mehr ändern. Nach einer Umbenennung findet der Deployer die alten Gruppen nicht mehr und legt neue an.']),
        hasLiveDeployment() ? note('warn', 'Für diesen Tenant gibt es schon ein Deployment. Geänderte Namen führen beim nächsten Lauf zu neuen Gruppen, die alten bleiben bestehen.') : null,
        h('div', { class: 'card' },
          radio('nm', 'Namensschema mit Platzhalter (empfohlen)', !individual, () => { S.namingMode = 'pattern'; cfgSet('naming.groupNames', undefined); render(); }, 'Ein Muster für alle Gruppen, einheitlich und leicht zu pflegen.'),
          radio('nm', 'Jeden Namen einzeln festlegen', individual, () => { S.namingMode = 'individual'; render(); }, 'Für Tenants mit eigener Namenskonvention, die sich nicht in ein Muster fassen lässt.')),
        body,
        roleAssignableCard(),
        additionalPersonasCard(),
        h('div', { class: 'card' }, h('h2', {}, 'Vorschau'), h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Gruppenname'), h('th', {}, 'Persona'), h('th', {}, ''))), preview)),
        h('div', { class: 'card' },
          h('h2', {}, 'Restricted Management AU'),
          h('p', {}, 'Eine Administrative Unit (AU) ist ein Ordner für Benutzer und Gruppen. Die Restricted Management AU ist ein abgeschlossener Ordner: Was darin liegt, dürfen nur Admins ändern, denen eine Rolle ausdrücklich für genau diesen Ordner zugewiesen ist. Sogar ein Global Administrator kommt ohne diese Zuweisung nicht ran.'),
          h('p', {}, 'Wozu das gut ist: Die Persona-Gruppen entscheiden, welche Regeln für wen gelten. Wer die Mitglieder ändern kann, kann sich Regeln entziehen. Ein Beispiel: Ein kompromittiertes Helpdesk-Konto nimmt einen Benutzer in die Breakglass-Gruppe auf. Der ist damit von allen Policies ausgenommen. Liegt die Gruppe in der Restricted Management AU, klappt das nicht.'),
          h('p', {}, 'Der Deployer legt die AU leer an. Nimm die Gruppen erst auf, wenn ihre Mitglieder stimmen, und weise vorher einem Admin eine passende Rolle für die AU zu. Sonst kann danach niemand mehr Mitglieder ändern.'),
          field('Name der Restricted Management AU', au.el))
      ];
    }
  },
  {
    id: 'locations', title: 'Named Locations',
    status: () => {
      if (!S.cfg) return 'open';
      const skip = new Set(cfgGet('namedLocations.skip', []) || []);
      const pending = S.defs.namedLocations.filter(n => !skip.has(n.name) && n.inputs.some(i => i.placeholder) && !nlValue(n).custom);
      const emptyCustom = customNls().filter(c => !(c.type === 'country' ? c.countriesAndRegions : c.ipRanges || []).length);
      return pending.length || emptyCustom.length ? 'warn' : 'done';
    },
    render() {
      if (needsCfg()) return [h('h1', {}, 'Named Locations'), needsCfg()];
      const skip = new Set(cfgGet('namedLocations.skip', []) || []);
      const selected = new Set(selectedKeys());
      const custom = customNls();
      const usersOf = name => S.defs.policies.filter(p => selected.has(p.key) && (p.namedLocations || []).includes(name));

      const templateCard = n => {
        const isCountry = n.type === 'countryNamedLocation';
        const on = !skip.has(n.name);
        const users = usersOf(n.name);
        const v = nlValue(n);
        const placeholder = (n.inputs[0] || {}).placeholder;
        const path = `inputs.namedLocations.${n.name}.${isCountry ? 'countriesAndRegions' : 'ipRanges'}`;
        let editor = null;
        if (on && isCountry) {
          editor = [
            countryPicker(v.values, list => { cfgSet(path, list); renderNav(); }, v.template.length ? v.template : null),
            placeholder && !v.values.length ? note('warn', `Ohne Auswahl setzt der Deployer den Platzhalter ${placeholder}, weil Graph keine leere Länderliste annimmt, und warnt im Protokoll.`) : null
          ];
        }
        else if (on) {
          editor = [ipEditor(v.values, list => { cfgSet(path, list); renderNav(); }),
            placeholder && !v.values.length ? note('warn', `Ohne Eintrag setzt der Deployer den Platzhalter ${placeholder} (ein Dokumentationsbereich, nie im Internet) und warnt im Protokoll.`) : null];
        }
        return h('div', { class: 'card nl' + (on ? '' : ' off') },
          h('div', { class: 'nl-head' },
            checkbox(h('strong', {}, n.name), on, val => {
              const s = new Set(cfgGet('namedLocations.skip', []) || []);
              val ? s.delete(n.name) : s.add(n.name);
              cfgSet('namedLocations.skip', s.size ? [...s] : undefined); render();
            }),
            h('span', {}, badge('', isCountry ? 'Länder' : 'IP-Bereiche'), ' ', n.trusted ? badge('', 'vertrauenswürdig') : null)),
          NL_INFO[n.name] ? h('p', {}, NL_INFO[n.name]) : null,
          h('p', { class: 'small muted' }, users.length ? `Verwendet von: ${users.map(p => p.displayName).join(', ')}` : 'Keine der ausgewählten Policies verwendet sie. Sie liegt bereit für eigene Regeln.'),
          !on && users.length ? note('warn', `Abgewählt. Gibt es die Location im Tenant noch nicht, überspringt der Deployer ${users.length === 1 ? 'diese Policy' : 'diese Policies'}.`) : null,
          editor);
      };

      const customCard = c => {
        const saveOne = patch => saveCustomNls(customNls().map(x => x.name === c.name ? { ...x, ...patch } : x));
        const isCountry = c.type === 'country';
        return h('div', { class: 'card nl' },
          h('div', { class: 'nl-head' },
            h('strong', {}, c.name),
            h('span', {}, badge('', 'eigene'), ' ', badge('', isCountry ? 'Länder' : 'IP-Bereiche'), ' ', c.trusted ? badge('', 'vertrauenswürdig') : null,
              ' ', h('button', { class: 'ghost small', type: 'button', onclick: () => { if (confirm(`„${c.name}“ entfernen? Im Tenant wird nichts gelöscht, der Deployer legt sie nur nicht mehr an.`)) saveCustomNls(customNls().filter(x => x.name !== c.name)); } }, 'Entfernen'))),
          c.source && c.source.vendor === 'zscaler'
            ? note('info', `Importiert aus der Zscaler-Cloud ${c.source.cloud} am ${c.source.fetched}. Beim Deployment holt der Deployer die Liste erneut beim Hersteller ab und nimmt die aktuelle.`)
            : null,
          isCountry
            ? countryPicker(c.countriesAndRegions || [], list => saveOne({ countriesAndRegions: list }), null)
            : [ipEditor(c.ipRanges || [], list => saveOne({ ipRanges: list })),
               checkbox('Als vertrauenswürdig markieren', !!c.trusted, v => saveOne({ trusted: v }), 'Nur für Netze, die du selbst kontrollierst. Anmeldungen von dort stuft Entra als weniger riskant ein.')]);
      };

      // Nach Persona gliedern: der zweite Teil des Namens, NL-<Persona>-...
      const sections = [{ key: 'Global', label: 'Global', group: 'alle Benutzer' },
        ...S.defs.personas.map(p => ({ key: p.key, label: p.key, group: personaNames().find(n => n.persona.key === p.key)?.name }))];
      const personaOf = name => (/^NL-([^-]+)-/.exec(name) || [])[1];
      const known = new Set(sections.map(s => s.key));

      return [
        h('h1', {}, 'Named Locations'),
        explain(
          ['Länder und IP-Bereiche, auf die sich Policies beziehen können', 'Damit sagst du Entra, woher Anmeldungen kommen dürfen oder wo sie verdächtig sind'],
          ['Legt die ausgewählten Locations an, die es noch nicht gibt, und aktualisiert vorhandene', 'Legt deine eigenen Locations an', 'Setzt Platzhalter, wo Werte fehlen, und warnt dann im Protokoll'],
          ['Öffentliche IP-Adressen der Standorte heraussuchen', 'Klären, aus welchen Ländern gearbeitet wird']),
        note('info', 'Empfohlen ist, alle Named Locations auszurollen, weil die Policies darauf aufbauen. Prüf nach dem Deployment im Entra Admin Center unter Conditional Access > Named Locations, ob Länder und IP-Bereiche zum Tenant passen.'),
        sections.map(s => {
          const tpl = S.defs.namedLocations.filter(n => (personaOf(n.name) || 'Global') === s.key || (s.key === 'Global' && !known.has(personaOf(n.name))));
          const own = custom.filter(c => (c.persona || 'Global') === s.key);
          if (!tpl.length && !own.length) return null;
          return h('section', { class: 'nl-section' },
            h('h2', {}, s.key === 'Global' ? 'Global: gilt für alle' : `${s.label}`, s.group && s.key !== 'Global' ? h('span', { class: 'muted small' }, `  Gruppe ${s.group}`) : null),
            PERSONA_NL_INFO[s.key] ? h('p', {}, PERSONA_NL_INFO[s.key]) : null,
            tpl.map(templateCard), own.map(customCard));
        }),
        customNlForm(),
        zscalerCard()
      ];
    }
  },
  {
    id: 'policies', title: 'Policies',
    status: () => {
      if (!S.cfg) return 'open';
      const need = selectedKeys().some(k => S.defs.policies.find(p => p.key === k)?.inputs.some(i => i.required && !(cfgGet(`inputs.${i.name}`, []) || []).length));
      return need ? 'warn' : 'done';
    },
    render() {
      if (needsCfg()) return [h('h1', {}, 'Policies'), needsCfg()];
      const cats = [...new Set(S.defs.policies.map(p => p.category))];
      const sel = new Set(selectedKeys());
      const skipNl = new Set(cfgGet('namedLocations.skip', []) || []);
      const set = (key, on) => { on ? sel.add(key) : sel.delete(key); writeSelection(sel); render(); };
      const inputs = [];
      for (const p of S.defs.policies.filter(p => sel.has(p.key))) {
        for (const i of p.inputs) {
          const vals = cfgGet(`inputs.${i.name}`, []) || [];
          const empty = vals.length === 1 && vals[0] === '-';
          inputs.push(h('div', { class: 'card' },
            h('h3', {}, `${p.displayName}: ${i.name}`),
            h('p', { class: 'small muted' }, i.hint),
            empty ? null : field('Werte, einer pro Zeile', listArea(vals, v => { cfgSet(`inputs.${i.name}`, v); renderNav(); }, 'z. B. Autopilot-Standard')),
            checkbox('Bewusst leer lassen', empty, v => { cfgSet(`inputs.${i.name}`, v ? ['-'] : []); render(); }, 'Ohne Werte und ohne dieses Häkchen überspringt der Deployer die Policy.')));
        }
      }
      const hintFor = p => {
        const parts = [];
        if (p.inputs.length) parts.push('braucht eine Eingabe');
        const off = (p.namedLocations || []).filter(n => skipNl.has(n));
        if (off.length) parts.push(`nutzt die abgewählte Location ${off.join(', ')}`);
        return parts.join('; ') || null;
      };
      return [
        h('h1', {}, 'Policies auswählen'),
        explain(
          ['37 Policies in sechs Kategorien: Global und je eine pro Persona', 'Global-Policies gelten für alle, die anderen nur für ihre Persona'],
          ['Legt die ausgewählten Policies an. Neue Policies bekommen den Status unten.', 'Bei Policies, die es schon gibt, bleibt der Status unverändert'],
          ['Klären, welche Policies gebraucht werden', 'Für #210 die Namen der Autopilot-Enrollment-Profile heraussuchen']),
        h('div', { class: 'card' },
          field('Status neuer Policies', h('select', { onchange: e => cfgSet('policies.stateOnCreate', e.target.value) },
            [['enabledForReportingButNotEnforced', 'Nur Bericht (empfohlen)'], ['disabled', 'Aus'], ['enabled', 'Ein']].map(([v, t]) =>
              h('option', { value: v, selected: cfgGet('policies.stateOnCreate', 'enabledForReportingButNotEnforced') === v }, t)))),
          cfgGet('policies.stateOnCreate') === 'enabled' ? note('err', 'Policies werden sofort wirksam. Das nur nach einem Testlauf im Modus „Nur Bericht“ verwenden.') : null,
          h('p', { class: 'small muted' }, `${sel.size} von ${S.defs.policies.length} ausgewählt`)),
        cats.map(cat => {
          const list = S.defs.policies.filter(p => p.category === cat);
          const all = list.every(p => sel.has(p.key));
          return h('div', { class: 'card cat' },
            h('div', { class: 'cat-head' }, h('h2', {}, cat),
              h('button', { class: 'ghost', type: 'button', onclick: () => { list.forEach(p => all ? sel.delete(p.key) : sel.add(p.key)); writeSelection(sel); render(); } }, all ? 'Keine' : 'Alle')),
            h('div', { class: 'policy-list' }, list.map(p => checkbox(p.displayName, sel.has(p.key), v => set(p.key, v), hintFor(p)))));
        }),
        inputs.length ? [h('h2', {}, 'Eingaben'), inputs] : null
      ];
    }
  },
  {
    id: 'methods', title: 'Authentifizierungsmethoden',
    status: () => S.cfg && cfgGet('authenticationMethods.passkeyHardwareProducts', null) !== null && cfgGet('authenticationMethods.migrateToPasskeyProfiles', null) !== null ? 'done' : (S.cfg ? 'warn' : 'open'),
    render() {
      if (needsCfg()) return [h('h1', {}, 'Authentifizierungsmethoden'), needsCfg()];
      const personas = new Set(cfgGet('authenticationMethods.passkeyPersonas', ['Admins']));
      personas.add('Admins');
      const byPersona = { ...(cfgGet('authenticationMethods.passkeyProfileByPersona', {}) || {}) };
      const hw = cfgGet('authenticationMethods.passkeyHardwareProducts', null);
      const hwSet = new Set(hw || []);
      const yubi = S.defs.aaguidProducts.filter(p => /YubiKey/i.test(p.name));
      const migrate = cfgGet('authenticationMethods.migrateToPasskeyProfiles', null);
      const catPanel = jobPanel('AAGUID-Katalog aktualisieren');
      const profiles = S.defs.passkeyProfiles;
      const profName = k => (profiles.find(p => p.key === k) || {}).name || k;
      const savePersonas = () => cfgSet('authenticationMethods.passkeyPersonas', [...personas]);
      const describe = p => `${p.passkeyTypes === 'deviceBound' ? 'nur gerätegebunden' : 'gerätegebunden und synchronisiert'}, Attestierung ${p.attestation === 'disabled' ? 'aus' : 'an'}, ${p.restricted ? 'nur erlaubte Modelle (AAGUID-Liste)' : 'alle Modelle'}`;
      return [
        h('h1', {}, 'Authentifizierungsmethoden und Passkeys'),
        explain(
          ['Die Stärken brauchen bestimmte Methoden: Passkey, Authenticator, Temporary Access Pass', 'Passkey-Profile legen fest, welche Passkeys eine Gruppe registrieren darf'],
          ['Schaltet nur deaktivierte Methoden ein, und dann nur für die Persona-Gruppen', 'Aktive Methoden bleiben unverändert', 'Legt die Profile „Privileged User Accounts“ und „Non-Privileged User Accounts“ an'],
          ['Klären, welche Hardware-Schlüssel die Admins nutzen', 'Entscheiden, ob der Tenant auf Passkey-Profile umgestellt werden darf']),
        authStrengthsCard(),
        h('div', { class: 'card' },
          h('h2', {}, 'Die beiden Profile'),
          h('table', {}, h('tbody', {}, profiles.map(p => h('tr', {}, h('td', {}, h('strong', {}, p.name)), h('td', { class: 'small' }, describe(p))))))),
        h('div', { class: 'card' },
          h('h2', {}, 'Wer bekommt Passkeys, mit welchem Profil'),
          h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Persona'), h('th', {}, 'Passkey-Profil'))),
            h('tbody', {}, S.defs.personas.map(p => {
              const admin = p.key === 'Admins';
              const on = personas.has(p.key);
              const current = admin ? 'Privileged' : (byPersona[p.key] || 'Privileged');
              return h('tr', {},
                h('td', {}, checkbox(p.key, on, v => { v ? personas.add(p.key) : personas.delete(p.key); savePersonas(); render(); }, admin ? 'immer dabei' : null, admin)),
                h('td', {}, on
                  ? h('select', { disabled: admin, onchange: e => { byPersona[p.key] = e.target.value; cfgSet('authenticationMethods.passkeyProfileByPersona', byPersona); } },
                      profiles.map(pr => h('option', { value: pr.key, selected: current === pr.key }, pr.name)))
                  : h('span', { class: 'muted small' }, 'kein Passkey')));
            }))),
          h('p', { class: 'small muted' }, `Admins bekommen immer „${profName('Privileged')}“. Ein Profil ohne zugewiesene Persona wird trotzdem angelegt, damit es später nur noch zugewiesen werden muss.`)),
        h('div', { class: 'card' },
          h('h2', {}, `YubiKeys im Profil „${profName('Privileged')}“`),
          yubi.length ? [
            h('p', { class: 'small muted' }, `Aus dem FIDO Metadata Service, Stand ${S.defs.catalogGenerated || 'unbekannt'}. Yubico vergibt pro Firmware eine eigene AAGUID, deshalb steht die Firmware dabei.`),
            yubi.map(p => checkbox(p.name, hwSet.has(p.key), v => { v ? hwSet.add(p.key) : hwSet.delete(p.key); cfgSet('authenticationMethods.passkeyHardwareProducts', [...hwSet]); renderNav(); }, `Firmware ${p.firmware.join(', ')}`)),
            hw === null ? note('warn', 'Noch keine Auswahl gespeichert. Ohne Auswahl erlaubt das Profil keinen YubiKey.') : null,
            h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: () => { cfgSet('authenticationMethods.passkeyHardwareProducts', [...hwSet]); renderNav(); render(); } }, hwSet.size ? 'Auswahl übernehmen' : 'Bewusst keinen YubiKey erlauben'))
          ] : note('warn', 'Der AAGUID-Katalog ist leer. Er wird aus dem FIDO Metadata Service erzeugt. Solange er fehlt, legt der Deployer das Profil für privilegierte Konten nicht an.'),
          h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: () => catPanel.run({ type: 'catalog' }, async c => { if (c === 0) { await loadDefs(); render(); } }) }, 'Katalog aktualisieren'))),
        catPanel.el,
        h('div', { class: 'card' },
          h('h2', {}, 'Umstellung auf Passkey-Profile'),
          h('p', {}, 'Ist der Tenant noch nicht umgestellt, braucht der Deployer eine Entscheidung. Laut Microsoft lässt sich die Umstellung nicht zurücknehmen, auch nicht mit dem Undo. Die bisherigen Einstellungen wandern dabei in ein Standardprofil.'),
          radio('migrate', 'Umstellen erlaubt', migrate === true, () => { cfgSet('authenticationMethods.migrateToPasskeyProfiles', true); render(); }),
          radio('migrate', 'Nicht umstellen, Profile dann weglassen', migrate === false, () => { cfgSet('authenticationMethods.migrateToPasskeyProfiles', false); render(); }),
          h('p', { class: 'small muted' }, 'Ob der Tenant schon umgestellt ist, zeigt der Schritt „Anmeldung prüfen“.'))
      ];
    }
  },
  {
    id: 'breakglass', title: 'Breakglass-Konten',
    status: () => S.cfg ? 'done' : 'open',
    render() {
      if (needsCfg()) return [h('h1', {}, 'Breakglass-Konten'), needsCfg()];
      const accounts = cfgGet('breakglassAccounts', []) || [];
      const bg = S.defs.breakglass;
      const mode = S.bgMode ?? (accounts.length ? 'existing' : 'new');
      const sample = Array.from({ length: bg.count }, (_, i) => bg.userPrincipalNamePattern.replace('{Nr}', String(i + 1).padStart(bg.numberFormat.length, '0')).replace('{InitialDomain}', cfgGet('tenant.primaryDomain', '<domäne>')));
      const upn = checkedInput({ value: accounts.join('\n'), check: checkUpnList, multiline: true, placeholder: 'notfall01@contoso.onmicrosoft.com', onValid: v => cfgSet('breakglassAccounts', v) });
      return [
        h('h1', {}, 'Breakglass-Konten'),
        explain(
          ['Notfallkonten, die bei einer Fehlkonfiguration den Zugang retten', 'Sie sind aus allen Policies ausgenommen, über die Persona-Gruppe Breakglass'],
          ['Nimmt vorhandene Konten in die Breakglass-Gruppe auf', 'Oder legt zwei neue Konten an. Die Kennwörter erscheinen einmal in dieser Oberfläche und landen nicht im Protokoll.'],
          ['Klären, ob es schon Notfallkonten gibt', 'Einen Tresor für die Kennwörter bereithalten', 'Rollen und Überwachung der Konten anschließend selbst einrichten']),
        h('div', { class: 'card' },
          radio('bg', `Zwei neue Konten anlegen: ${sample.join(', ')}`, mode === 'new', () => { S.bgMode = 'new'; cfgSet('breakglassAccounts', []); render(); }),
          radio('bg', 'Vorhandene Konten verwenden', mode === 'existing', () => { S.bgMode = 'existing'; render(); }),
          mode === 'existing' ? field('Anmeldenamen der vorhandenen Konten', upn.el, 'Einer pro Zeile') : null)
      ];
    }
  },
  {
    id: 'test', title: 'Prüfen und Probelauf',
    status: () => S.whatIf ? 'done' : (S.validated ? 'warn' : 'open'),
    render() {
      if (needsCfg()) return [h('h1', {}, 'Prüfen und Probelauf'), needsCfg()];
      const v = jobPanel('Offline-Prüfung');
      const w = jobPanel('Probelauf gegen den Tenant (WhatIf)');
      const vSum = h('div'), wSum = h('div');
      return [
        h('h1', {}, 'Prüfen und Probelauf'),
        explain(
          ['Zwei Durchläufe, bevor sich im Tenant etwas ändert'],
          ['Offline-Prüfung: löst alle Platzhalter mit Test-IDs auf, ohne Anmeldung', 'Probelauf: meldet sich an, liest den Tenant und zeigt, was angelegt oder geändert würde. Geändert wird nichts.'],
          ['Anmeldung geprüft (Schritt „Anmeldung prüfen“)', 'Warnungen der Prüfung durchgehen']),
        h('div', { class: 'actions' },
          h('button', { class: 'secondary', type: 'button', onclick: async () => { await saveNow(); v.run({ type: 'deploy', config: S.cfgName, mode: 'validate' }, (c, l) => { S.validated = c === 0; renderNav(); summaryFromLines(l, vSum); }); } }, 'Offline prüfen'),
          h('button', { class: 'primary', type: 'button', onclick: async () => { await saveNow(); w.run({ type: 'deploy', config: S.cfgName, mode: 'whatif' }, (c, l) => { S.whatIf = c === 0; renderNav(); summaryFromLines(l, wSum); }); } }, 'Probelauf starten')),
        v.el, vSum, w.el, wSum
      ];
    }
  },
  {
    id: 'deploy', title: 'Ausrollen',
    status: () => 'open',
    render() {
      if (needsCfg()) return [h('h1', {}, 'Ausrollen'), needsCfg()];
      S.deploySteps ??= new Set(Object.keys(STEP_LABELS));
      const panel = jobPanel('Deployment');
      const sum = h('div');
      let confirm = '';
      const btn = h('button', { class: 'danger', type: 'button', disabled: true, onclick: async () => {
        await saveNow();
        const all = S.deploySteps.size === Object.keys(STEP_LABELS).length;
        panel.run({ type: 'deploy', config: S.cfgName, mode: 'live', steps: all ? null : [...S.deploySteps] }, (c, l) => summaryFromLines(l, sum));
      } }, 'Jetzt ausrollen');
      const open = STEPS.filter(s => !['start', 'deploy', 'undo', 'test'].includes(s.id)).filter(s => { try { return s.status() === 'warn'; } catch { return false; } });
      return [
        h('h1', {}, 'Ausrollen'),
        explain(
          ['Der echte Lauf gegen den Tenant'],
          ['Arbeitet die Schritte der Reihe nach ab und schreibt nach jedem Eintrag ins Protokoll', 'Neue Policies starten mit dem Status aus dem Schritt „Policies“', 'Zeigt Kennwörter neuer Breakglass-Konten einmal an'],
          ['Probelauf ohne Fehler', 'Rollen aktiv: Global Administrator oder die Einzelrollen', 'Tresor für die Breakglass-Kennwörter bereit']),
        S.whatIf ? null : note('warn', 'Seit der letzten Änderung gab es keinen erfolgreichen Probelauf.'),
        open.length ? note('warn', `Offene Punkte in: ${open.map(s => s.title).join(', ')}`) : null,
        h('div', { class: 'card' },
          h('h2', {}, 'Schritte'),
          h('p', { class: 'small muted' }, 'Abgewählte Schritte laufen nur lesend mit, soweit spätere Schritte ihre IDs brauchen.'),
          Object.entries(STEP_LABELS).map(([k, t]) => checkbox(t, S.deploySteps.has(k), v => { v ? S.deploySteps.add(k) : S.deploySteps.delete(k); }))),
        h('div', { class: 'card' },
          field(`Zum Bestätigen die Microsoft-Domäne „${cfgGet('tenant.primaryDomain')}“ eingeben`, textInput('', v => { confirm = v; btn.disabled = cleanText(confirm).trim().toLowerCase() !== String(cfgGet('tenant.primaryDomain', '')).toLowerCase(); })),
          h('div', { class: 'actions' }, btn)),
        panel.el, sum
      ];
    }
  },
  {
    id: 'undo', title: 'Zurücknehmen',
    status: () => 'open',
    render() {
      if (needsCfg()) return [h('h1', {}, 'Zurücknehmen'), needsCfg()];
      const domain = String(cfgGet('tenant.primaryDomain', '')).replace(/[^\w.-]/g, '_');
      const logs = ((S.state && S.state.logs) || []).filter(l => !l.undo && l.name.toLowerCase().startsWith(domain.toLowerCase() + '-') && !/-(validate|whatif)\.json$/.test(l.name));
      const chosen = new Set();
      let purge = false;
      const panel = jobPanel('Rücknahme');
      const sum = h('div');
      const runUndo = async mode => {
        if (!chosen.size) { alert('Bitte mindestens ein Protokoll auswählen.'); return; }
        if (mode === 'live' && prompt('Zum Bestätigen JA eingeben') !== 'JA') return;
        panel.run({ type: 'undo', config: S.cfgName, mode, logs: [...chosen], purge }, (c, l) => summaryFromLines(l, sum));
      };
      return [
        h('h1', {}, 'Deployment zurücknehmen'),
        explain(
          ['Nimmt zurück, was ein Lauf laut Protokoll angelegt oder geändert hat'],
          ['Löscht angelegte Objekte, neueste zuerst, und entfernt vorher die Mitgliedschaften', 'Setzt Methoden, Stärken und Passkey-Profile auf den alten Stand', 'Meldet, was sich nur von Hand zurücksetzen lässt'],
          ['Dieselben Rollen wie beim Deployment', 'Erst den Probelauf ansehen']),
        h('div', { class: 'card' },
          h('h2', {}, `Protokolle für ${cfgGet('tenant.primaryDomain')}`),
          logs.length ? logs.map(l => checkbox(`${l.name}`, false, v => { v ? chosen.add(l.name) : chosen.delete(l.name); }, l.time)) : h('p', { class: 'muted' }, 'Keine Protokolle gefunden.'),
          checkbox('Endgültig löschen (Purge)', false, v => { purge = v; }, 'Gruppen, Benutzer und die AU landen sonst 30 Tage im Papierkorb. Für Testtenants praktisch.'),
          h('div', { class: 'actions' },
            h('button', { class: 'secondary', type: 'button', onclick: () => runUndo('whatif') }, 'Probelauf der Rücknahme'),
            h('button', { class: 'danger', type: 'button', onclick: () => runUndo('live') }, 'Zurücknehmen'))),
        panel.el, sum
      ];
    }
  }
];

// ---------------------------------------------------------------------------
// Hilfen für Schritte
// ---------------------------------------------------------------------------
const personaLabel = key => String((cfgGet('naming.personaLabels', {}) || {})[key] || key).trim();
function groupNameFromPattern(key, parent) {
  const label = parent ? `${personaLabel(parent)}-${personaLabel(key)}` : personaLabel(key);
  const pattern = String(cfgGet('naming.groupNamePattern', 'SG-CA-Persona-{Persona}')).trim();
  return pattern.replaceAll('{Persona}', label).replaceAll('{persona}', label.toLowerCase()).replaceAll('{PERSONA}', label.toUpperCase());
}
const additionalPersonas = () => (cfgGet('personas.additional', []) || []).filter(Boolean);
// Gruppennamen genauso gebildet wie im Modul (Get-PersonaGroupName), dazu die Prüfung.
// Zusätzliche Personas sind dabei, damit auch ihre Namen eindeutig bleiben.
function personaNames() {
  const fixed = cfgGet('naming.groupNames', {}) || {};
  const extra = additionalPersonas().map(x => ({ key: x.key, description: x.description || (x.parent ? `Sub-Persona von ${x.parent}` : 'zusätzliche Persona'), parent: x.parent, extra: true }));
  const list = [...S.defs.personas, ...extra].map(p => {
    const name = (fixed[p.key] && String(fixed[p.key]).trim()) || groupNameFromPattern(p.key, p.parent);
    return { persona: p, name, check: checkName(name, 'Der Gruppenname') };
  });
  const count = {};
  for (const n of list) count[n.name.toLowerCase()] = (count[n.name.toLowerCase()] || 0) + 1;
  for (const n of list) n.dup = count[n.name.toLowerCase()] > 1;
  return list;
}
// Aktuelle Werte einer Named Location: aus der Config, sonst aus der Vorlage (ohne Platzhalter)
function nlValue(n) {
  const isCountry = n.type === 'countryNamedLocation';
  const key = isCountry ? 'countriesAndRegions' : 'ipRanges';
  const placeholder = (n.inputs[0] || {}).placeholder;
  const template = (isCountry ? n.countries : n.ipRanges).filter(v => v !== placeholder);
  const own = cfgGet(`inputs.namedLocations.${n.name}.${key}`, null);
  return { values: own ? own : template, template, custom: Array.isArray(own) && own.length > 0 };
}

// ---------------------------------------------------------------------------
// Named Locations: Erklärungen, eigene Locations, Import
// ---------------------------------------------------------------------------
const PERSONA_NL_INFO = {
  Global: 'Diese Locations betreffen alle Benutzer. Die Sperrliste hält Anmeldungen aus Ländern fern, in denen niemand aus dem Unternehmen arbeitet. Die Firmenstandorte sind die Netze, denen Entra vertrauen darf.',
  Admins: 'Admin-Konten sind das lohnendste Ziel für Angreifer. Je enger du eingrenzt, von wo sich Admins anmelden dürfen, desto weniger nützt ein gestohlenes Admin-Kennwort.',
  Internals: 'Mitarbeitende arbeiten meist aus wenigen Ländern. Mit einer Länderliste kannst du später eine Regel bauen, die Anmeldungen von ganz woanders sperrt oder eine zusätzliche Bestätigung verlangt.',
  Externals: 'Externe arbeiten oft aus anderen Ländern als die eigenen Leute. Eine eigene Länderliste erlaubt dafür eine passende Regel, ohne die Liste der Mitarbeitenden aufzuweichen.',
  Developers: 'Entwickler arbeiten häufig mit Kollegen oder Dienstleistern im Ausland. Die eigene Länderliste trennt das von den Regeln für alle anderen.',
  Guests: 'Gäste kommen aus Partnerfirmen und melden sich von überall an. Eine Länderliste begrenzt, von wo Gastkonten genutzt werden können.',
  ServiceAccounts: 'Dienstkonten melden sich immer von denselben Servern an. Eine Anmeldung von woanders ist fast immer ein Zeichen, dass jemand das Kennwort missbraucht.'
};
const NL_INFO = {
  'NL-Global-Country_Blacklist-Country_IP': 'Länder, aus denen es keine Anmeldung geben soll. Beispiel: Ein Angreifer hat ein Kennwort erbeutet und meldet sich aus einem dieser Länder an. Policy #005 blockt ihn, egal welches Konto er benutzt.',
  'NL-Global-Corporate_Sites-IP': 'Die öffentlichen IP-Adressen deiner Standorte, also die Adressen, unter denen das Büro im Internet auftritt. Beispiel: Ein Admin meldet sich im Büro an und darf das. Mit demselben Konto aus einem Café klappt es nicht, solange das Land nicht freigegeben ist.',
  'NL-Global-Travel_Exception-Country_IP': 'Länder für Dienstreisen. Beispiel: Eine Kollegin ist zwei Wochen auf einer Messe in Las Vegas. Das Land kommt für diese Zeit hier hinein und danach wieder heraus. Die Regeln für alle anderen bleiben unverändert.',
  'NL-Admins-Country_Whitelist-Country_IP': 'Länder, aus denen sich Admins anmelden dürfen. Policy #105 blockt Admin-Anmeldungen von überall sonst, ausgenommen die Firmenstandorte.',
  'NL-Admins-Trusted_Networks-IP': 'Netze für Admin-Arbeit, etwa ein Admin-VPN oder ein Jump-Host. Beispiel: Admin-Portale sollen nur von dort aus erreichbar sein.',
  'NL-Internals-Country_Whitelist-Country_IP': 'Länder, in denen Mitarbeitende normalerweise arbeiten.',
  'NL-Externals-Country_Whitelist-Country_IP': 'Länder, in denen externe Mitarbeitende normalerweise arbeiten.',
  'NL-Developers-Country_Whitelist-Country_IP': 'Länder, in denen Entwickler normalerweise arbeiten.',
  'NL-Guests-Country_Whitelist-Country_IP': 'Länder, aus denen sich Gäste anmelden dürfen.',
  'NL-ServiceAccounts-Country_Whitelist-Country_IP': 'Länder, in denen die Server der Dienstkonten stehen.',
  'NL-ServiceAccounts-Trusted_Networks-IP': 'Die Netze, aus denen Dienstkonten arbeiten, zum Beispiel das Rechenzentrum. Policy #502 erlaubt Dienstkonten bisher nur die Firmenstandorte.'
};

const customNls = () => (cfgGet('namedLocations.custom', []) || []).filter(Boolean);
function saveCustomNls(list) { cfgSet('namedLocations.custom', list.length ? list : undefined); render(); }
const nlNameTaken = name => [...S.defs.namedLocations.map(n => n.name), ...customNls().map(c => c.name)].some(n => n.toLowerCase() === name.toLowerCase());

// IP-Feld mit Prüfung und Import aus einer Datei (wie im Entra-Portal: ein Bereich pro Zeile)
function ipEditor(values, onValid) {
  const ip = checkedInput({
    value: (values || []).join('\n'), check: checkIpRanges, multiline: true,
    placeholder: 'z. B. 203.0.113.0/24, ein Bereich pro Zeile. IPv4 und IPv6 sind möglich.',
    okText: r => r.value.length ? `${r.value.length} gültige Bereich(e)` : null,
    onValid
  });
  ip.input.classList.add('ip-area');
  const file = h('input', { type: 'file', accept: '.txt,.csv,text/plain,text/csv', class: 'hidden-file', onchange: async e => {
    const f = e.target.files[0];
    if (!f) return;
    if (f.size > 1024 * 1024) { alert('Die Datei ist größer als 1 MB. Eine Named Location fasst höchstens 2000 Bereiche.'); return; }
    // Kopfzeilen wie "IP-Bereich" oder "CIDR" enthalten keine Ziffer und fallen weg
    const text = (await f.text()).split(/\r?\n/).filter(l => /\d/.test(l)).join('\n');
    ip.input.value = [ip.input.value.trim(), text].filter(Boolean).join('\n');
    ip.run();
    e.target.value = '';
  } });
  return h('div', {},
    ip.el,
    h('div', { class: 'actions' },
      h('button', { class: 'ghost small', type: 'button', onclick: () => file.click() }, 'Aus Datei importieren (.txt, .csv)'),
      file),
    help('Welche Adressen gehören hier hin?',
      h('ul', {},
        h('li', {}, 'Nur öffentliche Adressen, also die, unter denen das Netz im Internet auftritt. Private Bereiche wie 10.0.0.0/8 oder 192.168.0.0/16 sieht Entra nie.'),
        h('li', {}, 'CIDR-Schreibweise: Adresse/Präfix, z. B. 203.0.113.0/24. Eine einzelne Adresse ohne Präfix wird als /32 bzw. /128 übernommen.'),
        h('li', {}, 'Entra erlaubt nur Präfixe größer als /8 und höchstens 2000 Bereiche je Location.'),
        h('li', {}, 'Beim Import ist das Format egal: ein Bereich pro Zeile, mit Komma oder Semikolon getrennt, auch die Exportdatei aus dem Entra-Portal geht. Ungültige Zeilen zeigt die Prüfung an.'),
        h('li', {}, 'Denk an IPv6, wenn die Standorte darüber ins Internet gehen. Sonst greift die Location für diese Anmeldungen nicht.'))));
}

function customNlForm() {
  const draft = { persona: 'Global', purpose: '', type: 'ip', name: '' };
  const msgs = h('div', { class: 'msgs' });
  const nameInput = h('input', { type: 'text', spellcheck: 'false', oninput: e => { draft.name = e.target.value; draft.nameTouched = true; } });
  const suggest = () => {
    if (draft.nameTouched) return;
    const purpose = cleanText(draft.purpose).trim().replace(/\s+/g, '_').replace(/[^A-Za-z0-9_]/g, '') || 'Zweck';
    const label = draft.persona === 'Global' ? 'Global' : personaLabel(draft.persona);
    draft.name = `NL-${label}-${purpose}-${draft.type === 'ip' ? 'IP' : 'Country_IP'}`;
    nameInput.value = draft.name;
  };
  suggest();
  const add = () => {
    const r = checkName(nameInput.value, 'Der Name');
    if (!r.errors.length && nlNameTaken(r.value)) r.errors.push(`Eine Named Location „${r.value}“ gibt es schon.`);
    if (!r.errors.length && /-Zweck-/.test(r.value)) r.errors.push('Bitte einen Zweck eintragen, z. B. Partner_VPN.');
    showCheck(msgs, r);
    if (r.errors.length) return;
    saveCustomNls([...customNls(), { name: r.value, persona: draft.persona, type: draft.type, ipRanges: [], countriesAndRegions: [], trusted: false }]);
  };
  return h('div', { class: 'card' },
    h('h2', {}, 'Eigene Named Location hinzufügen'),
    h('p', {}, 'Für Netze oder Länder, die das Framework nicht mitbringt, etwa das VPN eines Dienstleisters. Der Name folgt dem Schema NL-<Persona>-<Zweck>-<Typ>, du kannst ihn aber ändern.'),
    h('div', { class: 'row' },
      field('Persona', h('select', { onchange: e => { draft.persona = e.target.value; suggest(); } },
        h('option', { value: 'Global' }, 'Global (alle)'), S.defs.personas.map(p => h('option', { value: p.key }, p.key)))),
      field('Zweck', textInput('', v => { draft.purpose = v; suggest(); }, 'z. B. Partner_VPN')),
      field('Typ', h('select', { onchange: e => { draft.type = e.target.value; suggest(); } },
        h('option', { value: 'ip' }, 'IP-Bereiche'), h('option', { value: 'country' }, 'Länder')))),
    field('Name', nameInput, 'Wird vorgeschlagen, sobald du Persona, Zweck und Typ wählst.'),
    msgs,
    h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: add }, 'Hinzufügen')));
}

function zscalerCard() {
  const msgs = h('div', { class: 'msgs' });
  let cloud = 'zscaler.net';
  const name = 'NL-Global-ZScaler_Ranges-IP';
  const existing = customNls().find(c => c.source && c.source.vendor === 'zscaler');
  const run = async () => {
    msgs.textContent = '';
    msgs.append(h('div', { class: 'msg info' }, `Rufe die aktuelle Liste für ${cloud} bei Zscaler ab …`));
    let r;
    try { r = await api('GET', `/api/zscaler?cloud=${encodeURIComponent(cloud)}`); }
    catch (e) { r = { ok: false, error: e.message }; }
    msgs.textContent = '';
    if (!r.ok) { msgs.append(h('div', { class: 'msg err' }, `Abruf fehlgeschlagen: ${r.error}. Ohne aktuelle Liste wird nichts importiert.`)); return; }
    const c = checkIpRanges(r.ranges.join('\n'));
    if (c.errors.length) { showCheck(msgs, { errors: ['Die Liste von Zscaler enthält Einträge, die Entra nicht annimmt. Import abgebrochen.', ...c.errors], warnings: [], infos: [] }); return; }
    const entry = { name: existing ? existing.name : name, persona: 'Global', type: 'ip', ipRanges: c.value, trusted: false,
      source: { vendor: 'zscaler', cloud: r.cloud, url: r.url, fetched: r.fetched } };
    if (!existing && nlNameTaken(entry.name)) { msgs.append(h('div', { class: 'msg err' }, `Eine Named Location „${entry.name}“ gibt es schon.`)); return; }
    saveCustomNls(existing ? customNls().map(x => x === existing ? entry : x) : [...customNls(), entry]);
  };
  return h('div', { class: 'card' },
    h('h2', {}, 'IP-Bereiche von Zscaler importieren'),
    h('p', {}, 'Wer über Zscaler ins Internet geht, kommt bei Entra mit einer Adresse von Zscaler an. Damit Regeln für Firmennetze trotzdem greifen, braucht es die Adressen von Zscaler als eigene Named Location.'),
    h('p', { class: 'small muted' }, 'Der Assistent holt die Liste direkt bei Zscaler ab (config.zscaler.com, empfohlene Hub-Bereiche der gewählten Cloud) und prüft sie vor dem Import. Beim Deployment holt der Deployer sie noch einmal ab, damit keine veraltete Liste im Tenant landet. Die Location wird nicht als vertrauenswürdig markiert, weil über Zscaler auch fremde Firmen ins Internet gehen.'),
    h('div', { class: 'row' },
      field('Zscaler-Cloud', h('select', { onchange: e => { cloud = e.target.value; } }, (S.defs.zscalerClouds || ['zscaler.net']).map(c => h('option', { value: c, selected: existing && existing.source.cloud === c }, c))),
        'Steht im Zscaler-Admin-Portal oder in der URL, über die ihr euch dort anmeldet.')),
    msgs,
    h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: run }, existing ? `${existing.name} aktualisieren` : `Als ${name} anlegen`)));
}

// ---------------------------------------------------------------------------
// Authentifizierungsstärken: werden immer ausgerollt, hier nur zur Ansicht
// ---------------------------------------------------------------------------
const METHOD_NAMES = {
  windowsHelloForBusiness: 'Windows Hello for Business',
  fido2: 'Passkey (FIDO2)',
  'x509CertificateMultiFactor': 'Zertifikat (mehrstufig)',
  deviceBasedPush: 'Kennwortlose Anmeldung mit dem Authenticator',
  'password,microsoftAuthenticatorPush': 'Kennwort und Bestätigung im Authenticator',
  temporaryAccessPassMultiUse: 'Temporary Access Pass (mehrfach nutzbar)',
  temporaryAccessPassOneTime: 'Temporary Access Pass (einmalig)'
};
function authStrengthsCard() {
  const list = S.defs.authStrengths || [];
  return h('div', { class: 'card' },
    h('h2', {}, `Die ${list.length} Authentifizierungsstärken`),
    h('p', {}, 'Eine Authentifizierungsstärke legt fest, mit welchen Methoden sich jemand anmelden muss, damit eine Policy zufrieden ist. Diese Stärken gehören fest zum Framework und werden bei jedem Deployment angelegt, weil die CA-Policies auf sie verweisen. Hier gibt es dafür nichts auszuwählen.'),
    h('table', {}, h('tbody', {}, list.map(a => h('tr', {},
      h('td', {}, h('strong', {}, a.name), a.description ? h('div', { class: 'small muted' }, a.description) : null),
      h('td', { class: 'small' }, h('ul', {}, (a.combinations || []).map(c => h('li', {}, METHOD_NAMES[c] || c)))))))));
}

// Basis-Personas und zusätzliche Personas in einer Liste, jeweils mit key, description, parent
function allPersonaEntries() {
  return [...S.defs.personas, ...additionalPersonas().map(x => ({
    key: x.key, parent: x.parent || null, extra: true, roleAssignable: !!x.roleAssignable,
    description: x.description || (x.parent ? `Sub-Persona von ${x.parent}` : 'zusätzliche Persona')
  }))];
}
function roleAssignableOf(p) {
  if (p.extra) return !!p.roleAssignable;
  const o = (cfgGet('personas.roleAssignable', {}) || {})[p.key];
  return o === undefined || o === null ? !!p.roleAssignable : !!o;
}

function roleAssignableCard() {
  const set = (key, v) => {
    const m = { ...(cfgGet('personas.roleAssignable', {}) || {}) };
    const p = S.defs.personas.find(x => x.key === key);
    if (v === !!p.roleAssignable) delete m[key]; else m[key] = v;
    cfgSet('personas.roleAssignable', Object.keys(m).length ? m : undefined);
    render();
  };
  return h('div', { class: 'card' },
    h('h2', {}, 'Role-assignable'),
    h('p', {}, 'Eine role-assignable Gruppe ist besonders geschützt: Ihre Mitglieder kann nur ein Privileged Role Administrator oder Global Administrator ändern. Ein Gruppen- oder Helpdesk-Admin kann das nicht. Die Gruppe bekommt dadurch keine Rolle, das Flag schützt nur die Mitgliedschaft.'),
    h('p', { class: 'small muted' }, 'Wichtig: Das Flag lässt sich nur beim Anlegen setzen und später nicht mehr ändern. Dynamische Gruppen wie Guests können nicht role-assignable sein.'),
    h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Persona'), h('th', {}, 'Empfehlung'), h('th', {}, 'Role-assignable'))),
      h('tbody', {}, S.defs.personas.map(p => {
        const on = roleAssignableOf(p);
        const rec = !!p.roleAssignable;
        return h('tr', {},
          h('td', {}, p.key),
          h('td', { class: 'small' }, rec ? 'ja, die Gruppe schützt privilegierte oder ausgenommene Konten' : (p.dynamic ? 'nicht möglich (dynamische Gruppe)' : 'nein')),
          h('td', {}, checkbox('', on, v => set(p.key, v), null, p.dynamic),
            rec && !on ? h('div', { class: 'msg warn' }, 'Abgewählt: Dann kann auch ein Gruppen-Admin Mitglieder aufnehmen oder entfernen und so Konten an den Policies vorbeischleusen.') : null));
      }))));
}

function additionalPersonasCard() {
  const list = additionalPersonas();
  const baseKeys = S.defs.personas.map(p => p.key);
  const mains = list.filter(x => !x.parent).map(x => x.key);
  const save = l => { cfgSet('personas.additional', l.length ? l : undefined); render(); };
  const msgs = h('div', { class: 'msgs' });
  const draft = { key: '', parent: '', description: '', roleAssignable: false };

  const add = () => {
    const r = { errors: [], warnings: [], infos: [] };
    const key = cleanText(draft.key).trim();
    if (key !== draft.key) r.infos.push('Leerzeichen am Anfang bzw. Ende entfernt.');
    if (!key) r.errors.push('Bitte einen Namen für die Persona eintragen, z. B. VIP.');
    else if (!/^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(key)) r.errors.push('Erlaubt sind Buchstaben ohne Umlaute, Ziffern und _, am Anfang ein Buchstabe, höchstens 40 Zeichen. Leerzeichen und Bindestriche gehen nicht, weil der Name Teil des Gruppennamens wird.');
    else if ([...baseKeys, ...list.map(x => x.key)].some(k => k.toLowerCase() === key.toLowerCase())) r.errors.push(`Eine Persona „${key}“ gibt es schon.`);
    if (draft.parent && !baseKeys.includes(draft.parent) && !mains.includes(draft.parent)) r.errors.push('Die gewählte Hauptpersona gibt es nicht mehr.');
    showCheck(msgs, r);
    if (r.errors.length) return;
    const entry = { key, parent: draft.parent || null, description: cleanText(draft.description).trim() || null, roleAssignable: !!draft.roleAssignable };
    const name = groupNameFromPattern(key, entry.parent);
    if (personaNames().some(n => n.name.toLowerCase() === name.toLowerCase())) { showCheck(msgs, { errors: [`Der Gruppenname „${name}“ wäre doppelt.`], warnings: [], infos: [] }); return; }
    save([...list, entry]);
  };

  const remove = key => {
    const subs = list.filter(x => x.parent === key);
    if (subs.length) { alert(`„${key}“ ist Hauptpersona für ${subs.map(s => s.key).join(', ')}. Erst diese Sub-Personas entfernen oder einer anderen Hauptpersona zuordnen.`); return; }
    const g = { ...(cfgGet('naming.groupNames', {}) || {}) }; delete g[key];
    if (Object.keys(g).length) cfgSet('naming.groupNames', g);
    save(list.filter(x => x.key !== key));
  };
  const setParent = (key, parent) => {
    if (parent && list.some(x => x.parent === key)) { alert(`„${key}“ hat selbst Sub-Personas und kann deshalb keine Sub-Persona werden.`); render(); return; }
    save(list.map(x => x.key === key ? { ...x, parent: parent || null } : x));
  };
  const parentOptions = self => [
    h('option', { value: '' }, 'keine (eigenständige Persona)'),
    h('optgroup', { label: 'Persona-Gruppen des Frameworks' }, baseKeys.map(k => h('option', { value: k }, k))),
    mains.filter(k => k !== self).length ? h('optgroup', { label: 'Zusätzliche Personas' }, mains.filter(k => k !== self).map(k => h('option', { value: k }, k))) : null
  ];
  const parentSelect = (value, onChange, self) => {
    const s = h('select', { onchange: e => onChange(e.target.value) }, parentOptions(self));
    s.value = value || '';
    return s;
  };

  return h('div', { class: 'card' },
    h('h2', {}, 'Zusätzliche Personas'),
    h('p', {}, 'Reichen dir die sieben Personas nicht, leg hier weitere an. Eine Sub-Persona verfeinert eine bestehende Persona, z. B. VIP als Teil von Internals. Jede Sub-Persona gehört zu genau einer Hauptpersona, eine Hauptpersona kann beliebig viele Sub-Personas haben. Sub-Personas von Sub-Personas gibt es nicht.'),
    note('warn', 'Der Deployer legt dafür nur Entra-Sicherheitsgruppen an. Er ordnet sie keiner CA-Policy zu und erzeugt auch keine neuen Policies. Das machst du anschließend selbst, wenn du die Gruppe in Policies nutzen willst.'),
    list.length ? h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Persona'), h('th', {}, 'Gehört zu'), h('th', {}, 'Gruppenname'), h('th', {}, 'Role-assignable'), h('th', {}, ''))),
      h('tbody', {}, list.map(x => h('tr', {},
        h('td', {}, h('strong', {}, x.key), x.description ? h('div', { class: 'small muted' }, x.description) : null),
        h('td', {}, parentSelect(x.parent, v => setParent(x.key, v), x.key)),
        h('td', {}, code(personaNames().find(n => n.persona.key === x.key)?.name || '')),
        h('td', {}, checkbox('', !!x.roleAssignable, v => save(list.map(y => y.key === x.key ? { ...y, roleAssignable: v } : y)))),
        h('td', {}, h('button', { class: 'ghost small', type: 'button', onclick: () => remove(x.key) }, 'Entfernen')))))) : null,
    h('h3', {}, 'Persona hinzufügen'),
    h('div', { class: 'row' },
      field('Name der Persona', textInput('', v => { draft.key = v; }, 'z. B. VIP'), 'Wird im Gruppennamen für {Persona} eingesetzt.'),
      field('Gehört zu (Hauptpersona)', parentSelect('', v => { draft.parent = v; })),
      field('Beschreibung (optional)', textInput('', v => { draft.description = v; }, 'z. B. Geschäftsführung und Assistenz'))),
    checkbox('Role-assignable', false, v => { draft.roleAssignable = v; }, 'Nur wählen, wenn die Mitglieder besonders geschützt sein müssen.'),
    msgs,
    h('div', { class: 'actions' }, h('button', { class: 'secondary', type: 'button', onclick: add }, 'Persona hinzufügen')));
}

function selectedKeys() {
  const include = cfgGet('policies.include', ['*']) || ['*'];
  const exclude = cfgGet('policies.exclude', []) || [];
  const like = (k, pat) => new RegExp('^' + pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$').test(k);
  return S.defs.policies.map(p => p.key).filter(k => include.some(i => like(k, i)) && !exclude.some(e => like(k, e)));
}
function writeSelection(sel) {
  const all = S.defs.policies.every(p => sel.has(p.key));
  cfgSet('policies.include', all ? ['*'] : S.defs.policies.map(p => p.key).filter(k => sel.has(k)));
  cfgSet('policies.exclude', []);
  renderNav();
}

// ---------------------------------------------------------------------------
// Darstellung
// ---------------------------------------------------------------------------
// Ohne bestätigten Haftungsausschluss bleibt nur die Startseite erreichbar
function disclaimerOk() {
  if (S.disclaimer !== undefined) return S.disclaimer;
  // Gilt nur für die laufende Sitzung: Jeder neue Start fragt wieder nach
  try { return sessionStorage.getItem('caDisclaimer') === '1'; } catch { return false; }
}

function renderNav() {
  const nav = document.getElementById('steps');
  nav.textContent = '';
  const locked = !disclaimerOk();
  STEPS.forEach((s, i) => {
    let st = 'open';
    try { st = s.status(); } catch { }
    const sym = st === 'done' ? '✓' : st === 'warn' ? '!' : String(i + 1);
    nav.append(h('button', { type: 'button', class: i === S.step ? 'active' : '', disabled: locked && i > 0, title: locked && i > 0 ? 'Erst den Haftungsausschluss bestätigen' : null, 'aria-current': i === S.step ? 'step' : null, onclick: () => { S.step = i; render(); window.scrollTo(0, 0); } },
      h('span', { class: `dot ${st}` }, sym), s.title));
  });
  document.getElementById('cfg-label').textContent = S.cfgName ? `Tenant: ${cfgGet('tenant.primaryDomain') || S.cfgName}` : 'kein Tenant ausgewählt';
}

function render() {
  if (!disclaimerOk()) S.step = 0;
  renderNav();
  const main = document.getElementById('main');
  main.textContent = '';
  const step = STEPS[S.step];
  main.append(...[step.render()].flat(Infinity).filter(Boolean));
  main.append(h('div', { class: 'nav-actions' },
    h('button', { class: 'secondary', type: 'button', disabled: S.step === 0, onclick: () => { S.step--; render(); window.scrollTo(0, 0); } }, 'Zurück'),
    h('button', { class: 'primary', type: 'button', disabled: S.step === STEPS.length - 1 || !disclaimerOk(), onclick: () => { S.step++; render(); window.scrollTo(0, 0); } }, 'Weiter')));
}

async function refreshState() {
  try { S.state = await api('GET', '/api/state'); } catch { }
}
async function loadDefs() { S.defs = await api('GET', '/api/definitions'); }
async function loadConfig(name) {
  const raw = await api('GET', `/api/config?name=${encodeURIComponent(name)}`);
  S.cfgName = name;
  S.cfg = deepMerge(structuredClone(S.defs.example), typeof raw === 'string' ? JSON.parse(raw) : raw);
  S.check = null; S.validated = false; S.whatIf = false; S.bgMode = undefined; S.lookup = null; S.namingMode = undefined;
  localStorage.setItem('caLastConfig', name);
  setSaveState('');
}

async function init() {
  document.getElementById('btn-quit').onclick = async () => {
    if (!confirm('Oberfläche beenden? Laufende Aufträge werden abgebrochen.')) return;
    try { await api('POST', '/api/shutdown'); } catch { }
    document.body.textContent = 'Die Oberfläche ist beendet. Dieses Fenster kann geschlossen werden.';
  };
  if (!TOKEN) {
    document.getElementById('main').append(note('err', 'Kein Zugangsschlüssel. Bitte die Adresse aus dem Konsolenfenster verwenden.'));
    return;
  }
  document.getElementById('main').append(h('p', { class: 'muted' }, 'Vorlagen werden geladen …'));
  try {
    await Promise.all([refreshState(), loadDefs()]);
    const last = localStorage.getItem('caLastConfig');
    if (last && S.state.configs.some(c => c.name === last)) await loadConfig(last);
  } catch (e) {
    document.getElementById('main').append(note('err', 'Verbindung zum Server fehlgeschlagen: ' + e.message));
    return;
  }
  render();
}
init();
