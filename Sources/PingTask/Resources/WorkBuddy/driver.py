"""PingTask local WorkBuddy CLI adapter. No account credentials are logged or persisted."""
import base64, http.server, json, os, re, secrets, signal, subprocess, sys, threading, urllib.parse, zlib
from pathlib import Path
# Keep the signed application resource directory immutable when importing the helper.
sys.dont_write_bytecode = True
from wbipc import Client

LIMIT = 8 * 1024 * 1024

def emit(kind, **fields):
    print(json.dumps(dict(type=kind, **fields), ensure_ascii=False), flush=True)

class DriverFailure(Exception):
    pass

def check(app):
    product_config(app)
    if not (Path.home()/'.workbuddy/wbipc/endpoint.json').is_file():
        raise DriverFailure('WorkBuddy IPC 尚未就绪，请打开并登录桌面端，等待启动完成后重试。')
    client = Client()
    try:
        client.call('broker/GetPipe', {'pipe':'wb.request'})
    finally:
        client.close()

def product_config(app):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True, timeout=10).splitlines()
    pid = next((row.strip().split(None, 1)[0] for row in rows if app + '/' in row and '--stdio' in row and 'daemon-app-server-entry.js' in row), None)
    if pid is None: raise DriverFailure('WorkBuddy 尚未启动完成，请打开并登录桌面端后重试。')
    raw = subprocess.check_output(['/bin/ps', 'eww', '-p', pid, '-o', 'command='], text=True, timeout=10)
    parts = list(re.finditer(r'(?:^| )([A-Za-z_][A-Za-z0-9_]*)=', raw))
    env = {m.group(1): raw[m.end():(parts[i+1].start() if i+1 < len(parts) else len(raw))].rstrip('\n') for i,m in enumerate(parts)}
    return json.loads(Path(env['ACC_PRODUCT_CONFIG_PATH']).read_text())

