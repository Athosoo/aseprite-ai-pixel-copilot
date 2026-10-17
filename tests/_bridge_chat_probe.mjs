import WebSocket from 'ws';
const url = 'ws://127.0.0.1:8777';
const ws = new WebSocket(url);
let said = 0;
const timer = setTimeout(() => { console.log('TIMEOUT after 45s, replies=' + said); process.exit(1); }, 45000);
ws.on('open', () => {
  console.log('OPEN');
  ws.send(JSON.stringify({ type: 'hello', aseprite: 'probe', apiVersion: 1, ops: [], opsHelp: {} }));
  setTimeout(() => {
    console.log('SEND chat');
    ws.send(JSON.stringify({ type: 'chat', text: 'say OK in three words' }));
  }, 800);
});
ws.on('message', (buf) => {
  let m;
  try { m = JSON.parse(buf.toString()); } catch { return; }
  const t = m.type || m.kind || '?';
  const text = (m.text || m.content || '').toString().slice(0, 160);
  console.log('FRAME', t, '|', text);
  if (t === 'say' || t === 'chunk' || t === 'done' || t === 'error' || t === 'tool') said++;
  if (t === 'error' || (typeof text === 'string' && /error/i.test(t))) { console.log('ERROR FRAME SEEN'); }
  if (m.type === 'turn_end' || m.type === 'done') { clearTimeout(timer); console.log('TURN DONE after ' + said + ' frames'); ws.close(); process.exit(0); }
});
ws.on('error', (e) => { console.log('WS ERROR', e.message); process.exit(1); });
ws.on('close', () => console.log('CLOSE'));
