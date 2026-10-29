<#
.SYNOPSIS
    Cadastra (ou remove) um firewall pfSense no backup automatico.

.DESCRIPTION
    PRE-REQUISITO OBRIGATORIO (no pfSense, antes de rodar):
      - grupo  BACKUP-PFSENSE  com SO o privilegio
        "WebCfg - Diagnostics: Backup & Restore"
      - usuario dedicado (padrao srvbackup-pfsense) membro SO desse grupo
    O instalador confere isso de verdade (login + acesso ao backup + ausencia
    de privilegios extras) e RECUSA criar a tarefa se estiver errado.
    Os nomes padrao ficam no bloco "PADROES" do param() abaixo - mude ali
    ou passe por parametro (-User, -GroupName...).

    Antes de tudo, identifica o Windows (nome, build, 32/64 bits) e avisa se
    ele traz o curl.exe de fabrica (build 17134+: Windows 10 1803 / Server 2019)
    ou se vai ser preciso baixar (Server 2016 / 2012 R2 - so com sua concordancia).

    Faz, de uma vez, todo o setup de um perfil novo:
      1. cria a estrutura em <BaseDir> (config, secrets, backups, logs)
      2. trava as permissoes da pasta (so SYSTEM + Administradores, por SID,
         funciona em Windows em portugues ou ingles); o conteudo herda
      3. copia o Backup-pfSense.ps1 para <BaseDir> (se rodado de outra pasta)
      .  confere o curl.exe; se faltar (Server 2016/2012 R2), explica e, com a
         sua concordancia, baixa o curl oficial para <BaseDir>\bin\curl.exe
      4. gera a chave AES do perfil e grava a senha do pfSense cifrada
      5. testa a porta da WebGUI e FIXA a chave do certificado (pinning): dai
         em diante o backup recusa conversar com qualquer outro equipamento
      6. grava config\<Nome>.json
      7. registra a origem "pfSense-Backup" no Log de Aplicativo
      8. VERIFICA o usuario no pfSense (obrigatorio; reprova se errado)
      9. cria a tarefa agendada diaria como SYSTEM
     10. roda um backup de teste

    Pode ser rodado de novo para o mesmo perfil: atualiza o JSON e a tarefa,
    mantem chave, senha e o certificado fixado (use -UpdatePassword para
    trocar a senha, -TrustNewCert se o certificado da WebGUI foi renovado).
    Campos editados a mao no JSON (Retries, MaxTime...) sao preservados.

.PARAMETER Name
    Nome curto do perfil: letras, numeros, - e _. Vira nome de arquivo e de
    tarefa. Ex.: FWMATRIZ, FWFILIAL.

.PARAMETER FwHost
    IP ou nome do pfSense, como o servidor enxerga (normalmente o IP da LAN).

.PARAMETER Port
    Porta HTTPS da WebGUI (System > Advanced > Admin Access). Padrao 443.
    Se nao for informada, o instalador PERGUNTA, mostrando o padrao entre
    colchetes ([443] num cadastro novo, ou a porta ja salva no perfil):
    ENTER mantem, ou digite a porta (ex.: 11443). Informando -Port (ou -Yes),
    nao pergunta. A porta fica salva no config\<Nome>.json.

.PARAMETER User
    Usuario dedicado do pfSense, membro do grupo de backup. Padrao
    srvbackup-pfsense. "admin" e "root" sao recusados.

.PARAMETER GroupName
    Nome do grupo de backup no pfSense (so usado nas mensagens/instrucoes;
    a verificacao e feita pelo efeito do privilegio). Padrao BACKUP-PFSENSE.

.PARAMETER Yes
    Nao pergunta nada (automacao): assume que o pre-requisito do pfSense foi
    feito, usa a porta salva (ou 443), aceita o certificado da WebGUI no
    primeiro cadastro e AUTORIZA baixar o curl oficial se ele faltar.

.PARAMETER Time
    Horario diario da tarefa (HH:mm). Padrao 02:00.

.PARAMETER KeepDays
    Apaga backups mais velhos que N dias. Padrao 90.

.PARAMETER MinKeep
    Sempre preserva os N backups mais recentes, mesmo velhos. Padrao 10.

.PARAMETER IncludeRRD
    Inclui os graficos RRD no backup (arquivo bem maior).

