<#
.SYNOPSIS
    Baixa o config.xml de um pfSense pela WebGUI e guarda com data/hora.

.DESCRIPTION
    Motor de backup generico, multi-cliente. Cada firewall e um "perfil",
    identificado por um nome curto (ex.: FWMATRIZ, FWFILIAL). Os dados do perfil
    ficam em:

        <BaseDir>\config\<Nome>.json     configuracao (host, porta, usuario...)
        <BaseDir>\secrets\<Nome>.key     chave AES de 32 bytes
        <BaseDir>\secrets\<Nome>.pass    senha do pfSense cifrada com a chave
        <BaseDir>\secrets\<Nome>.encpass (opcional) senha de criptografia do backup
        <BaseDir>\backups\<Nome>\        backups gerados
        <BaseDir>\logs\<Nome>\<Nome>.log log de execucao (uma pasta por firewall)
        <BaseDir>\status\<Nome>\         3 arquivos para o Zabbix (ver abaixo)

    Arquivos de status (um valor por arquivo, sem quebra de linha - faceis de
    ler com vfs.file.contents no agente Zabbix):
        status.txt     OK | AVISO | ERRO   (AVISO = backup OK, mas a copia externa falhou)
        ultimo-ok.txt  segundos desde 1970 (UTC) do ultimo backup bom
        mensagem.txt   data + ultima mensagem (motivo do erro, arquivo gerado...)

    O perfil e criado pelo Install-pfSenseBackup.ps1. Este script so le.

    Fluxo: abre a tela de login (token CSRF) -> loga -> abre diag_backup.php
    (segundo token) -> pede o download -> sai da sessao -> valida o arquivo ->
    apaga antigos -> (opcional) copia para fora do servidor.

    Seguranca do transporte: todas as chamadas do curl usam --pinnedpubkey com
    a chave do certificado da WebGUI gravada no cadastro (PubKeyPin). Se outro
    equipamento responder no lugar do pfSense, o curl recusa ANTES de enviar a
    senha. As senhas vao para o curl por stdin (-K -), nunca na linha de comando.

    Falhas de rede/timeout sao repetidas (Retries/RetryDelay no JSON). Erros que
    nao adianta repetir (senha, privilegio, certificado trocado) param na hora -
    repetir login errado ainda faria o sshguard do pfSense bloquear o servidor.

    Codigo de saida: 0 = OK, 1 = erro. Eventos no Log de Aplicativo do
    Windows (origem "pfSense-Backup"): ID 1000 = sucesso, 1001 = erro,
    1002 = backup OK mas a copia externa (CopyTo) falhou.

.PARAMETER Name
    Nome do perfil (o mesmo usado no Install-pfSenseBackup.ps1).

.PARAMETER BaseDir
    Pasta raiz da instalacao. Padrao: a pasta onde este script esta. A tarefa
    agendada e o instalador sempre informam -BaseDir explicitamente.

.PARAMETER CheckOnly
    Nao baixa nada. So confere se o usuario do pfSense esta configurado
    do jeito certo: loga, acessa a pagina de backup e garante que ele NAO
    acessa paginas administrativas (privilegio demais = reprovado).
    Usado pelo instalador antes de criar a tarefa agendada.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\pfSense-Backup\Backup-pfSense.ps1 -Name FWCLIENTE

.NOTES
    Requer Windows PowerShell 4.0 a 5.1 (NAO o pwsh 7: usa -Encoding Byte) e curl.exe (nativo no Windows 10 1803+ /
    Server 2019+; em versoes antigas informe "CurlPath" no JSON do perfil).
    Arquivo mantido em ASCII puro de proposito (PowerShell 5.1 le .ps1 sem BOM
    como ANSI e quebraria acentos).
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
# Pasta do proprio script. NAO usar $PSScriptRoot como padrao no param(): em alguns
# Windows PowerShell (visto no Server 2016) ele chega VAZIO ali dentro e o primeiro
# Join-Path quebra com "cadeia de caracteres vazia".
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
# O que o PowerShell manda por pipe para o curl (config com as senhas, -K -) sai em
# UTF-8 sem BOM. O padrao do PS 5.1 e ASCII e trocaria acentos da senha por '?'.
$OutputEncoding = New-Object Text.UTF8Encoding($false)

# Paginas que o usuario de backup NAO pode acessar (teste de "privilegio demais").
# Se qualquer uma responder 200, o usuario tem mais permissao do que deveria.
$ForbiddenPages = @('system_usermanager.php', 'firewall_rules.php', 'diag_command.php')

