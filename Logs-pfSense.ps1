<#
.SYNOPSIS
    Coleta os logs do pfSense pela WebGUI e guarda organizados por categoria e dia.

.DESCRIPTION
    Segundo motor do pfSense-Backup (o primeiro e o Backup-pfSense.ps1). Usa o
    MESMO perfil, a MESMA senha cifrada e o MESMO certificado fixado: so conversa
    com o pfSense por HTTPS, pela WebGUI, como o backup. Nao instala nada no
    pfSense.

    Fontes (cada uma so e coletada se estiver em "LogSources" no JSON do perfil
    e se o usuario tiver o privilegio correspondente no pfSense):

        sistema           Status > System Logs > General   ("WebCfg - Status: Logs: System")
        portal            ... > Captive Portal Auth        ("WebCfg - Status: System Logs: Portal Auth")
        openvpn           ... > OpenVPN                    ("WebCfg - Status: System Logs: OpenVPN")
        ipsec             ... > IPsec                      ("WebCfg - Status: System Logs: IPsec VPN")
        dhcp              ... > DHCP                       ("WebCfg - Status: Logs: DHCP")
        dns               ... > DNS Resolver               ("WebCfg - Status: Logs: Resolver")
        gateways          ... > Gateways                   ("WebCfg - Status: Logs: Gateways")
        ppp               ... > PPP (opcional; no 2.7 o privilegio aparece com o nome errado "IPsec VPN")
        firewall          ... > Firewall                   ("WebCfg - Status: Logs: Firewall")
        pfblockerng       Firewall > pfBlockerNG > Logs    ("WebCfg - Firewall: pfBlockerNG")
        suricata          Services > Suricata > Logs View  ("WebCfg - Services: suricata package.")
        squid, squidguard Status > Squid Proxy Monitor     ("WebCfg - Services: Squid package")
        dhcp-concessoes   Status > DHCP Leases (foto)      ("WebCfg - Status: DHCP leases")

    O pfSense confere o endereco exato de cada privilegio: "Logs: System" NAO
    libera os outros logs. O log "Authentication > General" (logins na WebGUI e
    no SSH) nao tem privilegio proprio - so admin ve - e fica fora.

    E, se "LightSquidUrl" estiver no perfil, os relatorios diarios do LightSquid
    (servidor web proprio do pacote, com usuario e senha proprios).

    Onde guarda (so aparecem as datas que tiverem dados):

        <BaseDir>\logs-pfsense\<Nome>\<categoria>\AAAA\MM\AAAA-MM-DD.log
        <BaseDir>\visitantes\<Nome>\AAAA\acessos-AAAA-MM.csv      (portal cativo, abre no Excel)
        <BaseDir>\lightsquid\<Nome>\AAAA\MM\AAAA-MM-DD.html
        <BaseDir>\state\<Nome>\                                   (controle interno: o que ja foi coletado)
        <BaseDir>\logs\<Nome>\<Nome>-logs.log                     (log desta coleta)
        <BaseDir>\status\<Nome>\logs-status.txt, logs-ultimo-ok.txt, logs-mensagem.txt   (Zabbix)

    Incremental: a cada execucao pede as ultimas N linhas (LogLines) de cada log,
    acha onde a coleta anterior parou e grava SO o que e novo. Se entre duas
    coletas o pfSense gerar mais que N linhas, parte se perde: isso vira AVISO
    ("possivel lacuna") no status. Aumente LogLines ou rode mais vezes.

    Codigo de saida: 0 = OK (ou AVISO), 1 = erro. Eventos no Log de Aplicativo
    (origem "pfSense-Backup"): 1010 = OK, 1011 = erro, 1012 = aviso.

.PARAMETER Name
    Nome do perfil (o mesmo do backup).

.PARAMETER BaseDir
    Pasta raiz da instalacao. Padrao: a pasta deste script.

.PARAMETER CheckOnly
    Nao grava logs. So confere: login, acesso a cada fonte pedida e que o
    usuario NAO acessa paginas administrativas. Usado pelo instalador.

