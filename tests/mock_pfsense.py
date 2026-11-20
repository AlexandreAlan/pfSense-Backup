# pfSense simulado para os testes: mesmo fluxo da WebGUI que o Backup-pfSense.ps1 usa
# (login com CSRF, privilegios, download do config.xml, criptografia e logout).
# Uso: python3 mock_pfsense.py <senha> <senha_cripto> <porta> <cert.pem> <key.pem>
import http.server, ssl, urllib.parse, uuid, sys, json, base64, datetime, html
SENHA, ENC, PORTA, CERT, CHAVE = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
sess = {}; stats = {"logins_ok":0,"logins_falhos":0,"logouts":0,"downloads":0}
# ---- logs simulados (versao 2) ----
def agora(delta=0):
    d = datetime.datetime.now() - datetime.timedelta(seconds=delta)
    return d.strftime('%b ') + str(d.day).rjust(2) + d.strftime(' %H:%M:%S')
LOGS = {
  'system':     [f"{agora(300-i)} php-fpm[{100+i}]: /index.php: evento de sistema {i}" for i in range(5)],
  'openvpn':    [f"{agora(200-i)} openvpn[777]: usuario.vpn/200.1.1.{i}:5000 Peer Connection Initiated" for i in range(10)],
  'portalauth': [f"{agora(100)} logportalauth[88]: Zone: visitantes - ACCEPT: 52998224725 Maria \u00c1vila, aa:bb:cc:dd:ee:01, 10.10.30.5",
                 f"{agora(90)} logportalauth[88]: Zone: visitantes - VOUCHER: 00232772380 Jose Silva, aa:bb:cc:dd:ee:02, 10.10.30.6, codigo ABC123, 60 min",
                 f"{agora(80)} logportalauth[88]: Zone: visitantes - DISCONNECT: visitante sem cpf, aa:bb:cc:dd:ee:03, 10.10.30.7"],
  'dhcpd':      [f"{agora(50)} dhcpd[55]: DHCPACK on 172.16.10.{i} to 11:22:33:44:55:{i:02x} (PC{i}) via igb0" for i in range(3)],
  'filter':     [(agora(40-i), 'block', '1000000103', 'LAN', f'10.0.0.{i}:5000', '8.8.8.8:53', 'UDP') for i in range(4)],
  'squid':      [f"{datetime.datetime.now().strftime('%d.%m.%Y %H:%M:%S')}|172.16.10.{i}|TCP_MISS/200|http://site{i}.com.br/|-|site{i}.com.br" for i in range(3)],
  'sguard':     [f"{datetime.datetime.now().strftime('%d.%m.%Y %H:%M:%S')}|adult|http://ruim{i}.com/|172.16.10.9|-" for i in range(2)],
}
PFB = {'ip_block.log': '\n'.join(f"{agora(30-i)},1,igb0,LAN,block,4,6,TCP-S,1.2.3.{i},172.16.10.5,443" for i in range(3)) + '\n'}
SURI = {'alerts.log': '\n'.join(datetime.datetime.now().strftime('%m/%d/%Y-%H:%M:%S.000000') + f'  [**] [1:2000{i}:1] ET SCAN teste {i} [**] {{TCP}} 1.2.3.{i}:4444 -> 172.16.10.5:80' for i in range(2)) + '\n'}
LOGS_LIBERADOS = {'portalauth', 'openvpn', 'dhcpd'}   # logs com privilegio no usuario simulado (ipsec NAO)
def linhas_syslog(nome, qtd):
    ls = LOGS.get(nome, [])[-qtd:]
    return list(reversed(ls))   # como a WebGUI com "reverse": mais nova primeiro
def tr(cells, extra=''):
    return '<tr class="text-nowrap">' + extra + ''.join(f'<td>{html.escape(c)}</td>' for c in cells) + '</tr>\n'

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
        q=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if p=='/mock_add':   # usado pelos testes: acrescenta linhas a um log
            nome=q['log'][0]; n=int(q.get('n',['1'])[0])
            for i in range(n): LOGS[nome].append(f"{agora()} openvpn[777]: linha nova {len(LOGS[nome])}")
            return self.send(200,'ok')
        if p=='/index.php' and s in sess and sess[s]["logged"]:
            return self.send(200, '<html>dashboard<input type="hidden" name="__csrf_magic" value="sid:sess3,3" /></html>')
        if p=='/index.php':
            nid=s or uuid.uuid4().hex; sess.setdefault(nid,{"logged":False})
            return self.send(200, '<form><input type=\'hidden\' name=\'__csrf_magic\' value="sid:login1,1" /><input id="usernamefld"/></form>', extra={'Set-Cookie':f'PHPSESSID={nid}; path=/'})
        logged = s in sess and sess[s]["logged"]
        if p=='/diag_backup.php':
            if not logged: return self.send(200, '<input id="usernamefld"/> Enter username and password')
            return self.send(200, '<form><input type="hidden" name="__csrf_magic" value="sid:backup2,2" /></form>')
        if p in ('/system_usermanager.php','/firewall_rules.php','/diag_command.php','/diag_edit.php'):
            return self.send(302, '', extra={'Location':'/diag_backup.php'})
        r = self.paginas_logs(p, q, {}, logged)
        if r is not None: return r
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
        logged = s in sess and sess[s]["logged"]
        if p not in ('/diag_backup.php',) and logged and g('__csrf_magic').startswith('sid:'):
            r = self.paginas_logs(p, urllib.parse.parse_qs(u.query), f, logged, post=True)
            if r is not None: return r
        if p=='/diag_backup.php':
            if not (s in sess and sess[s]["logged"]) or g('__csrf_magic')!='sid:backup2,2' or not g('download'):
                return self.send(200,'<input id="usernamefld"/>')
            stats["downloads"]+=1
            if g('encrypt')=='yes':
                if g('encrypt_password')!=ENC or g('encrypt_password_confirm')!=ENC: return self.send(200,'senha de criptografia errada')
                return self.send(200, '---- BEGIN config.xml ----\n' + ('QUJD'*800) + '\n---- END config.xml ----\n', 'application/octet-stream')
            return self.send(200, CONFIG, 'application/octet-stream')
