<#
.SYNOPSIS
    Testes funcionais da versao 2: coleta de logs (Logs-pfSense.ps1) contra o
    pfSense simulado e relatorio de auditoria (Relatorio-pfSense.ps1) com um
    config.xml de exemplo. Chamado pelo run-funcional.sh depois do mock subir.
#>
param(
    [Parameter(Mandatory = $true)][string]$Senha,
    [Parameter(Mandatory = $true)][string]$PinOpenssl,
    [int]$Porta = 18443,
    [string]$Curl = 'curl',
    [Parameter(Mandatory = $true)][string]$WorkDir
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object Text.UTF8Encoding($false)
Set-Location $WorkDir
$repo = Split-Path -Parent $PSScriptRoot
$falhas = 0
$enc = New-Object Text.UTF8Encoding($false)

function Cenario([string]$Nome, [scriptblock]$Corpo) {
    $script:NoRetry = $false
    try { $r = & $Corpo; Write-Host "  [PASSOU] $Nome $r" -ForegroundColor Green }
    catch { $script:falhas++; Write-Host "  [FALHOU] $Nome -> $($_.Exception.Message)" -ForegroundColor Red }
}
function Linhas([string]$Arq) { if (-not (Test-Path $Arq)) { return 0 }; return @([IO.File]::ReadAllLines($Arq, $enc) | Where-Object { $_ }).Count }
function ArqDia([string]$Cat) { $d = Get-Date; return (Join-Path $WorkDir "logs-pfsense/TESTE/$Cat/$($d.ToString('yyyy'))/$($d.ToString('MM'))/$($d.ToString('yyyy-MM-dd')).log") }

# ---------------------------------------------------------------- logs
# Carrega o motor de logs SEM rodar o main (dot-source para no "return" do main).
. (Join-Path $repo 'Logs-pfSense.ps1') -Name 'TESTE' -BaseDir $WorkDir
New-Item -ItemType Directory -Force (Join-Path $WorkDir 'secrets'), $LogDir, $StateDir | Out-Null
$cfg = [pscustomobject]@{ User = 'srvbackup-pfsense'; LightSquidUrl = '' }
$pass = $Senha
$base = "https://127.0.0.1:$Porta"
$script:Curl = (Get-Command $Curl -CommandType Application | Select-Object -First 1).Source
$timeout = 5; $maxTime = 30; $lines = 50; $keepDays = 400
$script:Tls = @('-sk', '--connect-timeout', '5', '--max-time', '30', '--pinnedpubkey', "sha256//$PinOpenssl")
$sources = @('sistema', 'portal', 'openvpn', 'ipsec', 'dhcp', 'firewall', 'pfblockerng', 'suricata', 'squid', 'squidguard', 'dhcp-concessoes')

Write-Host '8) Funcoes de apoio'
Cenario 'Get-LineDate entende os formatos do pfSense e dos pacotes' {
    $ref = New-Object DateTime 2026, 11, 20, 12, 0, 0
    $casos = @(
        @('Nov 19 16:51:15 logportalauth[1]: x', '2026-11-19 16:51:15'),
        @('Dec 31 23:59:59 x', '2025-12-31 23:59:59'),            # dezembro lido em novembro: ainda nao chegou, e do ano anterior
        @('{"timestamp":"2026-11-18T10:00:01.1-0300"}', '2026-11-18 10:00:01'),
        @('11/17/2026-08:30:00.123  [**] alerta', '2026-11-17 08:30:00'),
        @('20.11.2026 09:15:00 | 10.0.0.1', '2026-11-20 09:15:00'),
        @('DNSBL-python,Nov 18 07:00:00,dominio', '2026-11-18 07:00:00'),
        @('linha sem data', '2026-11-20 12:00:00'))
    foreach ($c in $casos) {
        $d = (Get-LineDate $c[0] $ref).ToString('yyyy-MM-dd HH:mm:ss')
        if ($d -ne $c[1]) { throw "'$($c[0])' -> $d (esperado $($c[1]))" }
    }
    "($($casos.Count) formatos)"
}
Cenario 'Select-NewLines acha onde parou, mesmo com linhas repetidas' {
    $StateDir = Join-Path $WorkDir 'state-teste'
    $r1 = Select-NewLines @('a', 'b', 'b', 'c') 'x' 100 $true
    if ($r1.New.Count -ne 4) { throw "1a coleta: $($r1.New.Count) (esperado 4)" }
    $r2 = Select-NewLines @('b', 'b', 'c', 'b', 'd') 'x' 100 $true
    if (($r2.New -join ',') -ne 'b,d') { throw "2a coleta: $($r2.New -join ',') (esperado b,d)" }
    $r3 = Select-NewLines @('b', 'c', 'b', 'd') 'x' 100 $true
    if ($r3.New.Count -ne 0) { throw "3a coleta sem novidade devolveu $($r3.New.Count)" }
    $r4 = Select-NewLines @('z1', 'z2') 'x' 2 $true
    if (-not $r4.Gap) { throw 'lista cheia sem o rabo anterior deveria ser lacuna' }
    '(novo, repetido, sem novidade e lacuna)'
}

Write-Host '9) Verificacao de privilegios (-CheckOnly)'
$CheckOnly = $true
Cenario 'aponta a fonte sem privilegio e nao acusa admin' {
    $script:CookieJar = Join-Path $WorkDir ('c_' + [guid]::NewGuid().ToString('N'))
    $f = @(Invoke-LogCollection)
    if ($f -notcontains 'ipsec') { throw "deveria faltar 'ipsec': [$($f -join ',')]" }
    if ($f.Count -ne 1) { throw "so 'ipsec' deveria faltar: [$($f -join ',')]" }
    '(falta so ipsec, como no mock)'
}
$CheckOnly = $false

Write-Host '10) Primeira coleta'
Cenario 'grava cada fonte na sua pasta, por dia' {
    $script:CookieJar = Join-Path $WorkDir ('c_' + [guid]::NewGuid().ToString('N'))
    [void](Invoke-LogCollection)
    $esp = @{ 'sistema' = 5; 'vpn-openvpn' = 10; 'portal-visitantes' = 3; 'dhcp' = 3; 'firewall' = 4
              'pfblockerng/ip_block' = 3; 'suricata/LAN/alertas' = 2; 'squid-acessos' = 3; 'squidguard-bloqueios' = 2 }
    foreach ($k in $esp.Keys) {
        $n = Linhas (ArqDia $k)
        if ($n -ne $esp[$k]) { throw "$k`: $n linha(s) (esperado $($esp[$k])) em $(ArqDia $k)" }
    }
    if (@($script:Warnings | Where-Object { $_ -match '^ipsec' }).Count -ne 1) { throw "faltou o aviso do ipsec: $($script:Warnings -join ' | ')" }
    $fw = [IO.File]::ReadAllLines((ArqDia 'firewall'), $enc)[0]
    if ($fw -notmatch '\| block \(regra 1000000103\) \| LAN \|') { throw "linha do firewall mal formatada: $fw" }
    "($($esp.Count) fontes, aviso do ipsec presente)"
}
Cenario 'planilha de visitantes com CPF, nome com acento e evento' {
    $d = Get-Date
    $csv = Join-Path $WorkDir "visitantes/TESTE/$($d.ToString('yyyy'))/acessos-$($d.ToString('yyyy-MM')).csv"
    $bytes = [IO.File]::ReadAllBytes($csv)
    if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB) { throw 'CSV sem BOM UTF-8 (o Excel estragaria os acentos)' }
    $l = [IO.File]::ReadAllLines($csv, $enc)
    if ($l[0] -ne 'data;hora;zona;evento;cpf;nome;mac;ip;detalhe') { throw "cabecalho: $($l[0])" }
    if ($l.Count -ne 4) { throw "$($l.Count - 1) acesso(s) (esperado 3)" }
    $maria = @($l | Where-Object { $_ -match ';ACCEPT;52998224725;' })[0]
    if ($maria -notmatch ";Maria $([char]0xC1)vila;aa:bb:cc:dd:ee:01;10\.10\.30\.5;") { throw "linha da Maria: $maria" }
    if (-not @($l | Where-Object { $_ -match ';VOUCHER;00232772380;Jose Silva;.*codigo ABC123' })) { throw 'voucher sem o codigo' }
    if (-not @($l | Where-Object { $_ -match ';DISCONNECT;;visitante sem cpf;' })) { throw 'usuario sem CPF deveria ficar com CPF vazio' }
    '(3 acessos, BOM, acento, voucher)'
}
Cenario 'foto das concessoes DHCP em CSV' {
    $d = Get-Date
    $csv = Join-Path $WorkDir "logs-pfsense/TESTE/dhcp-concessoes/$($d.ToString('yyyy'))/$($d.ToString('MM'))/$($d.ToString('yyyy-MM-dd')).csv"
    $l = [IO.File]::ReadAllLines($csv, $enc)
    if ($l[0] -notmatch '^coletado;IP address;MAC address;Hostname') { throw "cabecalho: $($l[0])" }
    if ($l.Count -ne 4) { throw "$($l.Count - 1) concessoes (esperado 3)" }
    '(3 concessoes)'
}