.NOTES
    Windows PowerShell 4.0 a 5.1. Arquivo em ASCII puro (veja Backup-pfSense.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Name,

    [string]$BaseDir,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$EventSource = 'pfSense-Backup'
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$OutputEncoding = New-Object Text.UTF8Encoding($false)

# Paginas que o usuario NAO pode acessar, mesmo com os privilegios de logs.
$ForbiddenPages = @('system_usermanager.php', 'firewall_rules.php', 'diag_command.php', 'diag_edit.php')

# Fontes padrao (quando o perfil nao diz quais).
$DefaultSources = @('sistema', 'portal', 'openvpn', 'ipsec', 'dhcp', 'dns', 'gateways',
                    'firewall', 'pfblockerng', 'suricata', 'squid', 'squidguard', 'dhcp-concessoes')

# Fontes que usam a tela padrao de logs (status_logs.php?logfile=...).
$SyslogSources = [ordered]@{
    'sistema'      = 'system'
    'autenticacao' = 'auth'
    'portal'       = 'portalauth'
    'openvpn'      = 'openvpn'
    'ipsec'        = 'ipsec'
    'dhcp'         = 'dhcpd'
    'dns'          = 'resolver'
    'gateways'     = 'gateways'
    'ppp'          = 'ppp'
}

# Privilegio do pfSense que libera cada fonte (para as mensagens e para a documentacao).
# "autenticacao" (Authentication > General: logins na WebGUI/SSH) NAO tem privilegio
# proprio no pfSense - so admin ve. Fica fora do padrao.
$PrivName = @{
    'sistema' = '"WebCfg - Status: Logs: System"'; 'autenticacao' = '(nenhum: so admin ve este log)'
    'portal' = '"WebCfg - Status: System Logs: Portal Auth"'; 'openvpn' = '"WebCfg - Status: System Logs: OpenVPN"'
    'ipsec' = '"WebCfg - Status: System Logs: IPsec VPN"'; 'dhcp' = '"WebCfg - Status: Logs: DHCP"'
    'dns' = '"WebCfg - Status: Logs: Resolver"'; 'gateways' = '"WebCfg - Status: Logs: Gateways"'
    'ppp' = '(o segundo "WebCfg - Status: System Logs: IPsec VPN" da lista: o pfSense 2.7 usa esse nome errado para o log de PPP)'; 'firewall' = '"WebCfg - Status: Logs: Firewall"'
    'pfblockerng' = '"WebCfg - Firewall: pfBlockerNG"'; 'suricata' = '"WebCfg - Services: suricata package."'
    'squid' = '"WebCfg - Services: Squid package"'; 'squidguard' = '"WebCfg - Services: Squid package"'
    'dhcp-concessoes' = '"WebCfg - Status: DHCP leases"'
}

# Pasta de cada fonte dentro de logs-pfsense\<Nome>\
$CategoryDir = @{
    'sistema' = 'sistema'; 'autenticacao' = 'autenticacao'; 'portal' = 'portal-visitantes'
    'openvpn' = 'vpn-openvpn'; 'ipsec' = 'vpn-ipsec'; 'dhcp' = 'dhcp'; 'dns' = 'dns'
    'gateways' = 'gateways'; 'ppp' = 'ppp'; 'firewall' = 'firewall'
    'squid' = 'squid-acessos'; 'squidguard' = 'squidguard-bloqueios'
}

# Arquivos do pfBlockerNG coletados (o unified.log repete os outros, fica de fora).
$PfbFiles = @('ip_block.log', 'ip_permit.log', 'dnsbl.log', 'pfblockerng.log', 'error.log')
# Arquivos de cada interface do Suricata.
$SuricataFiles = @('alerts.log', 'block.log')

$Months = @{ Jan = 1; Feb = 2; Mar = 3; Apr = 4; May = 5; Jun = 6; Jul = 7; Aug = 8; Sep = 9; Oct = 10; Nov = 11; Dec = 12 }

# ------------------------- caminhos do perfil -------------------------
$CfgFile   = Join-Path $BaseDir "config\$Name.json"
$SecDir    = Join-Path $BaseDir 'secrets'
$KeyFile   = Join-Path $SecDir  "$Name.key"
$PassFile  = Join-Path $SecDir  "$Name.pass"
$LsFile    = Join-Path $SecDir  "$Name.lightsquid.pass"
$LogDir    = Join-Path $BaseDir "logs\$Name"
$LogFile   = Join-Path $LogDir  "$Name-logs.log"
$StatusDir = Join-Path $BaseDir "status\$Name"
$StateDir  = Join-Path $BaseDir "state\$Name"
$LogRoot   = Join-Path $BaseDir "logs-pfsense\$Name"
$VisitDir  = Join-Path $BaseDir "visitantes\$Name"
$LsRoot    = Join-Path $BaseDir "lightsquid\$Name"
$TmpFile   = Join-Path $SecDir  ("logs_" + [guid]::NewGuid().ToString('N') + '.tmp')
$CookieJar = Join-Path $SecDir  ("cookies_" + [guid]::NewGuid().ToString('N') + '.tmp')

$script:NoRetry  = $false
$script:Csrf     = ''
$script:Warnings = New-Object System.Collections.ArrayList
$script:Counts   = [ordered]@{}

# ------------------------------ funcoes -------------------------------
function Write-Log([string]$Message) {
    $line = "$((Get-Date).ToString('s'))  [$Name]  $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Write-Event([int]$Id, [string]$Type, [string]$Message) {
    try {
        if ([Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-EventLog -LogName Application -Source $EventSource -EventId $Id `
                -EntryType $Type -Message "[$Name] $Message" -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-Status([string]$Status, [string]$Message) {
    # Mesmo formato do backup, com prefixo "logs-": um valor por arquivo, ASCII.
    try {
        if (-not (Test-Path $StatusDir)) { New-Item -ItemType Directory -Force $StatusDir | Out-Null }
        $ascii = New-Object Text.ASCIIEncoding
        [IO.File]::WriteAllText((Join-Path $StatusDir 'logs-status.txt'), $Status, $ascii)
        [IO.File]::WriteAllText((Join-Path $StatusDir 'logs-mensagem.txt'), "$((Get-Date).ToString('s'))  $Message", $ascii)
        if ($Status -ne 'ERRO') {
            $epoch = [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
            [IO.File]::WriteAllText((Join-Path $StatusDir 'logs-ultimo-ok.txt'), "$epoch", $ascii)
        }
    } catch {}
}

function Add-Warning([string]$Message) {
    [void]$script:Warnings.Add($Message)
    Write-Log "AVISO: $Message"
}

function Stop-Permanent([string]$Message) {
    $script:NoRetry = $true
    throw $Message
}

function Get-Csrf([string]$Html) {
    $m = [regex]::Match($Html, 'value="(sid:[^"]+)"')
    if (-not $m.Success) { $m = [regex]::Match($Html, "value='(sid:[^']+)'") }
    if (-not $m.Success) { $m = [regex]::Match($Html, 'csrfMagicToken\s*=\s*"(sid:[^"]+)"') }
    return $m.Groups[1].Value
}

function Read-Secret([string]$File, [byte[]]$Key) {
    $sec  = Get-Content $File | ConvertTo-SecureString -Key $Key
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertTo-CurlConfig([string]$Option, [string]$Value) {
    return ('{0} = "{1}"' -f $Option, ($Value -replace '\\', '\\' -replace '"', '\"'))
}

function Read-Text([string]$File) {
    if (-not (Test-Path $File)) { return '' }
    return [IO.File]::ReadAllText($File, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Web([string[]]$CurlArgs, [string[]]$Secrets = @(), [string[]]$Tls = $script:Tls) {
    # Uma chamada do curl. A resposta vai SEMPRE para $TmpFile (nunca pelo pipe:
    # o PS 5.1 converte a saida de exe nativo pela pagina de codigo do console e
    # estragaria acentos). Devolve o codigo HTTP. Segredos por stdin (-K -).
    if (Test-Path $TmpFile) { Remove-Item $TmpFile -Force }
    $all = @($Tls) + @('-o', $TmpFile, '-w', '%{http_code}') + @($CurlArgs)
    if ($Secrets.Count -gt 0) {
        $out = ($Secrets -join "`n") | & $script:Curl -K - @all
    } else {
        $out = & $script:Curl @all
    }
    $rc = $LASTEXITCODE
    if ($rc -eq 90) {
        Stop-Permanent ("a chave do certificado do pfSense NAO confere com a do cadastro (curl exit 90). " +
            "A senha NAO foi enviada. Se a troca for legitima, rode o instalador com -TrustNewCert.")
    }
    if ($rc -ne 0) { throw "curl falhou (exit $rc) em: $($CurlArgs[-1])" }
    return ([string]($out -join '')).Trim()
}

function Test-LoginPage([string]$Html) {
    return ($Html -match 'id="usernamefld"' -or $Html -match 'Enter username and password')
}

function Get-Page([string]$Path) {
    # GET autenticado. Devolve @{ Code; Html; Ok }. Ok = 200 e nao e a tela de login.
    # Sem privilegio, o pfSense responde 302 para a primeira pagina permitida.
    $code = Invoke-Web @('-b', $CookieJar, '-c', $CookieJar, "$base/$Path")
    $html = Read-Text $TmpFile
    $tok = Get-Csrf $html
    if ($tok) { $script:Csrf = $tok }
    if (Test-LoginPage $html) { throw "a sessao caiu (o pfSense pediu login de novo) em $Path." }
    return [pscustomobject]@{ Code = $code; Html = $html; Ok = ($code -eq '200') }
}

function Send-Form([string]$Path, [string[]]$Fields) {
    # POST autenticado com o token CSRF da sessao. Devolve o codigo HTTP; o corpo fica em $TmpFile.
    $a = @('-b', $CookieJar, '-c', $CookieJar, '--data-urlencode', "__csrf_magic=$($script:Csrf)")
    foreach ($f in $Fields) { $a += @('--data-urlencode', $f) }
    $a += "$base/$Path"
    return (Invoke-Web $a)
}

function Connect-PfSense {
    $code = Invoke-Web @('-c', $CookieJar, "$base/index.php")
    $tok = Get-Csrf (Read-Text $TmpFile)
    if (-not $tok) { throw "nao achei o token CSRF na tela de login (e mesmo um pfSense em $base?)." }
    Invoke-Web @('-b', $CookieJar, '-c', $CookieJar,
        '--data-urlencode', "__csrf_magic=$tok",
        '--data-urlencode', "usernamefld=$($cfg.User)",
        '--data-urlencode', 'login=Sign In',
        "$base/index.php") @(ConvertTo-CurlConfig 'data-urlencode' "passwordfld=$pass") | Out-Null
    # Confirma o login numa pagina qualquer (index.php redireciona para a primeira permitida).
    $code = Invoke-Web @('-b', $CookieJar, '-c', $CookieJar, '-L', "$base/index.php")
    $html = Read-Text $TmpFile
    if (Test-LoginPage $html) {
        Stop-Permanent "login recusado: usuario/senha errados ou usuario desativado. Confira o usuario '$($cfg.User)' no pfSense e rode o instalador com -UpdatePassword."
    }
    $tok = Get-Csrf $html
    if ($tok) { $script:Csrf = $tok }
}

function Disconnect-PfSense {
    $noRetry = $script:NoRetry
    try {
        if ($script:Csrf) {
            Invoke-Web @('-b', $CookieJar, '--data-urlencode', "__csrf_magic=$($script:Csrf)",
                '--data-urlencode', 'logout=', "$base/index.php?logout") | Out-Null
        }
    } catch {}
    $script:NoRetry = $noRetry
}

function ConvertFrom-HtmlCell([string]$Html) {
    $t = [regex]::Replace($Html, '(?is)<script\b.*?</script>', ' ')
    $t = [regex]::Replace($t, '(?is)<br\s*/?>', ' ')
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = [Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function Get-TableRows([string]$Html) {
    # Linhas <tr> com pelo menos uma <td>. Cada item: @{ Cells = texto de cada <td>; Raw = html da linha }.
    $rows = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Html, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
        $inner = $m.Groups[1].Value
        if ($inner -match 'listhdrr') { continue }   # cabecalho em <td> (tela do Squid)
        $cells = @()
        foreach ($c in [regex]::Matches($inner, '(?is)<td\b[^>]*>(.*?)</td>')) { $cells += , (ConvertFrom-HtmlCell $c.Groups[1].Value) }
        if ($cells.Count -gt 0) { [void]$rows.Add([pscustomobject]@{ Cells = $cells; Raw = $inner }) }
    }
    return , $rows
}

function Get-LineDate([string]$Line, [datetime]$Fallback) {
    # Data de uma linha de log, em qualquer dos formatos usados pelo pfSense e pacotes.
    # O syslog nao tem ano: usa o ano atual (ou o anterior, se o mes ainda nao chegou).
    try {
        $m = [regex]::Match($Line, '(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)')
        if ($m.Success) { return (New-Object DateTime ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value)) }
        $m = [regex]::Match($Line, '(\d\d)/(\d\d)/(\d{4})-(\d\d):(\d\d):(\d\d)')   # Suricata MM/DD/AAAA
        if ($m.Success) { return (New-Object DateTime ([int]$m.Groups[3].Value), ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value)) }
        $m = [regex]::Match($Line, '(\d\d)\.(\d\d)\.(\d{4})\s+(\d\d):(\d\d):(\d\d)')  # Squid DD.MM.AAAA
        if ($m.Success) { return (New-Object DateTime ([int]$m.Groups[3].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[1].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value)) }
        $m = [regex]::Match($Line, '\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d\d):(\d\d):(\d\d)')
        if ($m.Success) {
            $mes = $Months[$m.Groups[1].Value]; $ano = $Fallback.Year
            if ($mes -gt $Fallback.Month) { $ano-- }
            return (New-Object DateTime $ano, $mes, ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value))
        }
    } catch {}
    return $Fallback
}

function Select-NewLines([string[]]$Lines, [string]$StateName, [int]$Requested, [bool]$CanTruncate) {
    # Devolve so as linhas que a coleta anterior ainda nao gravou.
    # Guarda as ultimas linhas vistas em state\<Nome>\<StateName>.last e procura
    # esse "rabo" na lista nova: tudo depois dele e novo. Se nao achar e a lista
    # veio cheia (Requested), pode ter passado mais linha do que o pedido: lacuna.
    $stateFile = Join-Path $StateDir "$StateName.last"
    $enc = New-Object Text.UTF8Encoding($false)
    $prev = @()
    if (Test-Path $stateFile) { $prev = @([IO.File]::ReadAllLines($stateFile, $enc)) }
    $Lines = @($Lines)
    $new = $Lines; $gap = $false
    if ($prev.Count -gt 0 -and $Lines.Count -gt 0) {
        $k = [Math]::Min($prev.Count, 30)
        $tail = $prev[($prev.Count - $k)..($prev.Count - 1)]
        $idx = -1
        for ($i = $Lines.Count - 1; $i -ge ($k - 1); $i--) {
            if ($Lines[$i] -cne $tail[$k - 1]) { continue }
            $ok = $true
            for ($j = 1; $j -lt $k; $j++) { if ($Lines[$i - $j] -cne $tail[$k - 1 - $j]) { $ok = $false; break } }
            if ($ok) { $idx = $i; break }
        }
        if ($idx -lt 0) {
            for ($i = $Lines.Count - 1; $i -ge 0; $i--) { if ($Lines[$i] -ceq $tail[$k - 1]) { $idx = $i; break } }
        }
        if ($idx -ge 0) {
            if ($idx -ge $Lines.Count - 1) { $new = @() } else { $new = $Lines[($idx + 1)..($Lines.Count - 1)] }
        } else {
            $gap = ($CanTruncate -and $Lines.Count -ge $Requested)
        }
    }
    if ($Lines.Count -gt 0 -and -not $CheckOnly) {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force $StateDir | Out-Null }
        $keep = [Math]::Min($Lines.Count, 30)
        [IO.File]::WriteAllLines($stateFile, [string[]]$Lines[($Lines.Count - $keep)..($Lines.Count - 1)], $enc)
    }
    return [pscustomobject]@{ New = @($new); Gap = $gap }
}

