<#
.SYNOPSIS
    Valida os scripts com o parser do PowerShell e (opcional) o PSScriptAnalyzer.
    Rode no Windows PowerShell 5.1 (o dos clientes) e/ou no pwsh.
.PARAMETER Analyzer
    Tambem roda o PSScriptAnalyzer, incluindo a regra que confere se a sintaxe
    e compativel com o Windows PowerShell 4.0 e 5.1.
#>
param([switch]$Analyzer)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scripts = @('Backup-pfSense.ps1', 'Install-pfSenseBackup.ps1')
$erros = 0

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
foreach ($s in $scripts) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $s), [ref]$t, [ref]$e)
    if ($e) {
        foreach ($x in $e) { Write-Host "ERRO $s linha $($x.Extent.StartLineNumber): $($x.Message)" -ForegroundColor Red }
        $erros += $e.Count
    } else { Write-Host "Sintaxe OK: $s" -ForegroundColor Green }
    # Os .ps1 tem que ser ASCII puro: o PS 5.1 le arquivo sem BOM como ANSI.
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $s))
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) { Write-Host "ERRO ${s}: tem caractere fora do ASCII" -ForegroundColor Red; $erros++ }
}

if ($Analyzer) {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force }
    # Avisos ignorados de proposito: Write-Host (ferramenta interativa), verbos em
    # portugues, catch vazio nos pontos de "melhor esforco" (log, logout).
    $excluir = @('PSAvoidUsingWriteHost', 'PSUseApprovedVerbs', 'PSUseSingularNouns',
                 'PSUseShouldProcessForStateChangingFunctions', 'PSAvoidUsingEmptyCatchBlock',
                 'PSReviewUnusedParameter', 'PSAvoidOverwritingBuiltInCmdlets')
    $cfg = @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('4.0', '5.1') } } }
    foreach ($s in $scripts) {
        $r = @(Invoke-ScriptAnalyzer -Path (Join-Path $repo $s) -Severity Warning, Error -ExcludeRule $excluir -Settings $cfg)
        foreach ($x in $r) { Write-Host "[$($x.Severity)] $s linha $($x.Line) $($x.RuleName): $($x.Message)" -ForegroundColor Yellow }
        $erros += @($r | Where-Object { $_.Severity -eq 'Error' -or $_.RuleName -eq 'PSUseCompatibleSyntax' }).Count
        if ($r.Count -eq 0) { Write-Host "PSScriptAnalyzer OK: $s" -ForegroundColor Green }
    }
}

if ($erros) { Write-Host "FALHOU: $erros problema(s)." -ForegroundColor Red; exit 1 }
Write-Host 'Tudo OK.' -ForegroundColor Green