Write-Host '11) Coletas seguintes'
Cenario 'sem novidade nao duplica nada' {
    $antes = Linhas (ArqDia 'vpn-openvpn'); $antesFw = Linhas (ArqDia 'firewall'); $antesPfb = Linhas (ArqDia 'pfblockerng/ip_block')
    $script:Warnings.Clear(); $script:CookieJar = Join-Path $WorkDir ('c_' + [guid]::NewGuid().ToString('N'))
    [void](Invoke-LogCollection)
    if ((Linhas (ArqDia 'vpn-openvpn')) -ne $antes) { throw 'openvpn duplicou' }
    if ((Linhas (ArqDia 'firewall')) -ne $antesFw) { throw 'firewall duplicou' }
    if ((Linhas (ArqDia 'pfblockerng/ip_block')) -ne $antesPfb) { throw 'pfblockerng duplicou' }
    '(nada duplicado)'
}
Cenario 'linhas novas entram uma vez so' {
    & $script:Curl -sk "$base/mock_add?log=openvpn&n=3" | Out-Null
    $antes = Linhas (ArqDia 'vpn-openvpn')
    $script:Warnings.Clear(); $script:CookieJar = Join-Path $WorkDir ('c_' + [guid]::NewGuid().ToString('N'))
    [void](Invoke-LogCollection)
    $depois = Linhas (ArqDia 'vpn-openvpn')
    if ($depois -ne $antes + 3) { throw "$antes -> $depois (esperado +3)" }
    '(+3)'
}
Cenario 'mais linhas que o pedido vira AVISO de lacuna' {
    & $script:Curl -sk "$base/mock_add?log=openvpn&n=80" | Out-Null
    $script:Warnings.Clear(); $script:CookieJar = Join-Path $WorkDir ('c_' + [guid]::NewGuid().ToString('N'))
    [void](Invoke-LogCollection)
    if (-not @($script:Warnings | Where-Object { $_ -match 'openvpn.*lacuna' })) { throw "sem aviso de lacuna: $($script:Warnings -join ' | ')" }
    '(aviso gerado)'
}

