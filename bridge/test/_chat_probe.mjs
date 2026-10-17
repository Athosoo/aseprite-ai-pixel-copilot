import WebSocket from 'ws';
const ws = new WebSocket('ws://127.0.0.1:8777');
const timer = setTimeout(() => { console.log('TIMEOUT 45s'); process.exit(1); }, 45000);
ws.on('open', () => {
  console.log('OPEN');
  ws.send(JSON.stringify({ type: 'hello', aseprite: 'probe', apiVersion: 1, ops: [], opsHelp: {} }));
  setTimeout(() => { console.log('SEND chat'); ws.send(JSON.stringify({ type: 'chat', text: 'say OK in three words' })); }, 800);
});
ws.on('message', (buf) => {
  let m; try { m = JSON.parse(buf.toString()); } catch { return; }
  const t = String(m.type || m.kind || '?');
  const text = String(m.text || m.content || '').slice(0, 140);
  console.log('FRAME', t, '|', text);
  if (t === 'done' || t === 'turn_end') { clearTimeout(timer); console.log('TURN DONE'); process.exit(0); }
});
ws.on('error', (e) => { console.log('WS ERROR', e.message); process.exit(1); });
ws.on('close', () => console.log('CLOSE'));