.PARAMETER Encrypt
    Pede ao pfSense o backup criptografado (.xml.enc). Pergunta a senha de
    criptografia e guarda cifrada. Guarde essa senha em local seguro: sem ela
    o backup nao restaura.

.PARAMETER CopyTo
    (Opcional) Pasta FORA deste servidor (ex.: \\nas\backups\pfsense) para
    onde cada backup validado e copiado, em <CopyTo>\<Nome>\, com a mesma
    retencao. Protege contra perder os backups junto com o servidor (falha de
    disco, ransomware). A tarefa roda como SYSTEM, que acessa a rede como a
    CONTA DO COMPUTADOR (DOMINIO\SERVIDOR$): de permissao de escrita a ela no
    compartilhamento. Recomendado junto com -Encrypt. Use -CopyTo '' para
    desligar.

.PARAMETER CurlPath
    Caminho do curl.exe. Normalmente nao precisa: o instalador procura em
    C:\Windows\System32\curl.exe (Windows 10 1803+ / Server 2019+), em
    <BaseDir>\bin\curl.exe e no PATH. Se nao achar (Server 2016/2012 R2), ele
    EXPLICA e PERGUNTA se pode baixar o curl oficial de https://curl.se/windows/
    para <BaseDir>\bin\curl.exe. Nada e instalado no Windows: e so esse arquivo.

.PARAMETER TrustNewCert
    Aceita um certificado da WebGUI diferente do fixado no cadastro. Use so
    depois de confirmar que a troca foi legitima (certificado renovado).

.PARAMETER BaseDir
    Pasta da instalacao. Padrao C:\pfSense-Backup. Sem espacos no caminho.

.PARAMETER UpdatePassword
    Pede de novo a senha do pfSense (e a de criptografia, se -Encrypt).

.PARAMETER NoTest
    Pula a verificacao do usuario e o backup de teste (ex.: pfSense
    inacessivel no momento da instalacao). Nao recomendado.

.PARAMETER Uninstall
    Remove a tarefa, o JSON e os segredos do perfil. Os backups ficam.

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 192.168.1.1
    (usa usuario srvbackup-pfsense e porta 443, os padroes)

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWFILIAL -FwHost 10.0.0.1 -Port 10443 -User backup.filial

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Encrypt -CopyTo \\NAS01\Backups\pfSense

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -UpdatePassword

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -TrustNewCert

.EXAMPLE
    .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Name,

    [string]$FwHost,

    # ======================= PADROES (edite aqui) =======================
    # Valores usados quando o parametro nao e informado na linha de comando.
    [string]$User      = 'srvbackup-pfsense',   # usuario dedicado no pfSense
    [string]$GroupName = 'BACKUP-PFSENSE',      # grupo com o privilegio de backup
    [ValidateRange(1, 65535)][int]$Port = 443,  # porta HTTPS da WebGUI
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$Time = '02:00',
    [ValidateRange(1, 3650)][int]$KeepDays = 90,
    [ValidateRange(1, 1000)][int]$MinKeep = 10,
    [ValidatePattern('^[^ ]+$')][string]$BaseDir = 'C:\pfSense-Backup',
    # ===================================================================

    [string]$CopyTo,

    [string]$CurlPath,

    [switch]$IncludeRRD,
    [switch]$Encrypt,
    [switch]$UpdatePassword,
    [switch]$TrustNewCert,
    [switch]$NoTest,
    [switch]$Yes,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$EventSource = 'pfSense-Backup'
$TaskName    = "pfSense Backup - $Name"
$SidSystem   = '*S-1-5-18'      # NT AUTHORITY\SYSTEM
$SidAdmins   = '*S-1-5-32-544'  # BUILTIN\Administrators / Administradores

$CfgDir   = Join-Path $BaseDir 'config'
$SecDir   = Join-Path $BaseDir 'secrets'
$CfgFile  = Join-Path $CfgDir  "$Name.json"
$KeyFile  = Join-Path $SecDir  "$Name.key"
$PassFile = Join-Path $SecDir  "$Name.pass"
$EncFile  = Join-Path $SecDir  "$Name.encpass"
$Engine   = Join-Path $BaseDir 'Backup-pfSense.ps1'

function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "    !!  $m" -ForegroundColor Yellow }

