// Tests web/player.js in headless Chromium against a mocked Spotify Web Playback SDK and a mocked app bridge.
// Prints "ok <name>" / "FAIL <name>: <detail>" per check; exit code 1 when anything failed.
//   node tests/player_page.js
const http = require('http');
const fs = require('fs');
const path = require('path');

let pw;
for (const p of [process.env.PLAYWRIGHT_PATH, 'playwright', '/opt/node22/lib/node_modules/playwright']) {
  if (!p) continue;
  try { pw = require(p); break; } catch (_) { /* try the next one */ }
}
if (!pw) { console.log('SKIP playwright is not installed'); process.exit(0); }

const WEB = path.join(__dirname, '..', 'web');
const SECRET = 'testsecret0123456789abcd';
let failed = 0;
const check = (cond, name, detail) => {
  if (cond) console.log('ok ' + name);
  else { failed++; console.log('FAIL ' + name + (detail !== undefined ? ': ' + JSON.stringify(detail) : '')); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await fn()) return true; await sleep(25); }
  return false;
}

// ---- the app's side of the bridge
const events = [];
const urls = [];
let sse = null;
const server = http.createServer((req, res) => {
  urls.push(req.url);
  const u = new URL(req.url, 'http://127.0.0.1');
  if (u.pathname === '/player') { res.setHeader('Content-Type', 'text/html'); return res.end(fs.readFileSync(path.join(WEB, 'player.html'))); }
  if (u.pathname === '/player.js') { res.setHeader('Content-Type', 'text/javascript'); return res.end(fs.readFileSync(path.join(WEB, 'player.js'))); }
  if (u.searchParams.get('k') !== SECRET) { res.statusCode = 403; return res.end(); }
  if (u.pathname === '/bridge/token') { res.setHeader('Content-Type', 'application/json'); return res.end('{"token":"TOKEN-1"}'); }
  if (u.pathname === '/bridge/event' && req.method === 'POST') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => { try { events.push(JSON.parse(b)); } catch (_) { events.push({ bad: b }); } res.statusCode = 204; res.end(); });
    return;
  }
  if (u.pathname === '/bridge/cmds') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
    res.write(': connected\n\n');
    sse = res;
    return;
  }
  res.statusCode = 404; res.end();
});

// A minimal stand-in for https://sdk.scdn.co/spotify-player.js
const MOCK_SDK = `
  window.__calls = [];
  window.Spotify = { Player: class {
    constructor(o) { this.o = o; this.l = {}; window.__player = this; window.__opts = { name: o.name, volume: o.volume, media: o.enableMediaSession }; }
    addListener(n, f) { (this.l[n] = this.l[n] || []).push(f); return true; }
    emit(n, d) { (this.l[n] || []).forEach((f) => f(d)); }
    connect() { this.o.getOAuthToken((t) => { window.__token = t; }); setTimeout(() => this.emit('ready', { device_id: 'MOCK-DEV' }), 20); return Promise.resolve(true); }
    togglePlay() { window.__calls.push(['toggle']); return Promise.resolve(); }
    pause() { window.__calls.push(['pause']); return Promise.resolve(); }
    resume() { window.__calls.push(['resume']); return Promise.resolve(); }
    seek(ms) { window.__calls.push(['seek', ms]); return Promise.resolve(); }
    setVolume(v) { window.__calls.push(['volume', v]); return Promise.resolve(); }
    nextTrack() { window.__calls.push(['next']); return Promise.resolve(); }
    previousTrack() { window.__calls.push(['prev']); return Promise.resolve(); }
    activateElement() { window.__calls.push(['activate']); return Promise.resolve(); }
    getCurrentState() { return Promise.resolve(window.__state || null); }
  } };
  setTimeout(() => window.onSpotifyWebPlaybackSDKReady && window.onSpotifyWebPlaybackSDKReady(), 0);
`;

