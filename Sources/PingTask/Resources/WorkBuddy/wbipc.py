import base64
import hashlib
import hmac
import json
import secrets
import socket
import struct
from pathlib import Path


class Client:
    def __init__(self):
        discovery = json.loads((Path.home() / '.workbuddy/wbipc/endpoint.json').read_text())
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(15)
        self.sock.connect(discovery['endpoint'])
        self.stream = self.sock.makefile('rwb', buffering=0)
        nonce = secrets.token_urlsafe(16)
        ticket = discovery['ticket']
        self.send({'type': 'session_hello', 'protocol_min': 1, 'protocol_max': 1,
                   'client_nonce': nonce, 'ticket_id': hashlib.sha256(ticket.encode()).hexdigest()[:16],
                   'client': {'kind': 'cli', 'id': 'pingtask', 'version': '0.1'}})
        challenge = self.receive()
        if challenge.get('type') != 'session_challenge':
            raise RuntimeError('Handshake rejected: ' + str(challenge.get('code')))
        def proof(side):
            parts = ['wbipc-' + side, '1', discovery['endpoint'], nonce, challenge['server_nonce']]
            data = b''.join(struct.pack('>I', len(p.encode())) + p.encode() for p in parts)
            return base64.urlsafe_b64encode(hmac.new(ticket.encode(), data, hashlib.sha256).digest()).decode().rstrip('=')
        if not hmac.compare_digest(proof('s'), challenge['server_proof']):
            raise RuntimeError('Server authentication failed')
        self.send({'type': 'session_prove', 'client_proof': proof('c')})
        self.hello = self.receive()
        if self.hello.get('type') != 'session_hello_ack':
            raise RuntimeError('Handshake did not complete')
        self.counter = 0

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + '\n').encode())

    def receive(self):
        line = self.stream.readline(2 * 1024 * 1024 + 1)
        if len(line) > 2 * 1024 * 1024:
            raise RuntimeError("IPC frame too large")
        if not line:
            raise RuntimeError('Connection closed')
        return json.loads(line)

    def call(self, method, params=None, mode=None):
        self.counter += 1
        req = {'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params or {}}
        if mode:
            req['mode'] = mode
        self.send(req)
        while True:
            reply = self.receive()
            if reply.get('id') == self.counter:
                if 'error' in reply:
                    raise RuntimeError(str(reply['error']))
                return reply.get('result')

    def close(self):
        self.stream.close()
        self.sock.close()