# ------------------------- caminhos do perfil -------------------------
$CfgFile   = Join-Path $BaseDir "config\$Name.json"
$SecDir    = Join-Path $BaseDir 'secrets'
$KeyFile   = Join-Path $SecDir  "$Name.key"
$PassFile  = Join-Path $SecDir  "$Name.pass"
$EncFile   = Join-Path $SecDir  "$Name.encpass"
$BkDir     = Join-Path $BaseDir "backups\$Name"
$LogDir    = Join-Path $BaseDir "logs\$Name"
$LogFile   = Join-Path $LogDir  "$Name.log"
$LogAntigo = Join-Path $BaseDir "logs\$Name.log"   # versoes antigas: log solto em logs\
$StatusDir = Join-Path $BaseDir "status\$Name"
$CookieJar = Join-Path $SecDir  ("cookies_" + [guid]::NewGuid().ToString('N') + '.tmp')

$script:NoRetry = $false

# ------------------------------ funcoes -------------------------------
function Write-Log([string]$Message) {
    $line = "$((Get-Date).ToString('s'))  [$Name]  $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Write-Event([int]$Id, [string]$Type, [string]$Message) {
    # Nao pode derrubar o backup se a origem do evento nao existir.
    try {
        if ([Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-EventLog -LogName Application -Source $EventSource -EventId $Id `
                -EntryType $Type -Message "[$Name] $Message" -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-Status([string]$Status, [string]$Message) {
    # Os 3 arquivos que o Zabbix le. Gravados sem quebra de linha e em ASCII para
    # o vfs.file.contents devolver exatamente "OK", "ERRO"... Nunca derruba o backup.
    try {
        if (-not (Test-Path $StatusDir)) { New-Item -ItemType Directory -Force $StatusDir | Out-Null }
        $ascii = New-Object Text.ASCIIEncoding
        [IO.File]::WriteAllText((Join-Path $StatusDir 'status.txt'), $Status, $ascii)
        [IO.File]::WriteAllText((Join-Path $StatusDir 'mensagem.txt'), "$((Get-Date).ToString('s'))  $Message", $ascii)
        if ($Status -ne 'ERRO') {
            $epoch = [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
            [IO.File]::WriteAllText((Join-Path $StatusDir 'ultimo-ok.txt'), "$epoch", $ascii)
        }
    } catch {}
}

function Stop-Permanent([string]$Message) {
    # Erro que nao adianta repetir (senha, privilegio, certificado): sai sem nova
    # tentativa. Repetir login errado faria o sshguard bloquear o IP do servidor.
    $script:NoRetry = $true
    throw $Message
}

function Get-Csrf([string]$Html) {
    $m = [regex]::Match($Html, 'value="(sid:[^"]+)"')
    if (-not $m.Success) { $m = [regex]::Match($Html, "value='(sid:[^']+)'") }
    return $m.Groups[1].Value
}

function Read-Secret([string]$File, [byte[]]$Key) {
    $sec  = Get-Content $File | ConvertTo-SecureString -Key $Key
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertTo-CurlConfig([string]$Option, [string]$Value) {
    # Uma linha de config do curl (-K). Entre aspas o curl so interpreta escapes
    # com barra invertida, entao basta escapar a propria barra e as aspas.
    return ('{0} = "{1}"' -f $Option, ($Value -replace '\\', '\\' -replace '"', '\"'))
}

function Invoke-Curl([string[]]$CurlArgs, [string[]]$Secrets = @()) {
    # Segredos vao por stdin como config do curl (-K -), nunca como argumento:
    # nao aparecem na lista de processos e nao passam pelo bug do PS 5.1 que
    # corrompe argumentos com aspas (") ao chamar um .exe nativo.
    # $script:Tls (-k, timeouts, --pinnedpubkey) entra em TODAS as chamadas.
    $all = @($script:Tls) + @($CurlArgs)
    if ($Secrets.Count -gt 0) {
        $out = ($Secrets -join "`n") | & $script:Curl -K - @all
    } else {
        $out = & $script:Curl @all
    }
    $rc = $LASTEXITCODE
    if ($rc -eq 90) {
        Stop-Permanent ("a chave do certificado do pfSense NAO confere com a do cadastro (curl exit 90). " +
            "Ou o certificado da WebGUI foi trocado, ou outro equipamento esta respondendo no lugar do firewall. " +
            "A senha NAO foi enviada. Confira e, se a troca for legitima, rode o instalador com -TrustNewCert.")
    }
    if ($rc -ne 0) { throw "curl falhou (exit $rc) em: $($CurlArgs[-1])" }
    return ($out -join "`n")
}

function Invoke-Logout([string]$Token) {
    # Encerra a sessao no pfSense; senao cada execucao deixa uma sessao aberta ate
    # expirar. Melhor esforco: falhar aqui nao invalida o backup nem muda a
    # decisao de repetir a tentativa.
    $noRetry = $script:NoRetry
    try {
        Invoke-Curl @('-b', $CookieJar, '-o', 'NUL',
            '--data-urlencode', "__csrf_magic=$Token",
            '--data-urlencode', 'logout=',
            "$base/index.php?logout") | Out-Null
    } catch {}
    $script:NoRetry = $noRetry
}

function Remove-OldBackups([string]$Dir) {
    # Apaga mais velhos que KeepDays, mas sempre preserva os MinKeep mais recentes.
    Get-ChildItem $Dir -Filter "config-$Name-*" | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $minKeep |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$keepDays) } |
        ForEach-Object { Remove-Item $_.FullName -Force; Write-Log "removido antigo: $($_.FullName)" }
}

