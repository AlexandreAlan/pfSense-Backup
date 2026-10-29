<#
.SYNOPSIS
    Testes funcionais: roda as funcoes REAIS do Backup-pfSense.ps1 e do
    Install-pfSenseBackup.ps1 contra o pfSense simulado (mock_pfsense.py).
    Normalmente chamado pelo run-funcional.sh, que sobe o mock antes.
#>
param(
    [Parameter(Mandatory = $true)][string]$Senha,
    [Parameter(Mandatory = $true)][string]$SenhaEnc,
    [Parameter(Mandatory = $true)][string]$PinOpenssl,
    [int]$Porta = 18443,
    [string]$Curl = 'curl',
    [Parameter(Mandatory = $true)][string]$WorkDir
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object Text.UTF8Encoding($false)
Set-Location $WorkDir   # o curl grava "-o NUL" como arquivo no Linux: fica na pasta temporaria

# Carrega as funcoes REAIS dos scripts do repositorio (sem rodar o main deles).
$repo = Split-Path -Parent $PSScriptRoot
$defs = @()
foreach ($par in @(@('Backup-pfSense.ps1', @('Write-Log','Write-Event','Stop-Permanent','Get-Csrf','ConvertTo-CurlConfig','Invoke-Curl','Invoke-Logout','Invoke-Backup','Write-Status')),
                   @('Install-pfSenseBackup.ps1', @('Get-DerElement','Get-WebGuiCert')))) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $par[0]), [ref]$null, [ref]$null)
    $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $par[1] -contains $_.Name } | ForEach-Object { $defs += $_.Extent.Text }
}
. ([scriptblock]::Create($defs -join "`n"))

