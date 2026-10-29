# pfSense simulado para os testes: mesmo fluxo da WebGUI que o Backup-pfSense.ps1 usa
# (login com CSRF, privilegios, download do config.xml, criptografia e logout).
# Uso: python3 mock_pfsense.py <senha> <senha_cripto> <porta> <cert.pem> <key.pem>
import http.server, ssl, urllib.parse, uuid, sys, json
SENHA, ENC, PORTA, CERT, CHAVE = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
sess = {}; stats = {"logins_ok":0,"logins_falhos":0,"logouts":0,"downloads":0}
CONFIG = '<?xml version="1.0"?>\n<pfsense>\n<version>23.3</version>\n' + ''.join(f'<item n="{i}">x</item>\n' for i in range(150)) + '</pfsense>\n'
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def sid(self):
        for c in (self.headers.get('Cookie') or '').split(';'):
            k,_,v = c.strip().partition('=')
            if k=='PHPSESSID': return v
    def body(self):
        n=int(self.headers.get('Content-Length') or 0)
        return urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8'), keep_blank_values=True)
    def send(self, code, txt, ctype='text/html', extra=None):
        b=txt.encode(); self.send_response(code)
        self.send_header('Content-Type',ctype); self.send_header('Content-Length',str(len(b)))
        for k,v in (extra or {}).items(): self.send_header(k,v)
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=urllib.parse.urlparse(self.path).path; s=self.sid()
        if p=='/stats': return self.send(200, json.dumps(stats), 'application/json')
        if p=='/index.php':
            nid=s or uuid.uuid4().hex; sess.setdefault(nid,{"logged":False})
            return self.send(200, '<form><input type=\'hidden\' name=\'__csrf_magic\' value="sid:login1,1" /><input id="usernamefld"/></form>', extra={'Set-Cookie':f'PHPSESSID={nid}; path=/'})
        logged = s in sess and sess[s]["logged"]
        if p=='/diag_backup.php':
            if not logged: return self.send(200, '<input id="usernamefld"/> Enter username and password')
            return self.send(200, '<form><input type="hidden" name="__csrf_magic" value="sid:backup2,2" /></form>')
        if p in ('/system_usermanager.php','/firewall_rules.php','/diag_command.php'):
            return self.send(302, '', extra={'Location':'/diag_backup.php'})
        self.send(404,'nao existe')
    def do_POST(self):
        u=urllib.parse.urlparse(self.path); p=u.path; s=self.sid(); f=self.body()
        g=lambda k: f.get(k,[''])[0]
        if p=='/index.php' and 'logout' in u.query:
            if s in sess and g('__csrf_magic')=='sid:backup2,2': sess[s]["logged"]=False; stats["logouts"]+=1
            return self.send(302,'',extra={'Location':'/'})
        if p=='/index.php':
            if g('__csrf_magic')=='sid:login1,1' and g('usernamefld')=='srvbackup-pfsense' and g('passwordfld')==SENHA:
                sess[s]["logged"]=True; stats["logins_ok"]+=1
            else: stats["logins_falhos"]+=1; stats["ultima_senha_recebida"]=g('passwordfld')
            return self.send(302,'',extra={'Location':'/'})
        if p=='/diag_backup.php':
            if not (s in sess and sess[s]["logged"]) or g('__csrf_magic')!='sid:backup2,2' or not g('download'):
                return self.send(200,'<input id="usernamefld"/>')
            stats["downloads"]+=1
            if g('encrypt')=='yes':
                if g('encrypt_password')!=ENC or g('encrypt_password_confirm')!=ENC: return self.send(200,'senha de criptografia errada')
                return self.send(200, '---- BEGIN config.xml ----\n' + ('QUJD'*800) + '\n---- END config.xml ----\n', 'application/octet-stream')
            return self.send(200, CONFIG, 'application/octet-stream')
srv=http.server.HTTPServer(('127.0.0.1',PORTA),H)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT,CHAVE)
srv.socket=ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