# ------------------------------------------------------------ modo SSH
Write-Host '13) Modo SSH (chave travada, comando forcado de verdade)'
$sw = Join-Path $WorkDir 'ssh'; $root = Join-Path $sw 'pfsense'
foreach ($d in @('var/log/arquivo', 'var/log/pfblockerng', 'var/log/suricata/suricata_igb033667', 'var/squidGuard/log', 'var/dhcpd/var/db', 'secrets', 'backups/SSHT')) {
    New-Item -ItemType Directory -Force (Join-Path $root $d), (Join-Path $sw $d) | Out-Null
}
function Hoje([int]$seg) { $d = (Get-Date).AddSeconds(-$seg); return ($d.ToString('MMM ', [Globalization.CultureInfo]::InvariantCulture) + $d.Day.ToString().PadLeft(2) + $d.ToString(' HH:mm:ss')) }
function Escreve([string]$Rel, [string[]]$Linhas, [switch]$Acrescenta) {
    $f = Join-Path $root $Rel; $t = ($Linhas -join "`n") + "`n"
    if ($Acrescenta) { [IO.File]::AppendAllText($f, $t, $enc) } else { [IO.File]::WriteAllText($f, $t, $enc) }
}
Escreve 'var/log/system.log' @(1..4 | ForEach-Object { "$(Hoje (400 - $_)) fw php-fpm[1]: sistema $_" })
Escreve 'var/log/auth.log' @("$(Hoje 300) fw php-fpm[2]: /index.php: Successful login for user 'admin' from: 172.16.80.2 (Local Database)")
Escreve 'var/log/portalauth.log' @("$(Hoje 200) fw logportalauth[9]: Zone: visitantes - ACCEPT: 52998224725 Ana Souza, aa:bb:cc:00:00:01, 10.10.30.11")
Escreve 'var/log/filter.log' @(1..6 | ForEach-Object { "$(Hoje (100 - $_)) fw filterlog[5]: 5,,,1000000103,igb0,match,block,in,4,0x0,,64,1,0,none,6,tcp,60,10.0.0.$_,8.8.8.8,5000,443,0,S,1,,64240,,mss" })
Escreve 'var/log/pfblockerng/ip_block.log' @('Nov 20 10:00:01,a', 'Nov 20 10:00:02,b', 'Nov 20 10:00:03,c')
Escreve 'var/log/suricata/suricata_igb033667/alerts.log' @("$((Get-Date).ToString('MM/dd/yyyy-HH:mm:ss')).1  [**] [1:1:1] ET teste [**] {TCP} 1.2.3.4:1 -> 172.16.10.5:80")
Escreve 'var/squidGuard/log/block.log' @("$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [1] Request(default/adult/-) http://x.com/ 172.16.10.9/- - GET REDIRECT")
Escreve 'var/dhcpd/var/db/dhcpd.leases' @('lease 172.16.10.50 {', '  starts 4 2026/11/20 13:00:01;', '  ends 4 2026/11/20 15:00:01;', '  binding state active;', '  hardware ethernet aa:bb:cc:dd:ee:50;', '  client-hostname "PC-RH";', '}')
Escreve 'backups/SSHT/config-SSHT-2026-11-20_0300.xml' @('<?xml version="1.0"?><pfsense><interfaces><lan><if>igb0</if><descr>LAN</descr></lan></interfaces><installedpackages><suricata><rule><interface>lan</interface><uuid>33667</uuid></rule></suricata></installedpackages></pfsense>')
Copy-Item (Join-Path $root 'backups/SSHT/config-SSHT-2026-11-20_0300.xml') (Join-Path $sw 'backups/SSHT/')