function Save-Lines([string]$Category, [string[]]$Lines, [string]$Source) {
    # Grava por dia: logs-pfsense\<Nome>\<categoria>\AAAA\MM\AAAA-MM-DD.log (acrescenta).
    $Lines = @($Lines)
    if ($Lines.Count -eq 0) { return }
    $now = Get-Date
    $byDay = @{}
    $last = $now
    foreach ($l in $Lines) {
        $d = Get-LineDate $l $now
        if ($d -gt $now.AddDays(1)) { $d = $last }   # data estranha: fica no dia da linha anterior
        $last = $d
        $key = $d.ToString('yyyy-MM-dd')
        if (-not $byDay.ContainsKey($key)) { $byDay[$key] = New-Object System.Collections.ArrayList }
        [void]$byDay[$key].Add($l)
    }
    $enc = New-Object Text.UTF8Encoding($false)
    foreach ($key in ($byDay.Keys | Sort-Object)) {
        $dir = Join-Path $LogRoot (Join-Path $Category (Join-Path $key.Substring(0, 4) $key.Substring(5, 2)))
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $text = (($byDay[$key] | ForEach-Object { $_ }) -join "`r`n") + "`r`n"
        [IO.File]::AppendAllText((Join-Path $dir "$key.log"), $text, $enc)
    }
    $script:Counts[$Source] = $Lines.Count
}