function Read-ConfirmedSecret([string]$Prompt) {
    while ($true) {
        $a = Read-Host $Prompt -AsSecureString
        $b = Read-Host "$Prompt (confirme)" -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
        $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
        try {
            $sa = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pa)
            $sb = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pb)
            if (-not $sa) { Warn 'vazia, digite de novo.'; continue }
            if ($sa -ceq $sb) { return $a }
            Warn 'as duas nao conferem, digite de novo.'
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb)
        }
    }
}

function Save-Secret([securestring]$Secret, [string]$File, [byte[]]$Key) {
    ConvertFrom-SecureString -SecureString $Secret -Key $Key | Set-Content -Path $File -Encoding ASCII
}

function Get-DerElement([byte[]]$B, [int]$Start) {
    # Le o cabecalho (tag + tamanho) de um elemento DER e devolve onde o conteudo
    # comeca e onde o elemento termina.
    $i = $Start + 1
    $len = [int]$B[$i]; $i++
    if ($len -band 0x80) {
        $n = $len -band 0x7F; $len = 0
        for ($k = 0; $k -lt $n; $k++) { $len = ($len -shl 8) -bor [int]$B[$i]; $i++ }
    }
    return @{ Content = $i; End = $i + $len }
}

function Get-WebGuiCert([string]$H, [int]$P) {
    # Pega o certificado da WebGUI (sem validar: e autoassinado) e calcula o pin no
    # formato do curl: sha256//<base64 do SHA-256 da SubjectPublicKeyInfo>.
    # O .NET Framework nao exporta a SPKI pronta, entao ela e lida direto do DER:
    # Certificate > tbsCertificate > [versao], serial, algoritmo, emissor,
    # validade, titular, SPKI.
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($H, $P, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { throw "sem resposta em ${H}:$P" }
        $tcp.EndConnect($ar)
        $aceitaTudo = [Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) $true }
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $aceitaTudo)
        try {
            $ssl.AuthenticateAsClient($H, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        } finally { $ssl.Dispose() }
    } finally { $tcp.Close() }

    $raw = $cert.RawData
    $p = (Get-DerElement $raw (Get-DerElement $raw 0).Content).Content
    if ($raw[$p] -eq 0xA0) { $p = (Get-DerElement $raw $p).End }       # [0] versao
    for ($n = 0; $n -lt 5; $n++) { $p = (Get-DerElement $raw $p).End }  # serial ... titular
    $spki = New-Object byte[] ((Get-DerElement $raw $p).End - $p)
    [Array]::Copy($raw, $p, $spki, 0, $spki.Length)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $pin = 'sha256//' + [Convert]::ToBase64String($sha.ComputeHash($spki))
        $fp  = [BitConverter]::ToString($sha.ComputeHash($raw)) -replace '-', ':'
    } finally { $sha.Dispose() }
    return [pscustomobject]@{ Pin = $pin; Sha256 = $fp; Subject = $cert.Subject; NotAfter = $cert.NotAfter }
}

function Get-Existing([string]$Field, $Default) {
    # Valor ja gravado no JSON do perfil (campo editado a mao e preservado).
    if ($existing -and $null -ne $existing.$Field -and "$($existing.$Field)" -ne '') { return $existing.$Field }
    return $Default
}

# --------------------------- pre-requisitos ---------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Rode este script num PowerShell aberto como Administrador.'
}
if ($PSVersionTable.PSVersion.Major -lt 4 -or $PSVersionTable.PSVersion.Major -gt 5) {
    throw "Use o Windows PowerShell 4.0-5.1 (powershell.exe). Versao atual: $($PSVersionTable.PSVersion)."
}

# ----------------------------- remocao --------------------------------
if ($Uninstall) {
    Step "Removendo perfil '$Name'"
    # PS 5.1 + ErrorActionPreference=Stop transforma stderr de exe nativo em excecao
    $ErrorActionPreference = 'Continue'
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0){ Ok "tarefa '$TaskName' removida" } else { Warn "tarefa '$TaskName' nao existia" }
    foreach ($f in @($CfgFile, $KeyFile, $PassFile, $EncFile)) {
        if (Test-Path $f) { Remove-Item $f -Force; Ok "apagado $f" }
    }
    Ok "backups mantidos em $(Join-Path $BaseDir "backups\$Name") (apague na mao se quiser)"
    return
}