. (Join-Path $repo 'Logs-pfSense.ps1') -Name 'SSHT' -BaseDir $sw
$forced = Join-Path $sw 'forced.sh'
[IO.File]::WriteAllText($forced, (New-ForcedCommand $root), $enc)
$env:FAKE_FORCED = $forced
$script:Ssh = Join-Path $PSScriptRoot 'fake_ssh.sh'
$script:SshRoot = $root
$cfg = [pscustomobject]@{ User = 'srvbackup-pfsense'; Host = '127.0.0.1'; LightSquidUrl = '' }
$transport = 'ssh'; $sshPort = 22; $sshUser = 'srvbackup-pfsense'; $timeout = 5; $keepDays = 400
$sources = $SshDefaultSources
New-Item -ItemType Directory -Force $StateDir, $LogDir | Out-Null
function ArqSsh([string]$Cat) { $d = Get-Date; return (Join-Path $sw "logs-pfsense/SSHT/$Cat/$($d.ToString('yyyy'))/$($d.ToString('MM'))/$($d.ToString('yyyy-MM-dd')).log") }

Cenario 'a trava recusa tudo que nao for list/get/sig dos logs' {
    $tentativas = @('id', 'list x', 'get /etc/passwd 0', 'get /var/log/../../../etc/passwd 0', 'get /var/log/system.log 0;id',
                    'get /var/log/system.log abc', 'sig /etc/passwd', 'get', 'get /var/log/nginx.log 0')
    foreach ($t in $tentativas) {
        $r = Invoke-Ssh ($t -split ' ')
        $out = Read-Text $r.Out
        if ($r.Code -ne 2 -or $out -match 'root:|uid=|sistema') { throw "'$t' deveria ser recusado (exit $($r.Code), saida: $out)" }
    }
    "($($tentativas.Count) tentativas recusadas)"
}
$CheckOnly = $true
Cenario '-CheckOnly: encontra as fontes e confirma que a chave esta travada' {
    $f = @(Invoke-LogCollection)
    $esperado = @('openvpn', 'ipsec', 'dhcp', 'dns', 'gateways', 'squid')   # arquivos que nao existem no pfSense simulado
    if ((@($f | Sort-Object) -join ',') -ne (@($esperado | Sort-Object) -join ',')) { throw "faltando: [$($f -join ',')]" }
    '(fontes conferidas, chave travada)'
}
Cenario '-CheckOnly reprova uma chave SEM trava' {
    [IO.File]::WriteAllText($forced, '/bin/sh -c "$SSH_ORIGINAL_COMMAND"', $enc)
    try {
        try { Invoke-LogCollection | Out-Null; throw 'deveria reprovar' } catch { if ($_.Exception.Message -notmatch 'NAO esta travada') { throw $_ } }
    } finally { [IO.File]::WriteAllText($forced, (New-ForcedCommand $root), $enc); $script:NoRetry = $false }
    '(reprovada)'
}
$CheckOnly = $false