def paginas_logs(self, p, q, f, logged, post=False):
    # Telas de log da WebGUI, no formato do pfSense 2.7. Devolve None se nao for uma delas.
    g=lambda k: f.get(k,[''])[0]
    tok='<input type="hidden" name="__csrf_magic" value="sid:logs4,4" />'
    if not logged: return None
    if p=='/status_logs.php':
        nome = q.get('logfile',['system'])[0]
        if nome!='system' and nome not in LOGS_LIBERADOS: return self.send(302,'',extra={'Location':'/index.php'})
        qtd = int(g('filterlogentries_qty') or 500) if post else 500
        corpo=''
        for l in linhas_syslog(nome, qtd):
            data, resto = l[:15], l[16:]
            proc, _, msg = resto.partition(': ')
            pid=''
            if '[' in proc: proc, pid = proc[:-1].split('[')
            corpo += tr([data, proc, pid, msg])
        return self.send(200, f'<html>{tok}<table><thead><tr><th>Time</th></tr></thead><tbody>{corpo}</tbody></table></html>')
    if p=='/status_logs_filter.php':
        qtd = int(q.get('filterlogentries_qty',['500'])[0])
        corpo=''
        for (t,a,trk,i,src,dst,pr) in list(reversed(LOGS['filter']))[:qtd]:
            corpo += f'<tr><td><i class="fa fa-times" title="{a}/{trk}"></i></td><td>{t}</td><td>{i}</td><td>Default deny rule</td><td>{src}</td><td>{dst}</td><td>{pr}</td></tr>\n'
        return self.send(200, f'<html>{tok}<table>{corpo}</table></html>')
    if p=='/pfblockerng/pfblockerng_log.php':
        if not post: return self.send(200, f'<html>{tok}<select><option>/var/log/pfblockerng/ip_block.log</option></select></html>')
        arq = g('logFile').rsplit('/',1)[-1]
        if g('download') and arq in PFB: return self.send(200, PFB[arq], 'application/octet-stream')
        return self.send(200, f'<html>{tok}pagina</html>')
    if p=='/suricata/suricata_logs_browser.php':
        if not post: return self.send(200, f'<html>{tok}<select name="instance" id="instance"><option value="0" selected>(LAN) igb0</option></select></html>')
        if g('action')=='load':
            arq=g('file')
            if arq in SURI: return self.send(200, f"|0|/var/log/suricata/suricata_igb0/{arq}|{base64.b64encode(SURI[arq].encode()).decode()}|")
            return self.send(200, '|3|Log file does not exist or that logging feature is not enabled.|')
        return None
    if p=='/squid_monitor.php': return self.send(200, f'<html>{tok}monitor</html>')
    if p=='/squid_monitor_data.php' and post:
        prog=g('program'); qtd=int(g('maxlines') or 50)
        cab = "<tr valign='top'>\n<td class='listhdrr'>Date</td>\n</tr>\n"
        corpo=''.join('<tr valign="top">' + ''.join(f'<td class="listlr">{html.escape(c)}</td>' for c in l.split('|')) + '</tr>\n' for l in list(reversed(LOGS['squid' if prog=='squid' else 'sguard']))[:qtd])
        return self.send(200, cab + corpo)
    if p=='/status_dhcp_leases.php':
        cab='<table><thead><tr><th></th><th>IP address</th><th>MAC address</th><th>Hostname</th><th>Description</th><th>Start</th><th>End</th><th>Online</th><th>Lease Type</th><th>Actions</th></tr></thead><tbody>'
        corpo=''.join(f'<tr><td><i class="fa"></i></td><td>172.16.10.{i}</td><td>11:22:33:44:55:{i:02x}</td><td>PC{i}</td><td></td><td>2026/11/20 08:00:00</td><td>2026/11/20 10:00:00</td><td>online</td><td>active</td><td><a>x</a></td></tr>' for i in range(3))
        return self.send(200, f'<html>{tok}{cab}{corpo}</tbody></table></html>')
    return None
H.paginas_logs = paginas_logs

srv=http.server.HTTPServer(('127.0.0.1',PORTA),H)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT,CHAVE)
srv.socket=ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