function Format-SyslogRow($Row) {
    # Tela padrao de logs: formatada (Hora, Processo, PID, Mensagem) ou bruta (Hora, Mensagem).
    $c = $Row.Cells
    if ($c.Count -ge 4) {
        $proc = $c[1]; if ($c[2]) { $proc = "$($c[1])[$($c[2])]" }
        return ("{0} {1}: {2}" -f $c[0], $proc, $c[3]).Trim()
    }
    if ($c.Count -ge 2) { return ("{0} {1}" -f $c[0], $c[1]).Trim() }
    return $null
}

function Format-FirewallRow($Row) {
    # Tela do firewall formatada: acao(icone), hora, interface, regra, origem, destino, protocolo.
    $c = $Row.Cells
    if ($c.Count -ge 7) {
        $act = ''
        $m = [regex]::Match($Row.Raw, 'title="([a-zA-Z-]+)/(\d*)"')
        if ($m.Success) { $act = $m.Groups[1].Value; if ($m.Groups[2].Value) { $act += " (regra $($m.Groups[2].Value))" } }
        return ("{0} | {1} | {2} | {3} | {4} -> {5} | {6}" -f $c[1], $act, $c[2], $c[3], $c[4], $c[5], $c[6])
    }
    if ($c.Count -ge 2) { return ("{0} {1}" -f $c[0], $c[1]).Trim() }
    return $null
}

function Get-OrderedLines([string[]]$Lines) {
    # A WebGUI pode mostrar do mais novo para o mais velho (opcao "reverse").
    # Normaliza para o mais velho primeiro, comparando a data da primeira e da ultima.
    $Lines = @($Lines | Where-Object { $_ })
    if ($Lines.Count -lt 2) { return , $Lines }
    $ref = Get-Date
    $a = Get-LineDate $Lines[0] $ref; $b = Get-LineDate $Lines[$Lines.Count - 1] $ref
    if ($a -gt $b) { [Array]::Reverse($Lines) }
    return , $Lines
}