# Uma tentativa completa: login -> (check | download) -> logout -> validacao.
# Devolve o resultado do download, ou $null no modo -CheckOnly.
function Invoke-Backup {
    # 1) token CSRF da tela de login
    $loginPage = Invoke-Curl @('-c', $CookieJar, "$base/index.php")
    $tok = Get-Csrf $loginPage
    if (-not $tok) { throw "nao achei o token CSRF na tela de login (e mesmo um pfSense em $base?)." }

    # 2) login (senha por stdin)
    Invoke-Curl @('-b', $CookieJar, '-c', $CookieJar, '-o', 'NUL',
        '--data-urlencode', "__csrf_magic=$tok",
        '--data-urlencode', "usernamefld=$($cfg.User)",
        '--data-urlencode', 'login=Sign In',
        "$base/index.php") @(ConvertTo-CurlConfig 'data-urlencode' "passwordfld=$pass") | Out-Null

    # 3) tela de backup: segundo token + confirma login e privilegio
    #    login recusado   -> 200 com o formulario de login
    #    sem privilegio   -> 302 (pfSense redireciona p/ a primeira pagina permitida)
    $resp  = Invoke-Curl @('-b', $CookieJar, '-c', $CookieJar, '-w', "`n%{http_code}", "$base/diag_backup.php")
    $code  = ($resp -split "`n")[-1].Trim()
    $bpage = $resp
    if ($bpage -match 'id="usernamefld"' -or $bpage -match 'Enter username and password') {
        Stop-Permanent "login recusado: usuario/senha errados ou usuario desativado. Confira o usuario '$($cfg.User)' no pfSense e rode o instalador com -UpdatePassword."
    }
    if ($code -match '^30') {
        Stop-Permanent "o usuario '$($cfg.User)' logou mas NAO tem acesso a pagina de backup. Coloque-o no grupo de backup (padrao BACKUP-PFSENSE) com o privilegio 'WebCfg - Diagnostics: Backup & Restore' (Auto Config Backup NAO serve)."
    }
    $tok2 = Get-Csrf $bpage
    if (-not $tok2) { throw "logou, mas nao achei o token na tela de backup (HTTP $code)." }

    # 3b) modo verificacao: confere que o usuario NAO tem privilegio demais
    if ($CheckOnly) {
        try {
            $extra = @()
            foreach ($pg in $ForbiddenPages) {
                $c = (Invoke-Curl @('-b', $CookieJar, '-o', 'NUL', '-w', '%{http_code}', "$base/$pg")).Trim()
                if ($c -eq '200') { $extra += $pg }
            }
            if ($extra.Count -gt 0) {
                Stop-Permanent "o usuario '$($cfg.User)' tem privilegio DEMAIS (acessa: $($extra -join ', ')). Ele deve estar SO no grupo de backup, com SO 'WebCfg - Diagnostics: Backup & Restore' - nunca admin/admins."
            }
        } finally { Invoke-Logout $tok2 }
        return $null
    }

    # 4) download do config.xml (senha de criptografia, se houver, por stdin)
    $ts  = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $ext = if ($encrypt) { 'xml.enc' } else { 'xml' }
    $out = Join-Path $BkDir "config-$Name-$ts.$ext"

    $dl = @('-b', $CookieJar,
        '--data-urlencode', "__csrf_magic=$tok2",
        '--data-urlencode', 'backuparea=',
        '--data-urlencode', ('donotbackuprrd=' + $(if ($includeRRD) { '' } else { 'yes' })),
        '--data-urlencode', 'download=Download configuration as XML')
    $sec = @()
    if ($encrypt) {
        # pfSense 2.4+: campos encrypt_password + encrypt_password_confirm
        $dl  += @('--data-urlencode', 'encrypt=yes')
        $sec  = @((ConvertTo-CurlConfig 'data-urlencode' "encrypt_password=$encPwd"),
                  (ConvertTo-CurlConfig 'data-urlencode' "encrypt_password_confirm=$encPwd"))
    }
    $dl += @('-o', $out, "$base/diag_backup.php")
    try     { Invoke-Curl $dl $sec | Out-Null }
    finally { Invoke-Logout $tok2 }

    # 5) validacao do arquivo
    if (-not (Test-Path $out)) { throw 'o arquivo de backup nao foi criado.' }
    $size = (Get-Item $out).Length
    $head = (Get-Content $out -TotalCount 1 -ErrorAction SilentlyContinue)
    try {
        if ($size -lt 2KB) { throw "arquivo pequeno demais ($size bytes). Inicio: $head" }
        if ($encrypt) {
            if ($head -notmatch 'BEGIN config\.xml') { throw "nao parece backup criptografado do pfSense. Inicio: $head" }
        } else {
            $xml = New-Object Xml.XmlDocument
            try { $xml.Load($out) } catch { throw "XML invalido/incompleto ($($_.Exception.Message)). Inicio: $head" }
            if ($xml.DocumentElement.Name -ne 'pfsense') { throw "XML nao e um config do pfSense (raiz <$($xml.DocumentElement.Name)>)." }
        }
    } catch {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        throw
    }

    # Compara com o backup anterior (so informativo). Nao vale para backup
    # criptografado: o pfSense usa um sal aleatorio a cada download, entao dois
    # .xml.enc da mesma configuracao nunca sao iguais.
    $note = ''
    if (-not $encrypt) {
        $prev = Get-ChildItem $BkDir -Filter "config-$Name-*" |
                Where-Object { $_.FullName -ne $out } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($prev -and (Get-FileHash $prev.FullName).Hash -eq (Get-FileHash $out).Hash) {
            $note = ' (identico ao anterior)'
        }
    }
    return [pscustomobject]@{ File = $out; Size = $size; Note = $note }
}