class Relay(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        client = None
        try:
            self.connection.settimeout(65)
            url = urllib.parse.urlsplit(self.path)
            supplied = self.headers.get('X-PingTask-Relay', '')
            authorization = self.headers.get('Authorization', '').removeprefix('Bearer ')
            if not (secrets.compare_digest(supplied, self.server.token) or secrets.compare_digest(authorization, self.server.token)):
                self.send_error(403); return
            # Only model completion calls may reach the desktop broker. No telemetry or arbitrary proxy.
            if url.path not in ['/v2/chat/completions', '/v1/chat/completions'] or url.query:
                self.send_error(404); return
            body = bytearray()
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                while True:
                    line = self.rfile.readline(256)
                    count = int(line.split(b';',1)[0],16)
                    if count == 0: break
                    if count < 0 or len(body)+count > LIMIT: raise ValueError('limit')
                    body.extend(self.rfile.read(count))
                    if self.rfile.read(2) != b'\r\n': raise ValueError('chunk')
            else:
                count = int(self.headers.get('Content-Length','0'))
                if count < 0 or count > LIMIT: raise ValueError('limit')
                body.extend(self.rfile.read(count))
            encoding = self.headers.get('Content-Encoding','').lower()
            if encoding in ['gzip','deflate'] or body[:2] == b'\x1f\x8b':
                decoder = zlib.decompressobj(31 if encoding == 'gzip' or body[:2] == b'\x1f\x8b' else 15)
                body = decoder.decompress(bytes(body), LIMIT+1)
                if len(body)>LIMIT or not decoder.eof: raise ValueError('limit')
            request = json.loads(body)
            keys = ['model','messages','stream','max_tokens','reasoning_effort','temperature','top_p','tools','tool_choice','parallel_tool_calls']
            body = json.dumps({k:request[k] for k in keys if k in request}).encode()
            client = Client(); client.sock.settimeout(60)
            client.call('broker/GetPipe', {'pipe':'wb.request'})
            reply = client.call('c:wb.request/http.fetch', {'method':'POST','path':'/v2/chat/completions','query':{},
                'headers':{'content-type':'application/json','accept':'text/event-stream'},'body_b64':base64.b64encode(body).decode()}, 'call')
            data = base64.b64decode(reply.get('body_b64',''), validate=True)
            if len(data)>LIMIT: raise ValueError('limit')
            self.send_response(int(reply['status']))
            self.send_header('Content-Type',reply.get('headers',{}).get('content-type','text/event-stream'))
            self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        except Exception:
            try: self.send_error(502,'WorkBuddy relay failed')
            except Exception: pass
        finally:
            if client: client.close()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 4
    def __init__(self, *args):
        self.slots = threading.BoundedSemaphore(4)
        super().__init__(*args)
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try: super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try: super().process_request_thread(request, client_address)
        finally: self.slots.release()

def run(submission, submission_directory=None):
    settings = submission['workBuddy']; app = settings['appPath']
    config = product_config(app)
    c = Client(); c.call('broker/GetPipe', {'pipe':'wb.request'}); c.close()
    server = Server(('127.0.0.1',0),Relay); server.token = secrets.token_urlsafe(32)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    config['endpoint'] = 'http://127.0.0.1:'+str(server.server_address[1])
    config['authentication'] = {'id':'pingtask-relay','type':'custom-token','attributes':{'token':server.token}}
    env = {k:v for k,v in os.environ.items() if not k.startswith(('ACC_PRODUCT_CONFIG','CODEBUDDY_SIDECAR_')) and k != 'WORKBUDDY_AT_REST_ENCRYPTION'}
    env.update(ELECTRON_RUN_AS_NODE='1', CODEBUDDY_FORCE_LITE_WB_BUNDLE='1', CODEBUDDY_CONFIG_DIR=str(Path.home()/'.workbuddy'),
        WORKBUDDY_CONFIG_DIR=str(Path.home()/'.workbuddy'), CODEBUDDY_CREDENTIALS_IN_MEMORY='1', CODEBUDDY_DISABLE_IDE='1',
        CODEBUDDY_DISABLE_PRODUCT_CACHE='1', CODEBUDDY_DISABLE_SHELL_SNAPSHOT='1', CODEBUDDY_REMOTE_CONFIG_DISABLED='1',
        CODEBUDDY_MAX_RETRIES='0', CODEBUDDY_FIRST_TOKEN_TIMEOUT_MS='55000', DISABLE_TELEMETRY='1',
        ACC_PRODUCT_CONFIG_V3=json.dumps(config,separators=(',',':')))
    tools = ['Read','Glob','Grep'] + (['Write','Edit'] if settings['allowEdits'] else [])
    session = submission['taskID'].lower()
    args = [app+'/Contents/MacOS/Electron', app+'/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy',
        '-p','--model',settings['model'],'--effort','low','--tools',','.join(tools),'--allowedTools',*tools,
        '--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','',
        '--session-id',session,'--output-format','json','--max-turns','12','--permission-mode','dontAsk',
        '--header','X-PingTask-Relay: '+server.token]
    process = None
    if submission_directory is not None:
        attachments = Path(submission_directory) / 'attachments'
        if attachments.is_dir(): args += ['--add-dir', str(attachments)]
    try:
        process = subprocess.Popen(args,cwd=submission['settings']['workspace'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        emit('thread.started',thread_id=session)
        prompt = submission['prompt']+'\n仅处理上述需求、来源文字、OCR 与用户明确选择的附件。请读取附件清单中的文件；未通过视觉参数传入图片，工具无法识别图片时必须说明。工作目录：'+submission['settings']['workspace']
        process.stdin.write(prompt.encode());process.stdin.close()
        output = bytearray(); overflow = threading.Event()
        def read():
            while True:
                chunk = process.stdout.read(65536)
                if not chunk: break
                if len(output)+len(chunk)>LIMIT:
                    overflow.set(); os.killpg(process.pid,signal.SIGKILL); break
                output.extend(chunk)
        thread = threading.Thread(target=read,daemon=True);thread.start()
        try: code = process.wait(timeout=900)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.wait(); raise RuntimeError('timeout')
        thread.join(timeout=5)
        if overflow.is_set() or thread.is_alive(): raise RuntimeError('output limit')
        try: events = json.loads(output)
        except ValueError: events = [json.loads(line) for line in output.splitlines() if line.strip()]
        if not isinstance(events,list): events = [events]
        result = next((x for x in reversed(events) if isinstance(x,dict) and x.get('type')=='result'),None)
        if not result: raise RuntimeError('missing result')
        text = result.get('result','')
        if isinstance(text,str) and text: emit('item.completed',item={'type':'agent_message','text':text[-32000:]})
        success = code == 0 and result.get('subtype')=='success' and not result.get('is_error') and not result.get('permission_denials')
        if success: emit('turn.completed'); return 0
        emit('turn.failed',error={'message':'WorkBuddy 未完成，可能存在权限拒绝或轮次限制；请核对结果。'});return 1
    finally:
        if process and process.poll() is None:
            os.killpg(process.pid,signal.SIGKILL);process.wait()
        server.shutdown();server.server_close()

if __name__=='__main__':
    try:
        if sys.argv[1]=='--check':
            try:
                check(sys.argv[2])
                print(json.dumps({'ok':True,'message':'WorkBuddy CLI + IPC 可用（未发送模型请求）'},ensure_ascii=False))
            except Exception as error:
                print(json.dumps({'ok':False,'message':str(error) if isinstance(error,DriverFailure) else 'WorkBuddy IPC 连接失败，请核对桌面登录与版本兼容性。'},ensure_ascii=False))
            sys.exit(0)
        sys.exit(run(json.loads(Path(sys.argv[1]).read_text()), Path(sys.argv[1]).resolve().parent))
    except Exception:
        emit('turn.failed',error={'message':'WorkBuddy 驱动失败或超时，请检查桌面登录、版本兼容性与工作目录。'})
        sys.exit(1)
