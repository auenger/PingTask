"""Offline adapter checks: no WorkBuddy account, network service or chat data."""
import base64
import contextlib
import http.client
import io
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Sources/PingTask/Resources/WorkBuddy'))
import driver

class FakeClient:
    calls = []
    def __init__(self): self.sock = self
    def settimeout(self, value): pass
    def close(self): pass
    def call(self, method, params, mode=None):
        self.calls.append((method, params))
        return {'status':200, 'body_b64':base64.b64encode(b'fixture').decode()}

class BridgeTests(unittest.TestCase):
    def test_relay_authorization_and_path(self):
        server = driver.Server(('127.0.0.1', 0), driver.Relay)
        server.token = 'synthetic-token'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.object(driver, 'Client', FakeClient):
                FakeClient.calls = []
                for path, token, expected in [('/v2/chat/completions','wrong',403),('/v1/traces',server.token,404),('/v2/chat/completions',server.token,200)]:
                    conn = http.client.HTTPConnection(*server.server_address)
                    conn.request('POST', path, json.dumps({'model':'fixture','messages':[], 'secret_extra':'discard'}), {'X-PingTask-Relay':token})
                    response = conn.getresponse()
                    self.assertEqual(response.status, expected)
                    response.read(); conn.close()
                self.assertEqual(len(FakeClient.calls), 2)
                forwarded = json.loads(base64.b64decode(FakeClient.calls[-1][1]['body_b64']))
                self.assertNotIn('secret_extra', forwarded)
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_result_and_permissions(self):
        class Input(io.BytesIO):
            def close(self): pass
        class Process:
            pid = 99999999
            def __init__(self, result):
                self.stdin = Input()
                self.stdout = io.BytesIO(json.dumps(result).encode())
            def wait(self, timeout=None): return 0
            def poll(self): return 0
        submission = {'workBuddy':{'appPath':'/fixture/WorkBuddy.app','model':'hy3','allowEdits':False},'taskID':'A-FIXTURE','settings':{'workspace':'/tmp'},'prompt':'synthetic fixture'}
        for denied, expected in [(False,0),(True,1)]:
            result = {'type':'result','subtype':'success','result':'fixture result','permission_denials':['Write'] if denied else []}
            output = io.StringIO()
            with patch.object(driver,'product_config',return_value={}), patch.object(driver,'Client',FakeClient), patch.object(driver.subprocess,'Popen',return_value=Process(result)) as launch, contextlib.redirect_stdout(output):
                self.assertEqual(driver.run(submission), expected)
            args = launch.call_args.args[0]
            self.assertEqual(args[args.index('--tools')+1], 'Read,Glob,Grep')
            self.assertIn('--strict-mcp-config',args)
            self.assertNotIn('Bash',args)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[-1]['type'], 'turn.failed' if denied else 'turn.completed')
            self.assertEqual(events[0]['thread_id'],'a-fixture')

if __name__ == '__main__': unittest.main()