Cenario 'primeira coleta: tudo, inclusive firewall e autenticacao' {
    $script:Warnings.Clear(); $script:Counts.Clear()
    Invoke-LogCollection | Out-Null
    $esp = @{ 'sistema' = 4; 'autenticacao' = 1; 'portal-visitantes' = 1; 'firewall' = 6; 'pfblockerng/ip_block' = 3; 'suricata/LAN/alertas' = 1; 'squidguard-bloqueios' = 1 }
    foreach ($k in $esp.Keys) {
        $n = Linhas (ArqSsh $k)
        if ($n -ne $esp[$k]) {
            $arvore = (Get-ChildItem (Join-Path $sw 'logs-pfsense') -Recurse -File | ForEach-Object { $_.FullName.Substring($sw.Length) }) -join ' ; '
            throw "$k`: $n linha(s) (esperado $($esp[$k])). Contagem: $(($script:Counts.Keys | ForEach-Object { "$_=$($script:Counts[$_])" }) -join ', '). Avisos: $($script:Warnings -join ' | '). Arquivos: $arvore"
        }
    }
    $d = Get-Date
    $csv = Join-Path $sw "visitantes/SSHT/$($d.ToString('yyyy'))/acessos-$($d.ToString('yyyy-MM')).csv"
    if (-not (Select-String -Path $csv -Pattern ';ACCEPT;52998224725;Ana Souza;' -Quiet)) { throw 'planilha de visitantes sem a Ana' }
    $lease = Join-Path $sw "logs-pfsense/SSHT/dhcp-concessoes/$($d.ToString('yyyy'))/$($d.ToString('MM'))/$($d.ToString('yyyy-MM-dd')).csv"
    if (-not (Select-String -Path $lease -Pattern ';172\.16\.10\.50;aa:bb:cc:dd:ee:50;PC-RH;' -Quiet)) { throw 'concessao DHCP nao gravada' }
    if ($script:Warnings.Count -gt 0) { throw "avisos inesperados: $($script:Warnings -join ' | ')" }
    "($($esp.Count) fontes + planilha + DHCP)"
}
Cenario 'so os bytes novos, inclusive linha incompleta' {
    Escreve 'var/log/filter.log' @("$(Hoje 5) fw filterlog[5]: nova 1", "$(Hoje 4) fw filterlog[5]: nova 2") -Acrescenta
    [IO.File]::AppendAllText((Join-Path $root 'var/log/filter.log'), "$(Hoje 3) fw filterlog[5]: pela metade", $enc)   # sem \n
    Invoke-LogCollection | Out-Null
    if ((Linhas (ArqSsh 'firewall')) -ne 8) { throw "firewall: $(Linhas (ArqSsh 'firewall')) (esperado 8: a linha pela metade fica para depois)" }
    [IO.File]::AppendAllText((Join-Path $root 'var/log/filter.log'), " - completa`n", $enc)
    Invoke-LogCollection | Out-Null
    $ult = @([IO.File]::ReadAllLines((ArqSsh 'firewall'), $enc))[-1]
    if ((Linhas (ArqSsh 'firewall')) -ne 9 -or $ult -notmatch 'pela metade - completa$') { throw "linha incompleta mal tratada: $ult" }
    '(+2, depois +1 completa)'
}
Cenario 'log girou (arquivado em .bz2): termina o antigo e le o novo, sem perder nem duplicar' {
    Escreve 'var/log/filter.log' @("$(Hoje 2) fw filterlog[5]: antes de girar") -Acrescenta
    $arq = Join-Path $root 'var/log/arquivo/filter-20261120-110000'
    Move-Item (Join-Path $root 'var/log/filter.log') $arq
    & bzip2 $arq
    Escreve 'var/log/filter.log' @("$(Hoje 1) fw filterlog[5]: depois de girar 1", "$(Hoje 0) fw filterlog[5]: depois de girar 2")
    Invoke-LogCollection | Out-Null
    $n = Linhas (ArqSsh 'firewall')
    if ($n -ne 12) { throw "firewall: $n linha(s) (esperado 12)" }
    if (@($script:Warnings | Where-Object { $_ -match 'lacuna' }).Count) { throw "nao deveria haver lacuna: $($script:Warnings -join ' | ')" }
    '(1 do antigo + 2 do novo)'
}
Cenario 'arquivo reescrito no lugar (pfBlockerNG) nao duplica' {
    Escreve 'var/log/pfblockerng/ip_block.log' @('Nov 20 10:00:02,b', 'Nov 20 10:00:03,c', 'Nov 20 10:00:04,d')
    Invoke-LogCollection | Out-Null
    if ((Linhas (ArqSsh 'pfblockerng/ip_block')) -ne 4) { throw "pfblockerng: $(Linhas (ArqSsh 'pfblockerng/ip_block')) (esperado 4)" }
    '(+1)'
}
Cenario 'linha da chave para o pfSense: travas e aspas escapadas' {
    $l = Get-AuthorizedKeyLine 'ssh-ed25519 AAAAC3NzaTESTE pfSense-Backup' '172.16.10.7'
    if ($l -notmatch '^restrict,from="172\.16\.10\.7",command="/bin/sh -c ''.*''" ssh-ed25519 AAAAC3NzaTESTE pfSense-Backup$') { throw "formato: $l" }
    $soltas = ([regex]::Matches(($l -replace '\\"', ''), '"')).Count
    if ($soltas -ne 4) { throw "aspas sem escape dentro do command: $soltas (esperado 4: from e command)" }
    "($($l.Length) caracteres)"
}