# ------------------------------- main ---------------------------------
$exitCode = 0
$pass = $null; $encPwd = $null
try {
    foreach ($d in @($BkDir, $LogDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    }
    # Instalacao antiga: o log ficava solto em logs\<Nome>.log. Move para a pasta
    # do firewall (logs\<Nome>\) sem perder o historico.
    if ((Test-Path $LogAntigo) -and -not (Test-Path $LogFile)) { Move-Item $LogAntigo $LogFile }
    if (Test-Path "$LogAntigo.old") { Move-Item "$LogAntigo.old" "$LogFile.old" -Force }

    # Rotacao simples do log (> 5 MB vira .old)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
        Move-Item $LogFile "$LogFile.old" -Force
    }

    if (-not (Test-Path $CfgFile))  { throw "perfil nao encontrado: $CfgFile (rode o Install-pfSenseBackup.ps1)." }
    if (-not (Test-Path $KeyFile))  { throw "chave nao encontrada: $KeyFile (rode o Install-pfSenseBackup.ps1)." }
    if (-not (Test-Path $PassFile)) { throw "senha nao encontrada: $PassFile (rode o Install-pfSenseBackup.ps1 -UpdatePassword)." }

    $cfg = Get-Content $CfgFile -Raw | ConvertFrom-Json

    # Valores padrao para campos opcionais (perfis antigos nao tem os novos)
    $port       = if ($cfg.Port)           { [int]$cfg.Port }           else { 443 }
    $keepDays   = if ($cfg.KeepDays)       { [int]$cfg.KeepDays }       else { 90 }
    $minKeep    = if ($cfg.MinKeep)        { [int]$cfg.MinKeep }        else { 10 }
    $timeout    = if ($cfg.ConnectTimeout) { [int]$cfg.ConnectTimeout } else { 15 }
    $maxTime    = if ($cfg.MaxTime)        { [int]$cfg.MaxTime }        else { 300 }
    $retries    = if ($cfg.Retries)        { [int]$cfg.Retries }        else { 3 }
    $retryDelay = if ($cfg.RetryDelay)     { [int]$cfg.RetryDelay }     else { 60 }
    $includeRRD = [bool]$cfg.IncludeRRD
    $encrypt    = [bool]$cfg.Encrypt
    # curl: o do JSON; senao o do Windows (10 1803+ / Server 2019+); senao o
    # <BaseDir>\bin\curl.exe (Server 2016/2012 R2, que nao trazem o curl).
    $script:Curl = if ($cfg.CurlPath) { [string]$cfg.CurlPath } else { Join-Path $env:SystemRoot 'System32\curl.exe' }
    if (-not $cfg.CurlPath -and -not (Test-Path $script:Curl)) { $script:Curl = Join-Path $BaseDir 'bin\curl.exe' }
    if ($CheckOnly) { $retries = 1 }   # o instalador quer a resposta na hora

    if (-not $cfg.Host) { throw "campo 'Host' vazio em $CfgFile." }
    if (-not $cfg.User) { throw "campo 'User' vazio em $CfgFile." }
    if (-not (Test-Path $script:Curl)) { throw "curl.exe nao encontrado em $($script:Curl). No Server 2016 e anteriores, copie o curl oficial (https://curl.se/windows/) para $(Join-Path $BaseDir 'bin\curl.exe') ou defina 'CurlPath' no JSON." }

    # -k: a WebGUI usa certificado autoassinado. Quem garante que e o firewall
    # certo e o --pinnedpubkey (o curl confere a chave mesmo com -k).
    $script:Tls = @('-sk', '--connect-timeout', "$timeout", '--max-time', "$maxTime")
    if ($cfg.PubKeyPin) {
        $script:Tls += @('--pinnedpubkey', [string]$cfg.PubKeyPin)
    } else {
        Write-Log "AVISO: perfil sem PubKeyPin - a identidade do pfSense NAO e verificada. Rode o instalador de novo para fixar o certificado."
    }

    $key  = [byte[]](Get-Content $KeyFile -Encoding Byte)
    $pass = Read-Secret $PassFile $key
    if ($encrypt) {
        if (-not (Test-Path $EncFile)) { throw "Encrypt=true mas $EncFile nao existe (rode o Install-pfSenseBackup.ps1 -Encrypt -UpdatePassword)." }
        $encPwd = Read-Secret $EncFile $key
    }

    $base = "https://$($cfg.Host):$port"
    Write-Log "Iniciando $(if ($CheckOnly) { 'verificacao' } else { 'backup' }) - $base - usuario '$($cfg.User)'"

    $result = $null
    for ($try = 1; $try -le $retries; $try++) {
        try {
            $result = Invoke-Backup
            break
        } catch {
            Remove-Item $CookieJar -Force -ErrorAction SilentlyContinue
            if ($script:NoRetry -or $try -ge $retries) { throw }
            Write-Log "tentativa $try de $retries falhou: $($_.Exception.Message) - nova tentativa em $retryDelay s"
            Start-Sleep -Seconds $retryDelay
        }
    }
    $pass = $null; $encPwd = $null

    if ($CheckOnly) {
        Write-Log "CHECK OK: login OK, acesso ao backup OK, sem privilegios extras."
    } else {
        Write-Log ("OK  {0}  ({1} KB){2}" -f $result.File, [math]::Round($result.Size / 1KB, 1), $result.Note)

        # 6) retencao local
        Remove-OldBackups $BkDir

        $cw = $null
        # 7) copia para fora do servidor (NAS/outro servidor). Falha aqui nao
        #    invalida o backup local: vira evento 1002 (aviso) para o monitoramento.
        if ($cfg.CopyTo) {
            try {
                $dest = Join-Path ([string]$cfg.CopyTo) $Name
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force $dest | Out-Null }
                Copy-Item $result.File $dest -Force
                Remove-OldBackups $dest
                Write-Log "copia externa OK: $dest"
            } catch {
                $cw = $_.Exception.Message
                Write-Log "AVISO: copia externa para '$($cfg.CopyTo)' falhou: $cw"
                Write-Event 1002 'Warning' "Backup local OK, mas a copia externa para '$($cfg.CopyTo)' FALHOU: $cw"
            }
        }

        Write-Log 'Concluido.'
        $resumo = "Backup OK: $($result.File) ($([math]::Round($result.Size / 1KB, 1)) KB)$($result.Note)"
        Write-Event 1000 'Information' $resumo
        if ($cw) { Write-Status 'AVISO' "$resumo - mas a copia externa FALHOU: $cw" }
        else     { Write-Status 'OK' $resumo }
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Log "ERRO: $msg"
    if (-not $CheckOnly) {
        Write-Event 1001 'Error' "Backup FALHOU: $msg"
        Write-Status 'ERRO' "Backup FALHOU: $msg"
    }
    $exitCode = 1
}
finally {
    $pass = $null; $encPwd = $null
    Remove-Item $CookieJar -Force -ErrorAction SilentlyContinue
}
exit $exitCode
