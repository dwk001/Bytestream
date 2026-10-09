// ByteStream audio helper page.
//
// ByteStream (the native app) starts Microsoft Edge in app mode pointing at this page.  The page hosts Spotify's
// official Web Playback SDK, which makes this browser a Spotify Connect device called "ByteStream" and plays the
// audio.  Everything else happens in the native app; this page only relays:
//   page -> app   POST /bridge/event   ready, not_ready, state, error
//   app  -> page  GET  /bridge/cmds    server-sent events: toggle, pause, resume, seek, volume, next, prev, ...
//   page <- app   GET  /bridge/token   the current access token (for the SDK's getOAuthToken callback)
// Every bridge call carries the per-run secret ?k= from this page's own URL.
(() => {
  'use strict';

  const K = new URLSearchParams(location.search).get('k') || '';
  const url = (path) => path + (path.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(K);
  const statusEl = document.getElementById('status');
  const setStatus = (t) => { if (statusEl) statusEl.textContent = t; };

  let player = null;
  let deviceId = null;
  let initialVolume = 0.7;

  function post(msg) {
    return fetch(url('/bridge/event'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(msg),
      cache: 'no-store',
    }).catch(() => {});
  }

  async function fetchToken() {
    const r = await fetch(url('/bridge/token'), { cache: 'no-store' });
    if (!r.ok) throw new Error('token endpoint answered ' + r.status);
    return (await r.json()).token;
  }

  // The SDK's view of "what is playing", reduced to what the app needs.
  function stateMessage(s) {
    if (!s) return { type: 'state', empty: true };
    const t = (s.track_window && s.track_window.current_track) || {};
    const album = t.album || {};
    return {
      type: 'state',
      paused: !!s.paused,
      position: s.position | 0,
      duration: s.duration | 0,
      shuffle: !!s.shuffle,
      repeat: s.repeat_mode | 0,
      track: {
        uri: t.uri || '',
        name: t.name || '',
        artists: (t.artists || []).map((a) => a.name),
        album: album.name || '',
        images: (album.images || []).map((i) => i.url),
      },
    };
  }

  function onCommand(c) {
    if (!player) return;
    switch (c.cmd) {
      case 'toggle': player.togglePlay(); break;
      case 'pause': player.pause(); break;
      case 'resume': player.resume(); break;
      case 'seek': player.seek(c.ms | 0); break;
      case 'volume': player.setVolume(Math.max(0, Math.min(100, +c.pct || 0)) / 100); break;
      case 'next': player.nextTrack(); break;
      case 'prev': player.previousTrack(); break;
      case 'activate': player.activateElement(); break;
      case 'state': player.getCurrentState().then((s) => post(stateMessage(s))); break;
      default: break;
    }
  }

  function connectCommands() {
    const es = new EventSource(url('/bridge/cmds'));
    es.onmessage = (e) => { try { onCommand(JSON.parse(e.data)); } catch (_) { /* ignore garbage */ } };
    // EventSource reconnects by itself when the app restarts the stream.
  }

  window.onSpotifyWebPlaybackSDKReady = () => {
    player = new Spotify.Player({
      name: 'ByteStream',
      getOAuthToken: (cb) => fetchToken().then(cb).catch((e) => post({ type: 'error', kind: 'token', message: String(e) })),
      volume: initialVolume,
      enableMediaSession: true,           // media keys and the Windows overlay show the track
    });
    player.addListener('ready', (d) => { deviceId = d.device_id; setStatus('Ready. You can minimise this window.'); post({ type: 'ready', device_id: d.device_id }); });
    player.addListener('not_ready', (d) => post({ type: 'not_ready', device_id: d.device_id }));
    player.addListener('player_state_changed', (s) => post(stateMessage(s)));
    ['initialization_error', 'authentication_error', 'account_error', 'playback_error'].forEach((kind) =>
      player.addListener(kind, (e) => post({ type: 'error', kind, message: (e && e.message) || '' })));
    player.addListener('autoplay_failed', () => post({ type: 'error', kind: 'autoplay_failed', message: '' }));
    player.connect().then((ok) => { if (!ok) post({ type: 'error', kind: 'connect_failed', message: 'the SDK could not connect' }); });
  };

  // While something plays the SDK only reports changes, so resync the position now and then.
  setInterval(() => {
    if (player) player.getCurrentState().then((s) => { if (s && !s.paused) post(stateMessage(s)); }).catch(() => {});
  }, 5000);

  connectCommands();
  const sdk = document.createElement('script');
  sdk.src = 'https://sdk.scdn.co/spotify-player.js';
  sdk.async = true;
  sdk.onerror = () => post({ type: 'error', kind: 'sdk_load_failed', message: 'could not load the Spotify Web Playback SDK (offline?)' });
  document.head.appendChild(sdk);
  post({ type: 'hello' });
})();