$Name = 'TESTE'; $EventSource = 'pfSense-Backup'; $LogFile = "$WorkDir/teste.log"
$BkDir = "$WorkDir/backups"; New-Item -ItemType Directory -Force $BkDir | Out-Null
$StatusDir = "$WorkDir/status/TESTE"
$ForbiddenPages = @('system_usermanager.php','firewall_rules.php','diag_command.php')
$cfg = [pscustomobject]@{ User = 'srvbackup-pfsense' }
$base = "https://127.0.0.1:$Porta"
$script:Curl = (Get-Command $Curl -CommandType Application | Select-Object -First 1).Source
$includeRRD = $false
$falhas = 0
function Stats { (& $script:Curl -sk "$base/stats") | ConvertFrom-Json }
function Cenario([string]$Nome, [scriptblock]$Corpo) {
    $script:NoRetry = $false
    $script:CookieJar = "$WorkDir/cookies_" + [guid]::NewGuid().ToString('N')
    try { $r = & $Corpo; Write-Host "  [PASSOU] $Nome $r" -ForegroundColor Green }
    catch { $script:falhas++; Write-Host "  [FALHOU] $Nome -> $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host '1) Instalador le o certificado e calcula o pin'
$pinCorreto = $null
Cenario 'pin do Get-WebGuiCert = pin do openssl' {
    $wc = Get-WebGuiCert '127.0.0.1' $Porta
    $script:pinCorreto = $wc.Pin
    if ($wc.Pin -ne "sha256//$PinOpenssl") { throw "pin $($wc.Pin) <> sha256//$PinOpenssl" }
    "($($wc.Pin))"
}
$script:Tls = @('-sk','--connect-timeout','5','--max-time','30','--pinnedpubkey',$script:pinCorreto)

Write-Host '2) Backup normal, senha com caracteres dificeis'
$pass = $Senha; $encrypt = $false; $encPwd = ''; $CheckOnly = $false
Cenario 'login + download + validacao + logout' {
    $antes = Stats
    $r = Invoke-Backup
    $depois = Stats
    if (-not (Test-Path $r.File)) { throw 'arquivo nao criado' }
    if ($depois.logins_ok -ne $antes.logins_ok + 1) { throw "login nao aconteceu (senha recebida: $($depois.ultima_senha_recebida))" }
    if ($depois.logouts -ne $antes.logouts + 1) { throw 'logout nao aconteceu' }
    "($([math]::Round($r.Size/1KB,1)) KB, logout OK)"
}

Write-Host '3) Backup criptografado, senha de criptografia dificil'
$encrypt = $true; $encPwd = $SenhaEnc
Cenario 'download .xml.enc com encrypt_password por stdin' {
    $r = Invoke-Backup
    if ($r.File -notlike '*.xml.enc') { throw "extensao errada: $($r.File)" }
    "($([System.IO.Path]::GetFileName($r.File)))"
}
$encrypt = $false; $encPwd = ''

Write-Host '4) Modo -CheckOnly (usuario so com privilegio de backup)'
$CheckOnly = $true
Cenario 'verificacao de privilegio' {
    $r = Invoke-Backup
    if ($null -ne $r) { throw 'CheckOnly deveria devolver $null' }
    '(paginas administrativas bloqueadas, como esperado)'
}
$CheckOnly = $false

Write-Host '5) Senha errada: tem que parar SEM repetir'
$pass = 'senha-errada'
Cenario 'login recusado + NoRetry' {
    try { Invoke-Backup | Out-Null; throw 'deveria ter falhado' }
    catch { if ($_.Exception.Message -notmatch 'login recusado') { throw $_ }; if (-not $script:NoRetry) { throw 'NoRetry deveria ser true' } }
    '(parou na hora, sem nova tentativa)'
}
$pass = $Senha

Write-Host '6) Certificado diferente (pin errado): NAO pode enviar a senha'
Cenario 'pin errado -> curl exit 90, senha nao enviada' {
    $script:Tls = @('-sk','--connect-timeout','5','--max-time','30','--pinnedpubkey','sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
    $antes = Stats
    try { Invoke-Backup | Out-Null; throw 'deveria ter falhado' }
    catch { if ($_.Exception.Message -notmatch 'NAO confere') { throw $_ } }
    $depois = Stats
    if (($depois.logins_ok + $depois.logins_falhos) -ne ($antes.logins_ok + $antes.logins_falhos)) { throw 'a senha CHEGOU no servidor!' }
    '(conexao recusada antes do login)'
}

Write-Host '7) Arquivos de status para o Zabbix'
Cenario 'status.txt / ultimo-ok.txt / mensagem.txt' {
    Write-Status 'OK' 'Backup OK: teste'
    $st  = [IO.File]::ReadAllText("$StatusDir/status.txt")
    $ok1 = [IO.File]::ReadAllText("$StatusDir/ultimo-ok.txt")
    if ($st -ne 'OK') { throw "status.txt = '$st' (esperado 'OK', sem quebra de linha)" }
    if ($ok1 -notmatch '^\d{10}$') { throw "ultimo-ok.txt = '$ok1' (esperado so os segundos)" }
    $agora = [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
    if ([math]::Abs($agora - [int64]$ok1) -gt 5) { throw "ultimo-ok.txt longe de agora: $ok1 x $agora" }
    Start-Sleep -Seconds 1
    Write-Status 'ERRO' 'Backup FALHOU: teste'
    if ([IO.File]::ReadAllText("$StatusDir/status.txt") -ne 'ERRO') { throw 'status.txt nao virou ERRO' }
    if ([IO.File]::ReadAllText("$StatusDir/ultimo-ok.txt") -ne $ok1) { throw 'ultimo-ok.txt NAO pode mudar num erro' }
    if ([IO.File]::ReadAllText("$StatusDir/mensagem.txt") -notmatch 'FALHOU: teste$') { throw 'mensagem.txt sem o motivo' }
    '(OK -> ERRO, ultimo-ok preservado no erro)'
}

Write-Host ''
if ($falhas) { Write-Host "RESULTADO: $falhas cenario(s) FALHARAM" -ForegroundColor Red; exit 1 }
Write-Host 'RESULTADO: todos os cenarios passaram' -ForegroundColor Green