# ----------------------------------------------------------- auditoria
Write-Host '12) Relatorio de auditoria'
$fx = Join-Path $PSScriptRoot 'fixtures'
$out = Join-Path $WorkDir 'auditoria-teste.html'
Cenario 'gera o HTML com as secoes, as mudancas e os pontos de atencao' {
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $repo 'Relatorio-pfSense.ps1') -Name 'TESTE' -BaseDir $WorkDir `
        -File (Join-Path $fx 'config-exemplo.xml') -Previous (Join-Path $fx 'config-anterior.xml') -OutFile $out *>&1 | Tee-Object -Variable saida | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "saiu com $LASTEXITCODE`: $($saida -join ' ')" }
    $h = [IO.File]::ReadAllText($out, $enc)
    $tem = @('fw-exemplo.exemplo.local', 'id="regras"', 'Visitantes nao acessam a LAN', 'NAO lan', 'id="vpn"', 'VPN fornecedor',
             'sem CRL', 'Regra criada', 'Regra alterada', 'Usuario alterado', 'Alias alterado', 'Usuario criado', 'maria.vpn',
             'DESATIVADO ainda no grupo de administradores', 'CA-VPN-TESTE', 'vpn-teste.exemplo', 'Impressora RH', 'Web interno',
             '203.0.113.10', 'VLAN 20 sobre igb0', 'ADMIN')
    foreach ($t in $tem) { if ($h.IndexOf($t) -lt 0) { throw "falta no HTML: '$t'" } }
    if ($env:RUNNER_TEMP) { Copy-Item $out (Join-Path $env:RUNNER_TEMP 'auditoria-exemplo.html') }   # artefato do CI
    "($($tem.Count) conferencias)"
}
Cenario 'NUNCA mostra segredos' {
    $h = [IO.File]::ReadAllText($out, $enc)
    foreach ($s in @('SEGREDO', 'U0VHUkVE', '$2y$10$')) { if ($h.IndexOf($s) -ge 0) { throw "segredo vazou no HTML: '$s'" } }
    '(hash, chave privada, PSK, TLS, RADIUS e SNMP fora)'
}
Cenario 'backup criptografado e pulado sem erro' {
    $e = Join-Path $WorkDir 'config-TESTE-x.xml.enc'; Set-Content $e 'x'
    $r = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $repo 'Relatorio-pfSense.ps1') -Name 'TESTE' -BaseDir $WorkDir -File $e
    if ($LASTEXITCODE -ne 0 -or ($r -join ' ') -notmatch 'criptografado') { throw "exit $LASTEXITCODE, saida: $r" }
    '(pulado)'
}

Write-Host ''
if ($falhas) { Write-Host "RESULTADO (logs/auditoria): $falhas cenario(s) FALHARAM" -ForegroundColor Red; exit 1 }
Write-Host 'RESULTADO (logs/auditoria): todos os cenarios passaram' -ForegroundColor Green