# ------------------------ sistema operacional -------------------------
# Primeira coisa: identificar o Windows, pra ja dizer se vai ser preciso baixar
# algo. O curl.exe vem de fabrica a partir do build 17134 (Windows 10 1803 e
# Server 2019, build 17763); o Server 2016 (build 14393) e o 2012 R2 nao trazem.
Step 'Sistema operacional'
$CurlDesdeBuild = 17134
$osBuild = [Environment]::OSVersion.Version.Build
$osNome  = 'Windows'
try { $osNome = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption.Trim() } catch {}
$osBits  = if ([Environment]::Is64BitOperatingSystem) { '64 bits' } else { '32 bits' }
$osTemCurl = $osBuild -ge $CurlDesdeBuild
Ok "$osNome (build $osBuild, $osBits) - PowerShell $($PSVersionTable.PSVersion)"
if ($osTemCurl) {
    Ok 'esta versao do Windows ja traz o curl.exe: nada precisa ser baixado.'
} else {
    Warn "esta versao do Windows NAO traz o curl.exe (ele so vem a partir do build ${CurlDesdeBuild}: Windows 10 1803 / Server 2019)."
    Warn 'o instalador vai procurar um curl ja existente; se nao achar, explica e PERGUNTA antes de baixar o curl oficial.'
}

# Em re-execucao sem -FwHost/-User, reaproveita o JSON existente
$existing = $null
if (Test-Path $CfgFile) { $existing = Get-Content $CfgFile -Raw | ConvertFrom-Json }
if (-not $FwHost -and $existing) { $FwHost = $existing.Host }
if (-not $PSBoundParameters.ContainsKey('User')       -and $existing -and $existing.User)     { $User     = $existing.User }
if (-not $PSBoundParameters.ContainsKey('Port')       -and $existing -and $existing.Port)     { $Port     = [int]$existing.Port }
if (-not $PSBoundParameters.ContainsKey('KeepDays')   -and $existing -and $existing.KeepDays) { $KeepDays = [int]$existing.KeepDays }
if (-not $PSBoundParameters.ContainsKey('MinKeep')    -and $existing -and $existing.MinKeep)  { $MinKeep  = [int]$existing.MinKeep }
if (-not $PSBoundParameters.ContainsKey('IncludeRRD') -and $existing) { $IncludeRRD = [bool]$existing.IncludeRRD }
if (-not $PSBoundParameters.ContainsKey('Encrypt')    -and $existing) { $Encrypt    = [bool]$existing.Encrypt }
if (-not $PSBoundParameters.ContainsKey('CopyTo')     -and $existing -and $existing.CopyTo) { $CopyTo = [string]$existing.CopyTo }
if (-not $FwHost) { throw 'Informe -FwHost (IP ou nome do pfSense).' }
if (-not $User)   { throw 'Informe -User (usuario dedicado do pfSense).' }
if ($User -in @('admin', 'root')) {
    throw "Nao use '$User'. Crie um usuario dedicado no grupo $GroupName (veja o README, passo 2)."
}

