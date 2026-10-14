import { WebSocketServer } from 'ws';
const wss = new WebSocketServer({ port: 8799 });
wss.on('connection', (ws) => {
  console.log('client connected');
  ws.on('message', (d, isBin) => { console.log('recv', isBin ? 'bin' : 'text', d.toString().slice(0, 60)); ws.send(isBin ? d : 'ECHO:' + d.toString()); });
});
console.log('echo server on 8799');