function Add-VisitorRecords([string[]]$Lines) {
    # Portal cativo -> planilha mensal: visitantes\<Nome>\AAAA\acessos-AAAA-MM.csv
    # Ex.: "Nov 19 16:51:15 logportalauth[88909]: Zone: visitantes - ACCEPT: 52998224725 maria silva, aa:bb:..., 10.10.30.5"
    $now = Get-Date
    $enc = New-Object Text.UTF8Encoding($true)   # com BOM: o Excel abre os acentos certo
    $re = 'Zone:\s*(\S+)\s*-\s*([A-Za-z][A-Za-z \-]*?):\s*(.*?),\s*([0-9a-fA-F:]{17}|noclientmac),\s*(\d{1,3}(?:\.\d{1,3}){3})(.*)$'
    $n = 0
    foreach ($l in @($Lines)) {
        $m = [regex]::Match($l, $re)
        if (-not $m.Success) { continue }
        $d = Get-LineDate $l $now
        $usuario = $m.Groups[3].Value.Trim()
        $cpf = ''; $nome = $usuario
        $u = [regex]::Match($usuario, '^(\d{11})\s+(.+)$')
        if ($u.Success) { $cpf = $u.Groups[1].Value; $nome = $u.Groups[2].Value }
        $extra = ($m.Groups[6].Value -replace '^\s*,\s*', '').Trim()
        $campos = @($d.ToString('yyyy-MM-dd'), $d.ToString('HH:mm:ss'), $m.Groups[1].Value, $m.Groups[2].Value.Trim(),
                    $cpf, $nome, $m.Groups[4].Value.ToLower(), $m.Groups[5].Value, $extra) |
                  ForEach-Object { ([string]$_) -replace '[;\r\n]', ' ' }
        $dir = Join-Path $VisitDir $d.ToString('yyyy')
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $arq = Join-Path $dir ("acessos-" + $d.ToString('yyyy-MM') + '.csv')
        if (-not (Test-Path $arq)) { [IO.File]::WriteAllText($arq, "data;hora;zona;evento;cpf;nome;mac;ip;detalhe`r`n", $enc) }
        [IO.File]::AppendAllText($arq, (($campos -join ';') + "`r`n"), $enc)
        $n++
    }
    if ($n -gt 0) { $script:Counts['visitantes (planilha)'] = $n }
}

function Get-SyslogPath([string]$LogName) {
    # O pfSense confere o endereco EXATO de cada privilegio: "Logs: System" libera
    # so "status_logs.php" (sem parametro); os outros logs tem privilegio proprio
    # para "status_logs.php?logfile=<nome>". Por isso a quantidade de linhas vai
    # no corpo do POST, nunca na URL.
    if ($LogName -eq 'system') { return 'status_logs.php' }
    return "status_logs.php?logfile=$LogName"
}

function Collect-Syslog([string]$Source, [string]$LogName) {
    $path = Get-SyslogPath $LogName
    $p = Get-Page $path
    if (-not $p.Ok) { Add-Warning "$Source`: sem acesso ao log '$LogName' - falta o privilegio $($PrivName[$Source]) no grupo de logs."; return }
    $code = Send-Form $path @('filterlogentries_submit=1', "filterlogentries_qty=$lines")
    if ($code -ne '200') { Add-Warning "$Source`: o pfSense respondeu HTTP $code ao pedir $lines linhas."; return }
    $rows = Get-TableRows (Read-Text $TmpFile)
    $out = @(); foreach ($r in $rows) { $x = Format-SyslogRow $r; if ($x) { $out += $x } }
    $out = Get-OrderedLines $out
    $sel = Select-NewLines $out "syslog-$LogName" $lines $true
    if ($sel.Gap) { Add-Warning "$Source`: possivel lacuna (mais de $lines linhas desde a ultima coleta). Aumente LogLines ou rode mais vezes." }
    Save-Lines $CategoryDir[$Source] $sel.New $Source
    if ($Source -eq 'portal') { Add-VisitorRecords $sel.New }
}

function Collect-Firewall {
    $p = Get-Page "status_logs_filter.php?filterlogentries_submit=1&filterlogentries_qty=$lines"
    if (-not $p.Ok) { Add-Warning "firewall: sem acesso a Status > System Logs > Firewall - falta o privilegio."; return }
    $rows = Get-TableRows $p.Html
    $out = @(); foreach ($r in $rows) { $x = Format-FirewallRow $r; if ($x) { $out += $x } }
    $out = Get-OrderedLines $out
    $sel = Select-NewLines $out 'firewall' $lines $true
    if ($sel.Gap) { Add-Warning "firewall: possivel lacuna (mais de $lines linhas desde a ultima coleta). Aumente LogLines ou rode mais vezes." }
    Save-Lines 'firewall' $sel.New 'firewall'
}

function Collect-PfBlocker {
    $p = Get-Page 'pfblockerng/pfblockerng_log.php'
    if (-not $p.Ok) { Add-Warning 'pfblockerng: sem acesso (privilegio "WebCfg - Firewall: pfBlockerNG") ou pacote nao instalado.'; return }
    $logdir = '/var/log/pfblockerng'
    $m = [regex]::Match($p.Html, '(/var/log/pfblockerng)/[A-Za-z_]+\.log')
    if ($m.Success) { $logdir = $m.Groups[1].Value }
    foreach ($f in $PfbFiles) {
        $code = Send-Form 'pfblockerng/pfblockerng_log.php' @("logFile=$logdir/$f", 'download=Download')
        $txt = Read-Text $TmpFile
        if ($code -ne '200' -or $txt -match '(?i)<html|Invalid filename' -or -not $txt) { continue }   # arquivo nao existe/vazio
        $all = @($txt -split "`r?`n" | Where-Object { $_ })
        $base_ = $f -replace '\.log$', ''
        $sel = Select-NewLines $all "pfb-$base_" 0 $false
        Save-Lines (Join-Path 'pfblockerng' $base_) $sel.New "pfblockerng/$base_"
    }
}