# Porta da WebGUI: muito pfSense usa porta fora do padrao (8443, 11443...). Se a
# porta nao veio na linha de comando (-Port), pergunta mostrando o padrao entre
# colchetes: 443 num cadastro novo, ou a porta ja salva no perfil. ENTER mantem.
# Com -Port ou -Yes nao pergunta nada (bom para automacao).
if (-not $PSBoundParameters.ContainsKey('Port') -and -not $Yes) {
    Write-Host ''
    Write-Host '  PORTA DA WebGUI DO pfSENSE' -ForegroundColor Yellow
    Write-Host '  --------------------------'
    Write-Host '  E o numero depois de ":" no endereco que voce usa para abrir o pfSense'
    Write-Host '  no navegador. Sem numero no endereco, a porta e 443.'
    Write-Host '     https://172.16.10.1        -> 443   (so aperte ENTER)'
    Write-Host '     https://172.16.10.1:11443  -> digite 11443'
    Write-Host '  No pfSense: System > Advanced > Admin Access > TCP port (vazio = 443).'
    while ($true) {
        $r = Read-Host "  Porta HTTPS da WebGUI [$Port]"
        if ([string]::IsNullOrWhiteSpace($r)) { break }
        $n = 0
        if ([int]::TryParse($r.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { $Port = $n; break }
        Warn 'porta invalida: digite so o numero, de 1 a 65535 (ou ENTER para manter).'
    }
    Ok "porta da WebGUI: $Port"
}

# ---------------------- 0. pre-requisito no pfSense -------------------
if (-not $Yes -and (-not $existing -or $UpdatePassword -or $PSBoundParameters.ContainsKey('User'))) {
    Write-Host ''
    Write-Host '  PRE-REQUISITO NO pfSense (obrigatorio)' -ForegroundColor Yellow
    Write-Host '  ---------------------------------------'
    Write-Host "  1. System > User Manager > Groups > Add"
    Write-Host "       Group name: $GroupName   (Scope: Local)  > Save"
    Write-Host "     Edite o grupo > Assigned Privileges > Add:"
    Write-Host "       SOMENTE  'WebCfg - Diagnostics: Backup & Restore'  > Save"
    Write-Host "       (NAO e 'Services: Auto Config Backup' - esse e outro recurso)"
    Write-Host "  2. System > User Manager > Users > Add"
    Write-Host "       Username: $User   Password: <forte>"
    Write-Host "       Group membership: $GroupName (e nenhum outro)  > Save"
    Write-Host ''
    $ans = Read-Host "  Ja criou o grupo '$GroupName' e o usuario '$User' assim? (S/N)"
    if ($ans -notmatch '^[sSyY]') {
        throw 'Instalacao cancelada. Crie o grupo e o usuario no pfSense e rode de novo.'
    }
}

# ---------------------------- 1. pastas -------------------------------
Step "Estrutura em $BaseDir"
foreach ($d in @($BaseDir, $CfgDir, $SecDir, (Join-Path $BaseDir 'backups'), (Join-Path $BaseDir 'logs'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
}
Ok 'pastas prontas'

# --------------------------- 2. permissoes ----------------------------
# A ACL explicita vai SO na pasta raiz; tudo dentro dela HERDA. Antes isto era um
# unico icacls com /T, que aplicava "/inheritance:r" e "(OI)(CI)" tambem em cada
# arquivo: em arquivo o (OI)(CI) nao vale, o grant falhava (escondido pelo /C /Q)
# e o arquivo ficava SEM permissao nenhuma - nem SYSTEM conseguia ler o script.
# Feito ANTES da copia: assim tambem conserta uma instalacao antiga ja travada
# (o /reset funciona porque o dono dos arquivos, Administradores, sempre pode
# reescrever a ACL).
Step 'Travando permissoes (SYSTEM + Administradores)'
& icacls.exe $BaseDir /inheritance:r /grant:r "${SidSystem}:(OI)(CI)F" "${SidAdmins}:(OI)(CI)F" /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls falhou ao travar $BaseDir (exit $LASTEXITCODE)." }
& icacls.exe (Join-Path $BaseDir '*') /reset /T /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw ("icacls falhou ao aplicar a heranca dentro de $BaseDir (exit $LASTEXITCODE). " +
           "Se a pasta veio de outra instalacao, assuma a posse e rode de novo: takeown /F $BaseDir /R /A /D S  (Windows em ingles: /D Y)")
}
Ok 'pasta acessivel apenas por SYSTEM e Administradores (conteudo herda da pasta)'

# ------------------------ 3. copia do motor ---------------------------
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Definition   # mesmo motivo do motor: nao confiar no $PSScriptRoot
$src = Join-Path $aqui 'Backup-pfSense.ps1'
if ((Resolve-Path $aqui).Path.TrimEnd('\') -ne (Resolve-Path $BaseDir).Path.TrimEnd('\')) {
    if (-not (Test-Path $src)) { throw "Backup-pfSense.ps1 nao encontrado ao lado deste instalador ($src)." }
    Copy-Item $src $Engine -Force
    Copy-Item $PSCommandPath (Join-Path $BaseDir 'Install-pfSenseBackup.ps1') -Force
    Ok "scripts copiados para $BaseDir"
} else {
    Ok 'rodando de dentro de BaseDir, nada a copiar'
}
if (-not (Test-Path $Engine)) { throw "motor nao encontrado em $Engine." }

# ------------------------------ curl.exe ------------------------------
# Verificado ANTES de pedir senha: sem curl nada funciona. Windows 10 1803+ e
# Server 2019+ ja trazem o curl.exe; Server 2016/2012 R2 nao. Nesse caso o
# instalador oferece baixar o curl OFICIAL (curl.se) - explicando o que, de onde,
# por que e onde fica - e so baixa se a pessoa concordar (ou com -Yes).
Step 'curl.exe'
$curlSys = Join-Path $env:SystemRoot 'System32\curl.exe'
$curlBin = Join-Path $BaseDir 'bin\curl.exe'
if ($CurlPath -and -not (Test-Path $CurlPath)) { throw "-CurlPath informado, mas o arquivo nao existe: $CurlPath" }
$candidatos = @()
if ($CurlPath) { $candidatos += $CurlPath }
elseif ($existing -and $existing.CurlPath) { $candidatos += [string]$existing.CurlPath }
$candidatos += @($curlSys, $curlBin)
$noPath = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($noPath) { $candidatos += $noPath.Path }
$curl = $null
foreach ($c in $candidatos) { if ($c -and (Test-Path $c)) { $curl = $c; break } }

if (-not $curl) {
    $pacote  = if ([Environment]::Is64BitOperatingSystem) { 'win64-mingw' } else { 'win32-mingw' }
    $urlCurl = "https://curl.se/windows/latest.cgi?p=$pacote.zip"
    $manual  = ("Para colocar o curl na mao:`n" +
                "    1. Num PC com internet, baixe o curl oficial para Windows: https://curl.se/windows/`n" +
                "    2. Do ZIP, copie o arquivo bin\curl.exe para $curlBin`n" +
                "    3. Rode este instalador de novo (ou informe -CurlPath <caminho do curl.exe>).")
    Write-Host ''
    Write-Host '  O curl.exe NAO foi encontrado neste servidor' -ForegroundColor Yellow
    Write-Host '  ---------------------------------------------'
    Write-Host '  O QUE E:     o curl, ferramenta de linha de comando open source (https://curl.se),'
    Write-Host '               a mesma que ja vem no Windows 10 1803+ e no Server 2019+.'
    Write-Host '  POR QUE:     o backup usa o curl para entrar na WebGUI do pfSense e baixar o'
    if ($osTemCurl) {
        Write-Host "               config.xml. Este $osNome (build $osBuild) deveria trazer o curl,"
        Write-Host "               mas ele nao esta em $curlSys (removido?)."
    } else {
        Write-Host "               config.xml. Este $osNome (build $osBuild) nao traz o curl de fabrica."
    }
    Write-Host '  DE ONDE:     site oficial do projeto, por HTTPS (certificado verificado):'
    Write-Host "               $urlCurl"
    Write-Host "  ONDE FICA:   so o arquivo curl.exe, em $curlBin"
    Write-Host '  O QUE NAO E FEITO: nada e instalado no Windows - sem instalador, sem PATH, sem'
    Write-Host '               registro, sem servico. Para remover, basta apagar a pasta bin.'
    Write-Host ''
    if ($Yes) {
        Ok 'download autorizado por -Yes'
    } else {
        $ans = Read-Host '  Baixar o curl oficial agora e colocar nessa pasta? (S/N)'
        if ($ans -notmatch '^[sSyY]') { throw "Instalacao cancelada: o curl e obrigatorio.`n    $manual" }
    }

    $tmpZip = Join-Path $env:TEMP ("curl_" + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        # O Windows PowerShell 5.1 no Server 2016 nao liga o TLS 1.2 sozinho, e o curl.se exige.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "    baixando $urlCurl ..."
        # Sem a barra de progresso: no PS 5.1 ela deixa o download dezenas de vezes mais lento.
        $progAntes = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $urlCurl -OutFile $tmpZip -UseBasicParsing }
        catch { throw "nao consegui baixar o curl ($($_.Exception.Message)). O servidor tem acesso a internet / proxy?`n    $manual" }
        finally { $ProgressPreference = $progAntes }

        # Extrai SO o bin\curl.exe do ZIP (sem Expand-Archive: nao existe no PowerShell 4).
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            $entrada = $zip.Entries | Where-Object { $_.FullName -match '(^|/)bin/curl\.exe$' } | Select-Object -First 1
            if (-not $entrada) { throw "o ZIP baixado nao tem bin/curl.exe (o site mudou o formato?).`n    $manual" }
            $pastaBin = Split-Path $curlBin -Parent
            if (-not (Test-Path $pastaBin)) { New-Item -ItemType Directory -Force $pastaBin | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, $curlBin, $true)
            Ok "extraido do ZIP: $($entrada.FullName)"
        } finally { $zip.Dispose() }
        $hashCurl = (Get-FileHash $curlBin -Algorithm SHA256).Hash
        Ok "curl colocado em $curlBin"
        Ok "SHA-256 do curl.exe: $hashCurl (anote, se quiser auditar depois)"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
    $curl = $curlBin
}
$verCurl = [string](& $curl --version | Select-Object -First 1)
$mv = [regex]::Match($verCurl, '^curl (\d+)\.(\d+)')
if (-not $mv.Success) { throw "$curl nao parece ser o curl (saida de --version: $verCurl)." }
if ([version]('{0}.{1}' -f $mv.Groups[1].Value, $mv.Groups[2].Value) -lt [version]'7.44') {
    throw "$curl e o curl $($mv.Groups[1].Value).$($mv.Groups[2].Value): antigo demais (precisa 7.44+ para fixar o certificado). Baixe o atual em https://curl.se/windows/."
}
Ok "$curl  ($(($verCurl -split ' ')[0..1] -join ' '))"
# So grava no JSON se nao for o do Windows; assim o motor acha o mesmo curl.
$curlSalvar = if ($curl -ieq $curlSys) { '' } else { $curl }

# ------------------------ 4. chave e senhas ---------------------------
Step 'Chave e senha'
if (-not (Test-Path $KeyFile)) {
    $k = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($k); $rng.Dispose()
    Set-Content -Path $KeyFile -Value $k -Encoding Byte
    Ok "chave AES gerada: $KeyFile"
} else {
    Ok 'chave ja existia, mantida'
}
$key = [byte[]](Get-Content $KeyFile -Encoding Byte)

if ($UpdatePassword -or -not (Test-Path $PassFile)) {
    $s = Read-ConfirmedSecret "Senha do pfSense para o usuario '$User'"
    Save-Secret $s $PassFile $key
    Ok "senha gravada cifrada: $PassFile"
} else {
    Ok 'senha ja existia, mantida (use -UpdatePassword para trocar)'
}

if ($Encrypt) {
    if ($UpdatePassword -or -not (Test-Path $EncFile)) {
        Warn 'senha de CRIPTOGRAFIA do backup: guarde-a fora deste servidor, sem ela o backup nao restaura.'
        $s = Read-ConfirmedSecret 'Senha de criptografia do backup'
        Save-Secret $s $EncFile $key
        Ok "senha de criptografia gravada: $EncFile"
    } else {
        Ok 'senha de criptografia ja existia, mantida'
    }
}

# ------------------ 5. porta + certificado (pinning) ------------------
Step "Testando ${FwHost}:$Port"
$tcp = New-Object Net.Sockets.TcpClient
try {
    $ar = $tcp.BeginConnect($FwHost, $Port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected) { Ok 'porta aberta' }
    else {
        Warn "sem resposta em ${FwHost}:$Port - confira IP, porta da WebGUI e regras do firewall."
        Warn "se a WebGUI usa outra porta, rode de novo com -Port <porta> (ex.: -Port 10443)."
    }
} catch { Warn "falha ao conectar: $($_.Exception.Message)" }
finally { $tcp.Close() }

Step 'Certificado da WebGUI (pinning)'
$pin = [string](Get-Existing 'PubKeyPin' '')
$wc = $null
try { $wc = Get-WebGuiCert $FwHost $Port }
catch { Warn "nao consegui ler o certificado: $($_.Exception.Message)" }
if ($wc) {
    Ok "titular: $($wc.Subject)  (valido ate $($wc.NotAfter.ToString('dd/MM/yyyy')))"
    Ok "SHA-256: $($wc.Sha256)"
    if (-not $pin) {
        if (-not $Yes) {
            Write-Host "    Confira essa impressao digital SHA-256 com a que o navegador mostra ao abrir"
            Write-Host "    https://${FwHost}:$Port a partir da mesma rede (cadeado > certificado > detalhes)."
            $ans = Read-Host '    A impressao digital confere? (S/N)'
            if ($ans -notmatch '^[sSyY]') { throw 'Instalacao cancelada: certificado nao confirmado.' }
        }
        $pin = $wc.Pin
        Ok "chave do certificado fixada: $pin"
    } elseif ($pin -ne $wc.Pin) {
        if (-not $TrustNewCert) {
            throw ("A chave do certificado do pfSense MUDOU desde o cadastro.`n" +
                   "    fixada: $pin`n    agora:  $($wc.Pin)`n" +
                   "    Se a troca foi legitima (certificado da WebGUI renovado), confira a impressao digital acima " +
                   "e rode de novo com -TrustNewCert. Se nao foi, alguem pode estar se passando pelo firewall.")
        }
        $pin = $wc.Pin
        Ok "nova chave aceita (-TrustNewCert): $pin"
    } else {
        Ok 'chave igual a fixada no cadastro'
    }
} elseif ($pin) {
    Warn 'mantida a chave fixada anteriormente.'
} else {
    Warn 'perfil fica SEM pinning: rode o instalador de novo com o pfSense acessivel.'
}

# --------------------------- 6. config JSON ---------------------------
Step 'Gravando configuracao'
$cfg = [ordered]@{
    Name           = $Name
    Host           = $FwHost
    Port           = $Port
    User           = $User
    KeepDays       = $KeepDays
    MinKeep        = $MinKeep
    IncludeRRD     = [bool]$IncludeRRD
    Encrypt        = [bool]$Encrypt
    CopyTo         = [string]$CopyTo
    PubKeyPin      = $pin
    ConnectTimeout = [int](Get-Existing 'ConnectTimeout' 15)
    MaxTime        = [int](Get-Existing 'MaxTime' 300)
    Retries        = [int](Get-Existing 'Retries' 3)
    RetryDelay     = [int](Get-Existing 'RetryDelay' 60)
    CurlPath       = [string]$curlSalvar
}
New-Object psobject -Property $cfg | ConvertTo-Json | Set-Content -Path $CfgFile -Encoding ASCII
Ok $CfgFile
if ($CopyTo) {
    Ok "copia externa: $CopyTo\$Name"
    Warn "a tarefa roda como SYSTEM e acessa '$CopyTo' como a conta do computador ($env:USERDOMAIN\$env:COMPUTERNAME`$) - de permissao de escrita a ela no compartilhamento."
    if (-not $Encrypt) { Warn 'copia externa SEM -Encrypt: o config.xml tem hashes de senha e chaves de VPN. Recomendado usar -Encrypt.' }
}

# ------------------------ 7. origem de eventos ------------------------
Step 'Log de eventos'
try {
    if (-not [Diagnostics.EventLog]::SourceExists($EventSource)) {
        New-EventLog -LogName Application -Source $EventSource
        Ok "origem '$EventSource' registrada (IDs 1000 = OK, 1001 = erro, 1002 = copia externa falhou)"
    } else { Ok "origem '$EventSource' ja existia" }
} catch { Warn "nao consegui registrar a origem de eventos: $($_.Exception.Message)" }

# ---------------- 8. verificacao do usuario no pfSense ----------------
if ($NoTest) {
    Warn 'verificacao do usuario PULADA (-NoTest). A tarefa sera criada sem validar.'
} else {
    Step "Verificando o usuario '$User' no pfSense"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Name $Name -BaseDir $BaseDir -CheckOnly
    if ($LASTEXITCODE -ne 0) {
        throw ("Verificacao REPROVADA - a tarefa NAO foi criada. Corrija conforme a mensagem acima " +
               "(grupo $GroupName so com 'WebCfg - Diagnostics: Backup & Restore') e rode de novo " +
               "(use -UpdatePassword se o erro foi de senha).")
    }
    Ok 'usuario correto: acessa o backup e nada alem disso'
}

# ------------------------ 9. tarefa agendada --------------------------
Step "Tarefa agendada '$TaskName' (diaria $Time, SYSTEM)"
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Name $Name -BaseDir $BaseDir"
& schtasks.exe /Create /F /TN $TaskName /RU SYSTEM /RL HIGHEST /SC DAILY /ST $Time /TR $tr | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks falhou ao criar a tarefa (exit $LASTEXITCODE)." }
Ok 'tarefa criada/atualizada'

# -------------------------- 10. teste real ----------------------------
if ($NoTest) {
    Warn 'backup de teste pulado (-NoTest).'
} else {
    Step 'Rodando backup de teste'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Name $Name -BaseDir $BaseDir
    if ($LASTEXITCODE -eq 0) { Ok 'backup de teste OK' }
    else { Warn "backup de teste FALHOU - veja $(Join-Path $BaseDir "logs\$Name.log") e a secao Problemas do README." }
}

Write-Host ''
Write-Host "Pronto. Para testar como SYSTEM (igual a execucao diaria):" -ForegroundColor Cyan
Write-Host "    schtasks /Run /TN `"$TaskName`""
Write-Host "    Start-Sleep 10; Get-Content $(Join-Path $BaseDir "logs\$Name.log") -Tail 5"