(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const exe = process.env.CHROME_PATH || (fs.existsSync('/opt/pw-browsers/chromium-1194/chrome-linux/chrome') ? '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' : undefined);
  const browser = await pw.chromium.launch({ executablePath: exe, channel: process.env.PW_CHANNEL || undefined, args: ['--no-sandbox'] });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.route('https://sdk.scdn.co/spotify-player.js', (route) => route.fulfill({ contentType: 'text/javascript', body: MOCK_SDK }));
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));

  await page.goto(`http://127.0.0.1:${port}/player?k=${SECRET}`);
  check(await until(() => events.some((e) => e.type === 'ready')), 'page: reports ready when the SDK connects', events);
  const ready = events.find((e) => e.type === 'ready') || {};
  check(events[0] && events[0].type === 'hello', 'page: says hello first', events[0]);
  check(ready.device_id === 'MOCK-DEV', 'page: ready carries the device id', ready);
  check(await page.evaluate(() => window.__token) === 'TOKEN-1', 'page: the SDK gets its token from /bridge/token');
  const opts = await page.evaluate(() => window.__opts);
  check(opts.name === 'ByteStream' && opts.media === true && opts.volume > 0 && opts.volume <= 1, 'page: the player is named ByteStream and uses the media session', opts);
  check(urls.filter((u) => u.startsWith('/bridge/')).every((u) => u.includes('k=' + SECRET)), 'page: every bridge call carries the secret', urls);
  check(await until(() => sse !== null), 'page: opens the command stream');

  // state mapping
  await page.evaluate(() => window.__player.emit('player_state_changed', {
    paused: false, position: 4321.7, duration: 200000, shuffle: true, repeat_mode: 2,
    track_window: { current_track: { uri: 'spotify:track:abc', name: 'Song', artists: [{ name: 'A' }, { name: 'B' }],
      album: { name: 'Album', images: [{ url: 'https://i/large' }, { url: 'https://i/small' }] } } },
  }));
  check(await until(() => events.some((e) => e.type === 'state' && !e.empty)), 'page: forwards player_state_changed');
  const st = events.filter((e) => e.type === 'state' && !e.empty).pop() || {};
  check(st.paused === false && st.position === 4321 && st.duration === 200000 && st.shuffle === true && st.repeat === 2, 'page: state numbers and flags are mapped', st);
  check(st.track && st.track.uri === 'spotify:track:abc' && st.track.name === 'Song' && st.track.album === 'Album'
    && JSON.stringify(st.track.artists) === '["A","B"]' && JSON.stringify(st.track.images) === '["https://i/large","https://i/small"]',
    'page: the track is reduced to uri, name, artists, album and image urls', st);
  await page.evaluate(() => window.__player.emit('player_state_changed', null));
  check(await until(() => events.some((e) => e.type === 'state' && e.empty === true)), 'page: a null state becomes {empty:true}');

  // commands from the app
  const send = (o) => sse.write('data: ' + JSON.stringify(o) + '\n\n');
  send({ cmd: 'toggle' }); send({ cmd: 'seek', ms: 90000 }); send({ cmd: 'volume', pct: 50 }); send({ cmd: 'volume', pct: 250 });
  send({ cmd: 'next' }); send({ cmd: 'prev' }); send({ cmd: 'pause' }); send({ cmd: 'resume' }); send({ cmd: 'bogus' });
  check(await until(async () => (await page.evaluate(() => window.__calls.length)) >= 8), 'page: executes the commands it is sent');
  const calls = await page.evaluate(() => window.__calls);
  check(JSON.stringify(calls) === JSON.stringify([['toggle'], ['seek', 90000], ['volume', 0.5], ['volume', 1], ['next'], ['prev'], ['pause'], ['resume']]),
    'page: toggle, seek, volume (percent to 0..1, clamped), next, prev, pause, resume map to SDK calls', calls);
  await page.evaluate(() => { window.__state = { paused: false, position: 777, duration: 1000, track_window: { current_track: { uri: 'u', name: 'n', artists: [], album: { images: [] } } } }; });
  const before = events.length;
  send({ cmd: 'state' });
  check(await until(() => events.length > before && events[events.length - 1].position === 777), 'page: a state command answers with the current state');
  send('not an object'); send({});
  await sleep(100);

  // errors
  await page.evaluate(() => { window.__player.emit('account_error', { message: 'premium' }); window.__player.emit('authentication_error', { message: 'x' });
    window.__player.emit('initialization_error', { message: 'drm' }); window.__player.emit('playback_error', { message: 'p' }); window.__player.emit('autoplay_failed'); });
  check(await until(() => ['account_error', 'authentication_error', 'initialization_error', 'playback_error', 'autoplay_failed']
    .every((k) => events.some((e) => e.type === 'error' && e.kind === k))), 'page: every SDK error kind is reported', events.filter((e) => e.type === 'error'));
  await page.evaluate(() => window.__player.emit('not_ready', { device_id: 'MOCK-DEV' }));
  check(await until(() => events.some((e) => e.type === 'not_ready')), 'page: not_ready is forwarded');
  check(errors.length === 0, 'page: no uncaught JavaScript errors', errors);

  // the SDK script cannot be loaded (offline)
  const before2 = events.length;
  const page2 = await ctx.newPage();
  await page2.route('https://sdk.scdn.co/spotify-player.js', (route) => route.abort());
  await page2.goto(`http://127.0.0.1:${port}/player?k=${SECRET}`);
  check(await until(() => events.slice(before2).some((e) => e.type === 'error' && e.kind === 'sdk_load_failed')), 'page: reports sdk_load_failed when the SDK cannot be fetched');

  await browser.close();
  server.close();
  console.log(failed ? `${failed} failed` : 'all passed');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log('FAIL harness: ' + e); process.exit(1); });