function Collect-Suricata {
    $p = Get-Page 'suricata/suricata_logs_browser.php'
    if (-not $p.Ok) { Add-Warning 'suricata: sem acesso (privilegio "WebCfg - Services: suricata package.") ou pacote nao instalado.'; return }
    $sel_ = [regex]::Match($p.Html, '(?is)<select[^>]*name="instance"[^>]*>(.*?)</select>')
    $inst = @()
    if ($sel_.Success) {
        foreach ($o in [regex]::Matches($sel_.Groups[1].Value, '(?is)<option[^>]*value="(\d+)"[^>]*>(.*?)</option>')) {
            $inst += [pscustomobject]@{ Id = $o.Groups[1].Value; Nome = (ConvertFrom-HtmlCell $o.Groups[2].Value) }
        }
    }
    if ($inst.Count -eq 0) { $inst = @([pscustomobject]@{ Id = '0'; Nome = 'interface0' }) }
    foreach ($i in $inst) {
        $pasta = ($i.Nome -replace '[^A-Za-z0-9_.-]+', '_').Trim('_')
        if (-not $pasta) { $pasta = "interface$($i.Id)" }
        foreach ($f in $SuricataFiles) {
            $code = Send-Form 'suricata/suricata_logs_browser.php' @('action=load', "file=$f", "instance=$($i.Id)")
            $resp = Read-Text $TmpFile
            $m = [regex]::Match($resp, '^\|0\|[^|]*\|([A-Za-z0-9+/=\s]*)\|')
            if ($code -ne '200' -or -not $m.Success) { continue }   # |3| = arquivo nao existe
            $txt = ''
            if ($m.Groups[1].Value) { $txt = (New-Object Text.UTF8Encoding($false)).GetString([Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))) }
            $all = @($txt -split "`r?`n" | Where-Object { $_ })
            $base_ = $f -replace '\.log$', ''
            $sel = Select-NewLines $all "suricata-$($i.Id)-$base_" 0 $false
            Save-Lines (Join-Path 'suricata' "$pasta-$base_") $sel.New "suricata/$pasta-$base_"
        }
    }
}

function Collect-SquidMonitor([string]$Source, [string]$Program) {
    # Tela "Squid Proxy Monitor": devolve as ultimas N linhas, da mais nova para a mais velha.
    $p = Get-Page 'squid_monitor.php'
    if (-not $p.Ok) { Add-Warning "$Source`: sem acesso (privilegio ""WebCfg - Services: Squid package"") ou pacote nao instalado."; return }
    $code = Send-Form 'squid_monitor_data.php' @("program=$Program", "maxlines=$lines", 'strfilter=')
    if ($code -ne '200') { Add-Warning "$Source`: a tela de monitoramento respondeu HTTP $code."; return }
    $rows = Get-TableRows (Read-Text $TmpFile)
    $out = @(); foreach ($r in $rows) { $out += ($r.Cells -join ' | ') }
    [Array]::Reverse($out)
    $sel = Select-NewLines $out "squid-$Program" $lines $true
    if ($sel.Gap) { Add-Warning "$Source`: possivel lacuna (mais de $lines linhas desde a ultima coleta)." }
    Save-Lines $CategoryDir[$Source] $sel.New $Source
}

function Collect-DhcpLeases {
    # Foto das concessoes DHCP: guarda no CSV do dia cada combinacao nova (IP, MAC, nome, inicio).
    $p = Get-Page 'status_dhcp_leases.php?all=1'
    if (-not $p.Ok) { Add-Warning 'dhcp-concessoes: sem acesso a Status > DHCP Leases (privilegio "WebCfg - Status: DHCP leases").'; return }
    $tab = $null
    foreach ($t in [regex]::Matches($p.Html, '(?is)<table\b.*?</table>')) { if ($t.Value -match '(?i)<th[^>]*>\s*(IP address|Endere)') { $tab = $t.Value } }
    if (-not $tab) { return }
    $heads = @(); foreach ($h in [regex]::Matches($tab, '(?is)<th\b[^>]*>(.*?)</th>')) { $heads += (ConvertFrom-HtmlCell $h.Groups[1].Value) }
    $rows = Get-TableRows $tab
    $now = Get-Date
    $dir = Join-Path $LogRoot (Join-Path 'dhcp-concessoes' (Join-Path $now.ToString('yyyy') $now.ToString('MM')))
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $arq = Join-Path $dir ($now.ToString('yyyy-MM-dd') + '.csv')
    $enc = New-Object Text.UTF8Encoding($true)
    $idx = @(); for ($i = 0; $i -lt $heads.Count; $i++) { if ($heads[$i] -and $heads[$i] -notmatch '(?i)^actions?$|^a..es$') { $idx += $i } }
    # Cada linha do CSV: hora da coleta + colunas da tela. A mesma concessao (mesmas
    # colunas) so entra uma vez por dia; a hora mostra quando ela foi vista primeiro.
    $vistos = @{}
    if (Test-Path $arq) {
        foreach ($l in [IO.File]::ReadAllLines($arq, $enc)) { $p_ = $l.IndexOf(';'); if ($p_ -ge 0) { $vistos[$l.Substring($p_ + 1)] = 1 } }
    } else {
        [IO.File]::WriteAllText($arq, ((@('coletado') + @($idx | ForEach-Object { $heads[$_] })) -join ';') + "`r`n", $enc)
    }
    $n = 0
    foreach ($r in $rows) {
        if ($r.Cells.Count -lt $heads.Count - 1) { continue }
        $vals = @($idx | ForEach-Object { if ($_ -lt $r.Cells.Count) { ($r.Cells[$_] -replace '[;\r\n]', ' ') } else { '' } })
        $chave = ($vals -join ';')
        if ($vistos.ContainsKey($chave)) { continue }
        [IO.File]::AppendAllText($arq, ($now.ToString('HH:mm') + ';' + $chave + "`r`n"), $enc)
        $vistos[$chave] = 1; $n++
    }
    if ($n -gt 0) { $script:Counts['dhcp-concessoes'] = $n }
}

function Collect-LightSquid {
    # LightSquid: servidor web proprio do pacote (porta 7445 por padrao), com
    # usuario e senha proprios. Guarda a pagina de cada dia que existir; os dias
    # passados so sao baixados uma vez, os 2 ultimos sao atualizados sempre.
    $url = ([string]$cfg.LightSquidUrl).TrimEnd('/')
    $lsTls = @('-sk', '--connect-timeout', "$timeout", '--max-time', "$maxTime")
    $sec = @()
    if ($cfg.LightSquidUser -and (Test-Path $LsFile)) {
        $sec = @(ConvertTo-CurlConfig 'user' ("{0}:{1}" -f $cfg.LightSquidUser, (Read-Secret $LsFile $key)))
    }
    if ($url -like 'http:*') { Write-Log 'AVISO: LightSquid sem HTTPS - a senha dele trafega aberta na rede. Ligue o SSL no pacote LightSquid.' }
    $code = Invoke-Web @("$url/index.cgi") $sec $lsTls
    if ($code -eq '401') { Add-Warning 'lightsquid: usuario/senha do LightSquid recusados (rode o instalador com -UpdateLightSquidPassword).'; return }
    if ($code -ne '200') { Add-Warning "lightsquid: $url respondeu HTTP $code."; return }
    $anos = @{}
    foreach ($m in [regex]::Matches((Read-Text $TmpFile), 'index\.cgi\?year=(\d{4})')) { $anos[$m.Groups[1].Value] = 1 }
    $hoje = Get-Date; $n = 0
    foreach ($ano in ($anos.Keys | Sort-Object)) {
        $code = Invoke-Web @("$url/index.cgi?year=$ano&month=all") $sec $lsTls
        if ($code -ne '200') { continue }
        $meses = @{}
        foreach ($m in [regex]::Matches((Read-Text $TmpFile), "index\.cgi\?year=$ano(?:&amp;|&)month=(\d\d)")) { $meses[$m.Groups[1].Value] = 1 }
        foreach ($mes in ($meses.Keys | Sort-Object)) {
            $pastaMes = Join-Path $LsRoot (Join-Path $ano $mes)
            $recente = ([int]$ano * 12 + [int]$mes) -ge ($hoje.Year * 12 + $hoje.Month - 1)
            if ((Test-Path $pastaMes) -and -not $recente) { continue }   # mes antigo ja guardado
            $code = Invoke-Web @("$url/index.cgi?year=$ano&month=$mes") $sec $lsTls
            if ($code -ne '200') { continue }
            $idxHtml = Read-Text $TmpFile
            $dias = @{}
            foreach ($m in [regex]::Matches($idxHtml, 'day_detail\.cgi\?([^"''>\s]+)')) {
                $q = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
                $dm = [regex]::Match($q, 'day=(\d\d?)')
                if ($dm.Success) { $dias[('{0:D2}' -f [int]$dm.Groups[1].Value)] = $q }
            }
            if (-not (Test-Path $pastaMes)) { New-Item -ItemType Directory -Force $pastaMes | Out-Null }
            $enc = New-Object Text.UTF8Encoding($false)
            $baseTag = "<base href=""$url/"">"
            [IO.File]::WriteAllText((Join-Path $pastaMes 'indice-do-mes.html'), ($idxHtml -replace '(?i)<head>', "<head>$baseTag"), $enc)
            foreach ($dia in ($dias.Keys | Sort-Object)) {
                $arq = Join-Path $pastaMes "$ano-$mes-$dia.html"
                $dt = New-Object DateTime ([int]$ano), ([int]$mes), ([int]$dia)
                if ((Test-Path $arq) -and $dt -lt $hoje.Date.AddDays(-1)) { continue }
                $code = Invoke-Web @("$url/day_detail.cgi?$($dias[$dia])") $sec $lsTls
                if ($code -ne '200') { continue }
                [IO.File]::WriteAllText($arq, ((Read-Text $TmpFile) -replace '(?i)<head>', "<head>$baseTag"), $enc)
                $n++
            }
        }
    }
    if ($n -gt 0) { $script:Counts['lightsquid (dias)'] = $n }
}

function Test-Access {
    # Modo -CheckOnly: confere cada fonte pedida e que o usuario nao e administrador.
    $faltam = @()
    foreach ($s in $sources) {
        $path = $null
        if ($SyslogSources.Contains($s)) { $path = Get-SyslogPath $SyslogSources[$s] }
        elseif ($s -eq 'firewall')        { $path = 'status_logs_filter.php' }
        elseif ($s -eq 'pfblockerng')     { $path = 'pfblockerng/pfblockerng_log.php' }
        elseif ($s -eq 'suricata')        { $path = 'suricata/suricata_logs_browser.php' }
        elseif ($s -in @('squid', 'squidguard')) { $path = 'squid_monitor.php' }
        elseif ($s -eq 'dhcp-concessoes') { $path = 'status_dhcp_leases.php' }
        if (-not $path) { continue }
        $p = Get-Page $path
        if ($p.Ok) { Write-Log "  OK      $s" } else { Write-Log "  FALTA   $s  -> inclua no grupo: $($PrivName[$s])"; $faltam += $s }
    }
    $extra = @()
    foreach ($pg in $ForbiddenPages) {
        $p = Get-Page $pg
        if ($p.Ok) { $extra += $pg }
    }
    if ($extra.Count -gt 0) {
        Stop-Permanent "o usuario '$($cfg.User)' tem privilegio DEMAIS (acessa: $($extra -join ', ')). Ele nao pode ser admin: deixe-o so nos grupos de backup e de logs."
    }
    return , $faltam
}

function Remove-OldLogs {
    # Retencao: apaga arquivos mais velhos que LogKeepDays e pastas que ficaram vazias.
    $limite = (Get-Date).AddDays(-$keepDays)
    foreach ($raiz in @($LogRoot, $VisitDir, $LsRoot)) {
        if (-not (Test-Path $raiz)) { continue }
        Get-ChildItem $raiz -Recurse -File | Where-Object { $_.LastWriteTime -lt $limite } |
            ForEach-Object { Remove-Item $_.FullName -Force }
        Get-ChildItem $raiz -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem $_.FullName -Force) } | ForEach-Object { Remove-Item $_.FullName -Force }
    }
}

function Invoke-LogCollection {
    Connect-PfSense
    try {
        if ($CheckOnly) { return (Test-Access) }
        foreach ($s in $sources) {
            try {
                if ($SyslogSources.Contains($s))     { Collect-Syslog $s $SyslogSources[$s] }
                elseif ($s -eq 'firewall')           { Collect-Firewall }
                elseif ($s -eq 'pfblockerng')        { Collect-PfBlocker }
                elseif ($s -eq 'suricata')           { Collect-Suricata }
                elseif ($s -eq 'squid')              { Collect-SquidMonitor 'squid' 'squid' }
                elseif ($s -eq 'squidguard')         { Collect-SquidMonitor 'squidguard' 'sguard' }
                elseif ($s -eq 'dhcp-concessoes')    { Collect-DhcpLeases }
                else { Add-Warning "fonte desconhecida no perfil: '$s'." }
            } catch {
                if ($script:NoRetry) { throw }
                Add-Warning "$s`: $($_.Exception.Message)"
            }
        }
    } finally { Disconnect-PfSense }
    if ($cfg.LightSquidUrl) {
        try { Collect-LightSquid } catch {
            if ($script:NoRetry) { throw }
            Add-Warning "lightsquid: $($_.Exception.Message)"
        }
    }
    return $null
}

# ------------------------------- main ---------------------------------
# So roda o main quando executado como script (os testes carregam as funcoes sem rodar isto).
if ($MyInvocation.InvocationName -eq '.' -or $env:PFSENSE_BACKUP_NO_MAIN) { return }

$exitCode = 0
$pass = $null
$mutex = $null
try {
    foreach ($d in @($LogDir, $StateDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) { Move-Item $LogFile "$LogFile.old" -Force }

    # Uma coleta por vez para o mesmo firewall (a tarefa roda de hora em hora).
    $mutex = New-Object Threading.Mutex($false, "Global\pfSenseLogs_$Name")
    if (-not $mutex.WaitOne(0)) { Write-Log 'outra coleta deste firewall ainda esta rodando - saindo.'; $mutex = $null; exit 0 }

    if (-not (Test-Path $CfgFile))  { throw "perfil nao encontrado: $CfgFile (rode o Install-pfSenseBackup.ps1)." }
    if (-not (Test-Path $KeyFile))  { throw "chave nao encontrada: $KeyFile (rode o Install-pfSenseBackup.ps1)." }
    if (-not (Test-Path $PassFile)) { throw "senha nao encontrada: $PassFile (rode o Install-pfSenseBackup.ps1 -UpdatePassword)." }

    $cfg = Get-Content $CfgFile -Raw | ConvertFrom-Json
    if (-not $CheckOnly -and $cfg.Logs -ne $true) { Write-Log 'coleta de logs desligada neste perfil (Logs=false) - nada a fazer.'; exit 0 }

    $port     = if ($cfg.Port)           { [int]$cfg.Port }           else { 443 }
    $timeout  = if ($cfg.ConnectTimeout) { [int]$cfg.ConnectTimeout } else { 15 }
    $maxTime  = if ($cfg.LogMaxTime)     { [int]$cfg.LogMaxTime }     else { 600 }
    $lines    = if ($cfg.LogLines)       { [int]$cfg.LogLines }       else { 5000 }
    $keepDays = if ($cfg.LogKeepDays)    { [int]$cfg.LogKeepDays }    else { 400 }
    $sources  = $DefaultSources
    if ($cfg.LogSources) { $sources = @(([string]$cfg.LogSources) -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() }) }

    $script:Curl = if ($cfg.CurlPath) { [string]$cfg.CurlPath } else { Join-Path $env:SystemRoot 'System32\curl.exe' }
    if (-not $cfg.CurlPath -and -not (Test-Path $script:Curl)) { $script:Curl = Join-Path $BaseDir 'bin\curl.exe' }
    if (-not (Test-Path $script:Curl)) { throw "curl.exe nao encontrado em $($script:Curl)." }
    if (-not $cfg.Host) { throw "campo 'Host' vazio em $CfgFile." }

    $script:Tls = @('-sk', '--connect-timeout', "$timeout", '--max-time', "$maxTime")
    if ($cfg.PubKeyPin) { $script:Tls += @('--pinnedpubkey', [string]$cfg.PubKeyPin) }
    else { Write-Log 'AVISO: perfil sem PubKeyPin - a identidade do pfSense NAO e verificada.' }

    $key  = [byte[]](Get-Content $KeyFile -Encoding Byte)
    $pass = Read-Secret $PassFile $key
    $base = "https://$($cfg.Host):$port"
    Write-Log "Iniciando $(if ($CheckOnly) { 'verificacao dos logs' } else { 'coleta de logs' }) - $base - usuario '$($cfg.User)' - fontes: $($sources -join ', ')"

    $faltam = Invoke-LogCollection
    $pass = $null

    if ($CheckOnly) {
        if (@($faltam).Count -gt 0) {
            Write-Log ("CHECK com pendencias: sem acesso a " + (@($faltam) -join ', ') + ". Inclua os privilegios no grupo de logs ou tire essas fontes do perfil.")
            exit 2
        }
        Write-Log 'CHECK OK: login OK, acesso a todas as fontes pedidas, sem privilegios administrativos.'
    } else {
        Remove-OldLogs
        $resumo = if ($script:Counts.Count -gt 0) { ($script:Counts.Keys | ForEach-Object { "$_=$($script:Counts[$_])" }) -join ', ' } else { 'nenhuma linha nova' }
        if ($script:Warnings.Count -gt 0) {
            $msg = "Logs coletados com AVISO ($resumo): " + ($script:Warnings -join ' | ')
            Write-Log $msg; Write-Event 1012 'Warning' $msg; Write-Status 'AVISO' $msg
        } else {
            $msg = "Logs coletados: $resumo"
            Write-Log $msg; Write-Event 1010 'Information' $msg; Write-Status 'OK' $msg
        }
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Log "ERRO: $msg"
    if (-not $CheckOnly) {
        Write-Event 1011 'Error' "Coleta de logs FALHOU: $msg"
        Write-Status 'ERRO' "Coleta de logs FALHOU: $msg"
    }
    $exitCode = 1
}
finally {
    $pass = $null
    Remove-Item $CookieJar, $TmpFile -Force -ErrorAction SilentlyContinue
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}
exit $exitCode
