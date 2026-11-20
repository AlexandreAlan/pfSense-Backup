<#
.SYNOPSIS
    Gera o relatorio de auditoria (HTML) a partir do config.xml baixado pelo backup.

.DESCRIPTION
    Le o backup mais recente do perfil (backups\<Nome>\config-<Nome>-*.xml) e
    monta uma pagina unica, pronta para um auditor ou para o cliente:

        resumo e pontos de atencao, interfaces e VLANs, gateways, regras do
        firewall por interface, NAT, aliases, usuarios e grupos (administradores
        em destaque), OpenVPN (servidores, certificados, validade e revogacao),
        IPsec, portal cativo, DHCP (faixas e reservas), pacotes instalados e
        O QUE MUDOU desde o backup anterior.

    Nunca mostra segredos: senhas, hashes, chaves privadas, chaves de VPN,
    PSK do IPsec e comunidades SNMP ficam de fora.

    Saida (so gera um novo quando a configuracao mudou):
        <BaseDir>\auditoria\<Nome>\AAAA\auditoria-<Nome>-AAAA-MM-DD_HHmm.html
        <BaseDir>\auditoria\<Nome>\ultimo.html        (copia do mais recente)

    Backup criptografado (.xml.enc) nao pode ser lido: o relatorio e pulado.

.PARAMETER Name
    Nome do perfil.
.PARAMETER BaseDir
    Pasta raiz da instalacao. Padrao: a pasta deste script.
.PARAMETER File
    (Opcional) config.xml especifico. Padrao: o backup mais recente do perfil.
.PARAMETER Previous
    (Opcional) config.xml para comparar. Padrao: o backup anterior ao -File.
.PARAMETER Force
    Gera mesmo que a configuracao nao tenha mudado.
.PARAMETER OutFile
    (Opcional) grava neste arquivo em vez da pasta auditoria (usado nos testes).

.NOTES
    Windows PowerShell 4.0 a 5.1. Arquivo em ASCII puro: os acentos do HTML sao
    entidades (&atilde; ...) para nao depender da codificacao do .ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Name,
    [string]$BaseDir,
    [string]$File,
    [string]$Previous,
    [switch]$Force,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# ------------------------------ funcoes -------------------------------
function Get-List($Value) {
    # No [xml] do PowerShell, um item vira objeto e varios viram lista: sempre lista.
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { if ($Value -eq '') { return @() } }
    return @($Value)
}

function Test-Flag($Node, [string]$Child) {
    # <disabled/> existe mas e vazio: no [xml] isso vira '' (nao $null).
    if ($null -eq $Node) { return $false }
    if ($Node -is [string]) { return $false }
    return ($null -ne $Node.$Child)
}

function Get-Text($Node, [string]$Child) {
    if ($null -eq $Node -or $Node -is [string]) { return '' }
    $v = $Node.$Child
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { return $v }
    if ($v -is [Xml.XmlElement]) { return $v.InnerText }
    return [string]$v
}

function H([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

function Format-Endpoint($Ep) {
    # <source>/<destination> de regra: any | network | address, + port, + not.
    if ($null -eq $Ep -or $Ep -is [string]) { return 'qualquer' }
    $t = 'qualquer'
    if (Test-Flag $Ep 'any') { $t = 'qualquer' }
    elseif ((Get-Text $Ep 'network') -ne '') { $t = Get-Text $Ep 'network' }
    elseif ((Get-Text $Ep 'address') -ne '') { $t = Get-Text $Ep 'address' }
    if (Test-Flag $Ep 'not') { $t = "NAO $t" }
    $p = Get-Text $Ep 'port'
    if ($p) { $t = "${t}:$p" }
    return $t
}

function Get-CertInfo([string]$Crt) {
    # crt no config.xml = base64 do PEM. Devolve titular e validade (ou $null).
    if (-not $Crt) { return $null }
    try {
        $pem = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Crt))
        $b64 = ($pem -replace '-----[^-]+-----', '' -replace '\s', '')
        $der = [Convert]::FromBase64String($b64)
        $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $der)
        return [pscustomobject]@{ Subject = $c.Subject; NotAfter = $c.NotAfter; Serial = $c.SerialNumber }
    } catch { return $null }
}

$script:Sb = New-Object Text.StringBuilder
function Out-Html([string]$Text) { [void]$script:Sb.Append($Text) }

function Out-Table([string[]]$Headers, $Rows, [string]$Empty = 'Nenhum item.') {
    # $Rows: lista de arrays de celulas JA em HTML (use H() no texto).
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { Out-Html "<p class=""vazio"">$Empty</p>"; return }
    # Uma linha so pode chegar "desembrulhada" pelo pipeline (array de textos): reembrulha.
    if (-not ($Rows[0] -is [array]) -and -not ($Rows[0] -is [hashtable])) { $Rows = @(, $Rows) }
    Out-Html '<table><thead><tr>'
    foreach ($h in $Headers) { Out-Html "<th>$h</th>" }
    Out-Html '</tr></thead><tbody>'
    foreach ($r in $Rows) {
        $cls = ''
        if ($r -is [hashtable]) { $cls = " class=""$($r.Class)"""; $r = $r.Cells }
        Out-Html "<tr$cls>"
        foreach ($c in @($r)) { Out-Html "<td>$c</td>" }
        Out-Html '</tr>'
    }
    Out-Html '</tbody></table>'
}

function Badge([string]$Text, [string]$Kind) { return "<span class=""b $Kind"">$(H $Text)</span>" }

function Get-IfName($Cfg, [string]$Key) {
    if (-not $Key) { return '' }
    $out = @()
    foreach ($k in ($Key -split ',')) {
        $i = $Cfg.pfsense.interfaces.$k
        if ($i -and -not ($i -is [string]) -and (Get-Text $i 'descr')) { $out += "$(Get-Text $i 'descr') ($k)" } else { $out += $k }
    }
    return ($out -join ', ')
}

function Get-RuleKey($Rule) {
    $t = Get-Text $Rule 'tracker'
    if ($t) { return "t:$t" }
    return "d:$(Get-Text $Rule 'interface')|$(Get-Text $Rule 'descr')"
}

function Get-RuleSummary($Rule) {
    $st = 'ativa'; if (Test-Flag $Rule 'disabled') { $st = 'DESATIVADA' }
    $proto = Get-Text $Rule 'protocol'; if (-not $proto) { $proto = 'qualquer' }
    return ('{0} {1} {2} {3} -> {4} [{5}] "{6}"' -f (Get-Text $Rule 'type'), (Get-Text $Rule 'interface'), $proto,
        (Format-Endpoint $Rule.source), (Format-Endpoint $Rule.destination), $st, (Get-Text $Rule 'descr'))
}

function Compare-Config($New, $Old) {
    # Mudancas relevantes entre dois config.xml. Devolve lista de @(tipo, item, detalhe).
    $chg = New-Object System.Collections.ArrayList
    if ($null -eq $Old) { return , $chg }

    $or = @{}; foreach ($r in (Get-List $Old.pfsense.filter.rule)) { $or[(Get-RuleKey $r)] = $r }
    $nr = @{}; foreach ($r in (Get-List $New.pfsense.filter.rule)) { $nr[(Get-RuleKey $r)] = $r }
    foreach ($k in $nr.Keys) {
        if (-not $or.ContainsKey($k)) { [void]$chg.Add(@('Regra criada', (Get-RuleSummary $nr[$k]), '')) }
        elseif ((Get-RuleSummary $nr[$k]) -ne (Get-RuleSummary $or[$k])) { [void]$chg.Add(@('Regra alterada', (Get-RuleSummary $nr[$k]), "antes: $(Get-RuleSummary $or[$k])")) }
    }
    foreach ($k in $or.Keys) { if (-not $nr.ContainsKey($k)) { [void]$chg.Add(@('Regra removida', (Get-RuleSummary $or[$k]), '')) } }

    $ou = @{}; foreach ($u in (Get-List $Old.pfsense.system.user)) { $ou[(Get-Text $u 'name')] = $u }
    $nu = @{}; foreach ($u in (Get-List $New.pfsense.system.user)) { $nu[(Get-Text $u 'name')] = $u }
    foreach ($k in $nu.Keys) {
        if (-not $ou.ContainsKey($k)) { [void]$chg.Add(@('Usuario criado', $k, (Get-Text $nu[$k] 'descr'))) }
        elseif ((Test-Flag $nu[$k] 'disabled') -ne (Test-Flag $ou[$k] 'disabled')) {
            $s = 'reativado'; if (Test-Flag $nu[$k] 'disabled') { $s = 'desativado' }
            [void]$chg.Add(@('Usuario alterado', $k, $s))
        }
    }
    foreach ($k in $ou.Keys) { if (-not $nu.ContainsKey($k)) { [void]$chg.Add(@('Usuario removido', $k, '')) } }

    $og = @{}; foreach ($g in (Get-List $Old.pfsense.system.group)) { $og[(Get-Text $g 'name')] = (@(Get-List $g.member) | Sort-Object) -join ',' }
    foreach ($g in (Get-List $New.pfsense.system.group)) {
        $gn = Get-Text $g 'name'; $m = (@(Get-List $g.member) | Sort-Object) -join ','
        if ($og.ContainsKey($gn) -and $og[$gn] -ne $m) { [void]$chg.Add(@('Grupo alterado', $gn, "membros (uid): antes [$($og[$gn])], agora [$m]")) }
        elseif (-not $og.ContainsKey($gn)) { [void]$chg.Add(@('Grupo criado', $gn, '')) }
    }

    $oa = @{}; foreach ($a in (Get-List $Old.pfsense.aliases.alias)) { $oa[(Get-Text $a 'name')] = Get-Text $a 'address' }
    $na = @{}; foreach ($a in (Get-List $New.pfsense.aliases.alias)) { $na[(Get-Text $a 'name')] = Get-Text $a 'address' }
    foreach ($k in $na.Keys) {
        if (-not $oa.ContainsKey($k)) { [void]$chg.Add(@('Alias criado', $k, $na[$k])) }
        elseif ($oa[$k] -ne $na[$k]) { [void]$chg.Add(@('Alias alterado', $k, "antes: $($oa[$k]) | agora: $($na[$k])")) }
    }
    foreach ($k in $oa.Keys) { if (-not $na.ContainsKey($k)) { [void]$chg.Add(@('Alias removido', $k, '')) } }

    $ov = @{}; foreach ($s in (Get-List $Old.pfsense.openvpn.'openvpn-server')) { $ov[(Get-Text $s 'vpnid')] = "$(Get-Text $s 'description') $(Get-Text $s 'protocol')/$(Get-Text $s 'local_port') desativada=$(Test-Flag $s 'disable') crl=$(Get-Text $s 'crlref')" }
    foreach ($s in (Get-List $New.pfsense.openvpn.'openvpn-server')) {
        $id = Get-Text $s 'vpnid'; $v = "$(Get-Text $s 'description') $(Get-Text $s 'protocol')/$(Get-Text $s 'local_port') desativada=$(Test-Flag $s 'disable') crl=$(Get-Text $s 'crlref')"
        if (-not $ov.ContainsKey($id)) { [void]$chg.Add(@('VPN criada', (Get-Text $s 'description'), "$(Get-Text $s 'protocol')/$(Get-Text $s 'local_port')")) }
        elseif ($ov[$id] -ne $v) { [void]$chg.Add(@('VPN alterada', (Get-Text $s 'description'), '')) }
    }

    $on = @(Get-List $Old.pfsense.nat.rule).Count; $nn = @(Get-List $New.pfsense.nat.rule).Count
    if ($on -ne $nn) { [void]$chg.Add(@('NAT (port forward)', "$on -> $nn regras", '')) }

    $oc = @{}; foreach ($c in (Get-List $Old.pfsense.crl)) { $oc[(Get-Text $c 'refid')] = @(Get-List $c.cert).Count }
    foreach ($c in (Get-List $New.pfsense.crl)) {
        $n = @(Get-List $c.cert).Count; $r = Get-Text $c 'refid'
        if ($oc.ContainsKey($r) -and $n -gt $oc[$r]) { [void]$chg.Add(@('Certificado revogado', (Get-Text $c 'descr'), "$($n - $oc[$r]) novo(s)")) }
    }
    return , $chg
}

function New-Report($Cfg, $Prev, [string]$SourceFile, [string]$PrevFile) {
    $script:Sb = New-Object Text.StringBuilder
    $p = $Cfg.pfsense
    $sys = $p.system
    $host_ = "$(Get-Text $sys 'hostname').$(Get-Text $sys 'domain')"
    $agora = Get-Date
    $limiteCert = $agora.AddDays(60)

    # --- coleta dos dados -------------------------------------------------
    $users  = Get-List $sys.user
    $groups = Get-List $sys.group
    $uidName = @{}; foreach ($u in $users) { $uidName[(Get-Text $u 'uid')] = Get-Text $u 'name' }
    $userGroups = @{}
    foreach ($g in $groups) { foreach ($m in (Get-List $g.member)) { $n = $uidName[[string]$m]; if ($n) { if (-not $userGroups.ContainsKey($n)) { $userGroups[$n] = @() }; $userGroups[$n] += (Get-Text $g 'name') } } }
    $adminGroup = @($groups | Where-Object { (Get-Text $_ 'name') -eq 'admins' -or @(Get-List $_.priv) -contains 'page-all' } | ForEach-Object { Get-Text $_ 'name' })
    $rules = Get-List $p.filter.rule
    $certs = Get-List $p.cert
    $cas   = Get-List $p.ca
    $crls  = Get-List $p.crl
    $revoked = @{}; foreach ($c in $crls) { foreach ($rc in (Get-List $c.cert)) { $revoked[(Get-Text $rc 'refid')] = (Get-Text $c 'descr') } }
    $ovpn  = Get-List $p.openvpn.'openvpn-server'

    # --- pontos de atencao -----------------------------------------------
    $att = New-Object System.Collections.ArrayList
    foreach ($ce in ($certs + $cas)) {
        $i = Get-CertInfo (Get-Text $ce 'crt')
        if ($i -and -not $revoked.ContainsKey((Get-Text $ce 'refid'))) {
            if ($i.NotAfter -lt $agora) { [void]$att.Add(@('alto', "Certificado VENCIDO: $(Get-Text $ce 'descr') (venceu em $($i.NotAfter.ToString('dd/MM/yyyy')))")) }
            elseif ($i.NotAfter -lt $limiteCert) { [void]$att.Add(@('medio', "Certificado vence em menos de 60 dias: $(Get-Text $ce 'descr') ($($i.NotAfter.ToString('dd/MM/yyyy')))")) }
        }
    }
    foreach ($u in $users) {
        $n = Get-Text $u 'name'
        if ((Test-Flag $u 'disabled') -and $userGroups.ContainsKey($n) -and @($userGroups[$n] | Where-Object { $adminGroup -contains $_ }).Count -gt 0) {
            [void]$att.Add(@('medio', "Usuario DESATIVADO ainda no grupo de administradores: $n"))
        }
    }
    foreach ($s in $ovpn) {
        if (-not (Test-Flag $s 'disable') -and -not (Get-Text $s 'crlref')) { [void]$att.Add(@('medio', "VPN sem lista de revogacao (CRL): $(Get-Text $s 'description') - um certificado vazado nao pode ser cancelado")) }
    }
    if ((Test-Flag $sys.ssh 'enable') -and (Get-Text $sys.ssh 'sshdkeyonly') -notin @('enabled', 'both')) { [void]$att.Add(@('baixo', 'SSH ativo aceitando senha (o mais seguro e so chave)')) }
    $semDesc = @($rules | Where-Object { -not (Test-Flag $_ 'disabled') -and -not (Get-Text $_ 'descr') }).Count
    if ($semDesc -gt 0) { [void]$att.Add(@('baixo', "$semDesc regra(s) ativa(s) sem descricao - dificulta a auditoria")) }
    $pf = @(Get-List $p.nat.rule | Where-Object { -not (Test-Flag $_ 'disabled') })
    if ($pf.Count -gt 0) { [void]$att.Add(@('info', "$($pf.Count) redirecionamento(s) de porta (NAT) ativo(s) - confira a lista na secao NAT")) }

    $changes = Compare-Config $Cfg $Prev

    # --- HTML --------------------------------------------------------------
    Out-Html '<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">'
    Out-Html "<title>Auditoria $(H $host_) - $($agora.ToString('dd/MM/yyyy'))</title>"
    Out-Html @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;color:#1f2937;background:#f3f4f6}
header{background:#0f172a;color:#fff;padding:24px 32px}
header h1{margin:0;font-size:22px} header p{margin:4px 0 0;color:#cbd5e1;font-size:13px}
main{padding:24px 32px;max-width:1400px}
nav{background:#fff;border:1px solid #e5e7eb;border-radius:8px;padding:12px 16px;margin-bottom:20px;font-size:13px;line-height:1.9}
nav a{color:#1d4ed8;text-decoration:none;margin-right:14px}
section{background:#fff;border:1px solid #e5e7eb;border-radius:8px;padding:16px 20px;margin-bottom:20px}
h2{font-size:17px;margin:0 0 12px;border-bottom:2px solid #e5e7eb;padding-bottom:6px}
h3{font-size:14px;margin:18px 0 8px;color:#374151}
table{border-collapse:collapse;width:100%;font-size:12.5px}
th{background:#f9fafb;text-align:left;padding:6px 8px;border-bottom:1px solid #d1d5db;white-space:nowrap}
td{padding:5px 8px;border-bottom:1px solid #f1f5f9;vertical-align:top;word-break:break-word}
tr.off td{color:#9ca3af;text-decoration:line-through}
.cards{display:flex;flex-wrap:wrap;gap:12px}
.card{flex:1 1 150px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:12px}
.card b{display:block;font-size:22px}
.card span{font-size:12px;color:#6b7280}
.b{display:inline-block;padding:1px 7px;border-radius:10px;font-size:11px;font-weight:600}
.alto{background:#fee2e2;color:#991b1b}.medio{background:#fef3c7;color:#92400e}.baixo{background:#e0f2fe;color:#075985}.info{background:#f3f4f6;color:#374151}
.ok{background:#dcfce7;color:#166534}.pass{background:#dcfce7;color:#166534}.block,.reject{background:#fee2e2;color:#991b1b}
.vazio{color:#6b7280;font-style:italic;font-size:13px}
footer{color:#6b7280;font-size:12px;padding:0 32px 24px}
@media print{nav{display:none} body{background:#fff} section{break-inside:avoid-page}}
</style></head><body>
'@
    Out-Html "<header><h1>Relat&oacute;rio de auditoria do firewall &mdash; $(H $host_)</h1>"
    Out-Html "<p>Backup analisado: $(H ([IO.Path]::GetFileName($SourceFile))) &middot; gerado em $($agora.ToString('dd/MM/yyyy HH:mm')) &middot; pfSense config v$(H (Get-Text $p 'version'))"
    $rev = $p.revision
    if ($rev) { Out-Html " &middot; &uacute;ltima altera&ccedil;&atilde;o: $(H (Get-Text $rev 'description')) por $(H (Get-Text $rev 'username'))" }
    Out-Html '</p></header><main>'
    Out-Html '<nav><a href="#resumo">Resumo</a><a href="#mudancas">Mudan&ccedil;as</a><a href="#interfaces">Interfaces</a><a href="#gateways">Gateways</a><a href="#regras">Regras</a><a href="#nat">NAT</a><a href="#aliases">Aliases</a><a href="#usuarios">Usu&aacute;rios</a><a href="#vpn">OpenVPN</a><a href="#certs">Certificados</a><a href="#ipsec">IPsec</a><a href="#portal">Portal cativo</a><a href="#dhcp">DHCP</a><a href="#acesso">Acesso administrativo</a><a href="#pacotes">Pacotes</a></nav>'

    # Resumo
    $ativas = @($rules | Where-Object { -not (Test-Flag $_ 'disabled') }).Count
    $admins = @($users | Where-Object { -not (Test-Flag $_ 'disabled') -and $userGroups.ContainsKey((Get-Text $_ 'name')) -and @($userGroups[(Get-Text $_ 'name')] | Where-Object { $adminGroup -contains $_ }).Count -gt 0 }).Count
    Out-Html '<section id="resumo"><h2>Resumo</h2><div class="cards">'
    foreach ($c in @(@(@(Get-List $p.interfaces.ChildNodes).Count, 'interfaces'), @($ativas, 'regras ativas'), @((@($rules).Count - $ativas), 'regras desativadas'),
                     @(@(Get-List $p.aliases.alias).Count, 'aliases'), @(@($users | Where-Object { -not (Test-Flag $_ 'disabled') }).Count, 'usu&aacute;rios ativos'),
                     @($admins, 'administradores'), @(@($ovpn | Where-Object { -not (Test-Flag $_ 'disable') }).Count, 'VPNs OpenVPN ativas'),
                     @(@(Get-List $p.ipsec.phase1).Count, 't&uacute;neis IPsec'), @($changes.Count, 'mudan&ccedil;as desde o backup anterior'))) {
        Out-Html "<div class=""card""><b>$($c[0])</b><span>$($c[1])</span></div>"
    }
    Out-Html '</div><h3>Pontos de aten&ccedil;&atilde;o</h3>'
    $ordem = @{ alto = 0; medio = 1; baixo = 2; info = 3 }
    Out-Table @('N&iacute;vel', 'Item') @($att | Sort-Object { $ordem[$_[0]] } | ForEach-Object { , @((Badge $_[0] $_[0]), (H $_[1])) }) 'Nenhum ponto de aten&ccedil;&atilde;o encontrado automaticamente.'
    Out-Html '</section>'

    # Mudancas
    Out-Html '<section id="mudancas"><h2>Mudan&ccedil;as desde o backup anterior</h2>'
    if ($PrevFile) {
        Out-Html "<p class=""vazio"">Comparado com $(H ([IO.Path]::GetFileName($PrevFile))).</p>"
        Out-Table @('Tipo', 'Item', 'Detalhe') @($changes | ForEach-Object { , @((H $_[0]), (H $_[1]), (H $_[2])) }) 'Nenhuma mudan&ccedil;a relevante (regras, usu&aacute;rios, grupos, aliases, VPNs, NAT, revoga&ccedil;&otilde;es).'
    } else { Out-Html '<p class="vazio">Primeiro relat&oacute;rio: n&atilde;o h&aacute; backup anterior para comparar.</p>' }
    Out-Html '</section>'

    # Interfaces
    $vlans = @{}; foreach ($v in (Get-List $p.vlans.vlan)) { $vlans[(Get-Text $v 'vlanif')] = "VLAN $(Get-Text $v 'tag') sobre $(Get-Text $v 'if')" }
    $rows = @()
    foreach ($i in (Get-List $p.interfaces.ChildNodes)) {
        if ($i.NodeType -ne 'Element') { continue }
        $ip = Get-Text $i 'ipaddr'; if ((Get-Text $i 'subnet')) { $ip = "$ip/$(Get-Text $i 'subnet')" }
        $st = Badge 'desativada' 'info'; if (Test-Flag $i 'enable') { $st = Badge 'ativa' 'ok' }
        $rows += , @((H $i.LocalName), (H (Get-Text $i 'descr')), (H (Get-Text $i 'if')), (H $vlans[(Get-Text $i 'if')]), (H $ip), $st)
    }
    Out-Html '<section id="interfaces"><h2>Interfaces e VLANs</h2>'
    Out-Table @('Chave', 'Nome', 'Porta', 'VLAN', 'Endere&ccedil;o', 'Status') $rows
    Out-Html '</section>'

    # Gateways
    $rows = @()
    foreach ($g in (Get-List $p.gateways.gateway_item)) { $rows += , @((H (Get-Text $g 'name')), (H (Get-IfName $Cfg (Get-Text $g 'interface'))), (H (Get-Text $g 'gateway')), (H (Get-Text $g 'monitor')), (H (Get-Text $g 'descr'))) }
    Out-Html '<section id="gateways"><h2>Gateways</h2>'
    Out-Table @('Nome', 'Interface', 'Gateway', 'Monitorado', 'Descri&ccedil;&atilde;o') $rows
    $rows = @(); foreach ($g in (Get-List $p.gateways.gateway_group)) { $rows += , @((H (Get-Text $g 'name')), (H ((Get-List $g.item) -join ', ')), (H (Get-Text $g 'descr'))) }
    Out-Html '<h3>Grupos de gateway (failover / balanceamento)</h3>'
    Out-Table @('Grupo', 'Membros (gateway|n&iacute;vel)', 'Descri&ccedil;&atilde;o') $rows
    Out-Html "<p class=""vazio"">Gateway padr&atilde;o IPv4: $(H (Get-Text $p.gateways 'defaultgw4'))</p></section>"

    # Regras por interface (na ordem em que o pfSense avalia)
    Out-Html '<section id="regras"><h2>Regras do firewall</h2><p class="vazio">Na ordem de avalia&ccedil;&atilde;o. Riscadas = desativadas.</p>'
    $porIf = [ordered]@{}
    foreach ($r in $rules) {
        $k = Get-Text $r 'interface'; if (Test-Flag $r 'floating') { $k = '(flutuantes)' }
        if (-not $porIf.Contains($k)) { $porIf[$k] = @() }
        $porIf[$k] += $r
    }
    foreach ($k in $porIf.Keys) {
        $nome = $k; if ($k -ne '(flutuantes)') { $nome = Get-IfName $Cfg $k }
        Out-Html "<h3>$(H $nome) &mdash; $(@($porIf[$k]).Count) regra(s)</h3>"
        $rows = @(); $n = 0
        foreach ($r in $porIf[$k]) {
            $n++
            $tipo = Get-Text $r 'type'
            $proto = Get-Text $r 'protocol'; if (-not $proto) { $proto = 'qualquer' }
            $log = ''; if (Test-Flag $r 'log') { $log = 'sim' }
            $cells = @("$n", (Badge $tipo $tipo), (H $proto), (H (Format-Endpoint $r.source)), (H (Format-Endpoint $r.destination)), (H (Get-Text $r 'gateway')), $log, (H (Get-Text $r 'descr')), (H (Get-Text $r 'tracker')))
            if (Test-Flag $r 'disabled') { $rows += @{ Class = 'off'; Cells = $cells } } else { $rows += , $cells }
        }
        Out-Table @('#', 'A&ccedil;&atilde;o', 'Protocolo', 'Origem', 'Destino', 'Gateway', 'Log', 'Descri&ccedil;&atilde;o', 'ID') $rows
    }
    Out-Html '</section>'

    # NAT
    Out-Html '<section id="nat"><h2>NAT</h2><h3>Redirecionamento de portas (port forward)</h3>'
    $rows = @()
    foreach ($r in (Get-List $p.nat.rule)) {
        $cells = @((H (Get-IfName $Cfg (Get-Text $r 'interface'))), (H (Get-Text $r 'protocol')), (H (Format-Endpoint $r.source)), (H (Format-Endpoint $r.destination)), (H ("$(Get-Text $r 'target'):$(Get-Text $r 'local-port')")), (H (Get-Text $r 'descr')))
        if (Test-Flag $r 'disabled') { $rows += @{ Class = 'off'; Cells = $cells } } else { $rows += , $cells }
    }
    Out-Table @('Interface', 'Protocolo', 'Origem', 'Destino', 'Redireciona para', 'Descri&ccedil;&atilde;o') $rows 'Nenhum redirecionamento de porta.'
    Out-Html "<h3>NAT de sa&iacute;da (modo: $(H (Get-Text $p.nat.outbound 'mode')))</h3>"
    $rows = @()
    foreach ($r in (Get-List $p.nat.outbound.rule)) {
        $cells = @((H (Get-IfName $Cfg (Get-Text $r 'interface'))), (H (Format-Endpoint $r.source)), (H (Format-Endpoint $r.destination)), (H (Get-Text $r 'target')), (H (Get-Text $r 'descr')))
        if (Test-Flag $r 'disabled') { $rows += @{ Class = 'off'; Cells = $cells } } else { $rows += , $cells }
    }
    Out-Table @('Interface', 'Origem', 'Destino', 'Traduz para', 'Descri&ccedil;&atilde;o') $rows 'Sem regras manuais (s&oacute; as autom&aacute;ticas).'
    Out-Html '</section>'

    # Aliases
    $rows = @(); foreach ($a in (Get-List $p.aliases.alias)) { $rows += , @((H (Get-Text $a 'name')), (H (Get-Text $a 'type')), (H ((Get-Text $a 'address') -replace ' ', ', ')), (H (Get-Text $a 'descr'))) }
    Out-Html '<section id="aliases"><h2>Aliases</h2>'
    Out-Table @('Nome', 'Tipo', 'Conte&uacute;do', 'Descri&ccedil;&atilde;o') $rows
    Out-Html '</section>'

    # Usuarios e grupos
    Out-Html '<section id="usuarios"><h2>Usu&aacute;rios e grupos</h2>'
    $rows = @()
    foreach ($u in $users) {
        $n = Get-Text $u 'name'
        $gs = @(); if ($userGroups.ContainsKey($n)) { $gs = $userGroups[$n] }
        $isAdmin = @($gs | Where-Object { $adminGroup -contains $_ }).Count -gt 0 -or (Get-Text $u 'uid') -eq '0'
        $st = Badge 'ativo' 'ok'; if (Test-Flag $u 'disabled') { $st = Badge 'desativado' 'info' }
        $adm = ''; if ($isAdmin) { $adm = Badge 'ADMIN' 'alto' }
        $ssh = ''; if (Get-Text $u 'authorizedkeys') { $ssh = 'sim' }
        $exp = Get-Text $u 'expires'
        $cells = @("$(H $n) $adm", (H (Get-Text $u 'descr')), $st, (H ($gs -join ', ')), (H ((Get-List $u.priv) -join ', ')), $ssh, (H $exp))
        if (Test-Flag $u 'disabled') { $rows += @{ Class = 'off'; Cells = $cells } } else { $rows += , $cells }
    }
    Out-Table @('Usu&aacute;rio', 'Nome completo', 'Status', 'Grupos', 'Privil&eacute;gios diretos', 'Chave SSH', 'Expira') $rows
    Out-Html '<h3>Grupos</h3>'
    $rows = @()
    foreach ($g in $groups) {
        $mem = @(Get-List $g.member | ForEach-Object { $x = $uidName[[string]$_]; if ($x) { $x } else { "uid $_" } })
        $rows += , @((H (Get-Text $g 'name')), (H (Get-Text $g 'description')), (H ($mem -join ', ')), (H ((Get-List $g.priv) -join ', ')))
    }
    Out-Table @('Grupo', 'Descri&ccedil;&atilde;o', 'Membros', 'Privil&eacute;gios') $rows
    Out-Html '</section>'

    # OpenVPN
    $caName = @{}; foreach ($c in $cas) { $caName[(Get-Text $c 'refid')] = Get-Text $c 'descr' }
    $rows = @()
    foreach ($s in $ovpn) {
        $crl = Badge 'sem CRL' 'medio'; if (Get-Text $s 'crlref') { $crl = Badge 'com CRL' 'ok' }
        $st = Badge 'ativa' 'ok'; if (Test-Flag $s 'disable') { $st = Badge 'desativada' 'info' }
        $ina = Get-Text $s 'inactive_seconds'; if ($ina) { $ina = "${ina}s" }
        $cells = @((H (Get-Text $s 'vpnid')), (H (Get-Text $s 'description')), $st, (H ("$(Get-Text $s 'protocol') $(Get-Text $s 'local_port')")), (H (Get-IfName $Cfg (Get-Text $s 'interface'))),
                   (H (Get-Text $s 'tunnel_network')), (H (Get-Text $s 'local_network')), (H "$(Get-Text $s 'data_ciphers') / $(Get-Text $s 'digest') / tls-$(Get-Text $s 'tls_type')"),
                   (H $caName[(Get-Text $s 'caref')]), $crl, (H $ina))
        if (Test-Flag $s 'disable') { $rows += @{ Class = 'off'; Cells = $cells } } else { $rows += , $cells }
    }
    Out-Html '<section id="vpn"><h2>OpenVPN</h2>'
    Out-Table @('ID', 'Descri&ccedil;&atilde;o', 'Status', 'Porta', 'Interface', 'T&uacute;nel', 'Redes liberadas', 'Criptografia', 'CA', 'Revoga&ccedil;&atilde;o', 'Inatividade') $rows 'Nenhum servidor OpenVPN.'
    Out-Html '</section>'

    # Certificados
    $rows = @()
    foreach ($ce in @($cas | ForEach-Object { @{ T = 'CA'; N = $_ } }) + @($certs | ForEach-Object { @{ T = 'Certificado'; N = $_ } })) {
        $i = Get-CertInfo (Get-Text $ce.N 'crt')
        $val = ''; $st = ''
        if ($i) {
            $val = $i.NotAfter.ToString('dd/MM/yyyy')
            if ($i.NotAfter -lt $agora) { $st = Badge 'vencido' 'alto' } elseif ($i.NotAfter -lt $limiteCert) { $st = Badge 'vence em breve' 'medio' } else { $st = Badge 'v&aacute;lido' 'ok' }
        }
        if ($revoked.ContainsKey((Get-Text $ce.N 'refid'))) { $st = Badge "revogado ($($revoked[(Get-Text $ce.N 'refid')]))" 'info' }
        $emissor = ''; if ($ce.T -eq 'Certificado') { $emissor = $caName[(Get-Text $ce.N 'caref')] }
        $subj = ''; if ($i) { $subj = $i.Subject }
        $rows += , @((H $ce.T), (H (Get-Text $ce.N 'descr')), (H $subj), (H $emissor), (H $val), $st)
    }
    Out-Html '<section id="certs"><h2>Certificados e autoridades (CA)</h2>'
    Out-Table @('Tipo', 'Nome', 'Titular', 'Emitido por', 'V&aacute;lido at&eacute;', 'Situa&ccedil;&atilde;o') $rows
    $rows = @(); foreach ($c in $crls) { $rows += , @((H (Get-Text $c 'descr')), (H $caName[(Get-Text $c 'caref')]), (H "$(@(Get-List $c.cert).Count)"), (H ((Get-List $c.cert | ForEach-Object { Get-Text $_ 'descr' }) -join ', '))) }
    Out-Html '<h3>Listas de revoga&ccedil;&atilde;o (CRL)</h3>'
    Out-Table @('Lista', 'CA', 'Revogados', 'Certificados revogados') $rows 'Nenhuma CRL.'
    Out-Html '</section>'

    # IPsec (sem PSK)
    $rows = @()
    foreach ($ph in (Get-List $p.ipsec.phase1)) {
        $id = Get-Text $ph 'ikeid'
        $p2 = @(Get-List $p.ipsec.phase2 | Where-Object { (Get-Text $_ 'ikeid') -eq $id } | ForEach-Object { "$(Get-Text $_ 'descr'): $(Format-Endpoint $_.localid) <-> $(Format-Endpoint $_.remoteid)" })
        $st = Badge 'ativo' 'ok'; if (Test-Flag $ph 'disabled') { $st = Badge 'desativado' 'info' }
        $rows += , @((H $id), (H (Get-Text $ph 'descr')), $st, (H (Get-Text $ph 'remote-gateway')), (H (Get-Text $ph 'iketype')), (H (Get-Text $ph 'authentication_method')), (H ($p2 -join ' | ')))
    }
    Out-Html '<section id="ipsec"><h2>IPsec</h2>'
    Out-Table @('ID', 'Descri&ccedil;&atilde;o', 'Status', 'Gateway remoto', 'IKE', 'Autentica&ccedil;&atilde;o', 'Redes (fase 2)') $rows 'Nenhum t&uacute;nel IPsec.'
    Out-Html '<p class="vazio">Chaves pr&eacute;-compartilhadas (PSK) nunca aparecem neste relat&oacute;rio.</p></section>'

    # Portal cativo
    $rows = @()
    if ($p.captiveportal -and -not ($p.captiveportal -is [string])) {
        foreach ($z in $p.captiveportal.ChildNodes) {
            if ($z.NodeType -ne 'Element') { continue }
            $st = Badge 'desativado' 'info'; if (Test-Flag $z 'enable') { $st = Badge 'ativo' 'ok' }
            $vou = 'n&atilde;o'; if ($p.voucher -and -not ($p.voucher -is [string]) -and (Test-Flag $p.voucher.($z.LocalName) 'enable')) { $vou = 'sim' }
            $rows += , @((H (Get-Text $z 'zone')), (H (Get-Text $z 'descr')), $st, (H (Get-IfName $Cfg (Get-Text $z 'interface'))), (H (Get-Text $z 'auth_method')), (H (Get-Text $z 'timeout')), (H (Get-Text $z 'idletimeout')), $vou)
        }
    }
    Out-Html '<section id="portal"><h2>Portal cativo (visitantes)</h2>'
    Out-Table @('Zona', 'Descri&ccedil;&atilde;o', 'Status', 'Interfaces', 'Autentica&ccedil;&atilde;o', 'Tempo m&aacute;x. (min)', 'Ociosidade (min)', 'Vouchers') $rows 'Nenhum portal cativo.'
    Out-Html '<p class="vazio">Os acessos dos visitantes (nome, CPF, MAC, IP) ficam nas planilhas da pasta <b>visitantes</b>, geradas pela coleta de logs.</p></section>'

    # DHCP
    Out-Html '<section id="dhcp"><h2>DHCP</h2>'
    $rows = @(); $res = @()
    if ($p.dhcpd -and -not ($p.dhcpd -is [string])) {
        foreach ($d in $p.dhcpd.ChildNodes) {
            if ($d.NodeType -ne 'Element') { continue }
            $st = Badge 'desativado' 'info'; if (Test-Flag $d 'enable') { $st = Badge 'ativo' 'ok' }
            $deny = ''; if (Test-Flag $d 'denyunknown') { $deny = 'sim' }
            $rows += , @((H (Get-IfName $Cfg $d.LocalName)), $st, (H "$(Get-Text $d.range 'from') - $(Get-Text $d.range 'to')"), (H ((Get-List $d.dnsserver) -join ', ')), $deny, (H "$(@(Get-List $d.staticmap).Count)"))
            foreach ($m in (Get-List $d.staticmap)) { $res += , @((H (Get-IfName $Cfg $d.LocalName)), (H (Get-Text $m 'ipaddr')), (H (Get-Text $m 'mac')), (H (Get-Text $m 'hostname')), (H (Get-Text $m 'descr'))) }
        }
    }
    Out-Table @('Interface', 'Status', 'Faixa', 'DNS entregue', 'S&oacute; aparelhos cadastrados', 'Reservas') $rows 'DHCP n&atilde;o configurado.'
    Out-Html '<h3>Reservas (IP fixo por MAC)</h3>'
    Out-Table @('Interface', 'IP', 'MAC', 'Nome', 'Descri&ccedil;&atilde;o') $res 'Nenhuma reserva.'
    Out-Html '</section>'

    # Acesso administrativo
    $wg = $sys.webgui
    $rows = @(
        , @('WebGUI', (H "$(Get-Text $wg 'protocol') porta $(Get-Text $wg 'port')"))
        , @('Regra anti-bloqueio da WebGUI', (H $(if (Test-Flag $wg 'noantilockout') { 'desativada (acesso so pelas regras)' } else { 'ativa (LAN sempre acessa o painel)' })))
        , @('SSH', (H $(if (Test-Flag $sys.ssh 'enable') { "ativo, porta $(Get-Text $sys.ssh 'port'), autenticacao: $(if (Get-Text $sys.ssh 'sshdkeyonly') { Get-Text $sys.ssh 'sshdkeyonly' } else { 'senha' })" } else { 'desativado' })))
        , @('Fuso hor&aacute;rio', (H (Get-Text $sys 'timezone')))
        , @('Servidores DNS do firewall', (H ((Get-List $sys.dnsserver) -join ', ')))
        , @('Log remoto (syslog)', (H $(if (Test-Flag $p.syslog 'enable') { Get-Text $p.syslog 'remoteserver' } else { 'desligado' })))
    )
    Out-Html '<section id="acesso"><h2>Acesso administrativo e sistema</h2>'
    Out-Table @('Item', 'Configura&ccedil;&atilde;o') $rows
    Out-Html '</section>'

    # Pacotes
    $rows = @(); foreach ($pk in (Get-List $p.installedpackages.package)) { $rows += , @((H (Get-Text $pk 'name')), (H (Get-Text $pk 'version'))) }
    Out-Html '<section id="pacotes"><h2>Pacotes instalados</h2>'
    Out-Table @('Pacote', 'Vers&atilde;o') $rows
    Out-Html '</section></main>'
    Out-Html "<footer>Gerado pelo pfSense-Backup a partir do config.xml. Nenhuma senha, chave ou segredo &eacute; exibido. Arquivo de origem: $(H $SourceFile)</footer></body></html>"
    return $script:Sb.ToString()
}

function Get-Backups([string]$Dir) {
    return @(Get-ChildItem $Dir -Filter "config-$Name-*" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

# ------------------------------- main ---------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

$BkDir  = Join-Path $BaseDir "backups\$Name"
$AudDir = Join-Path $BaseDir "auditoria\$Name"
try {
    if (-not $File) {
        $bks = Get-Backups $BkDir
        if ($bks.Count -eq 0) { throw "nenhum backup em $BkDir." }
        $File = $bks[0].FullName
        if (-not $Previous) {
            $ant = @($bks | Select-Object -Skip 1 | Where-Object { $_.Name -like '*.xml' } | Select-Object -First 1)
            if ($ant.Count -gt 0) { $Previous = $ant[0].FullName }
        }
    }
    if ($File -like '*.enc') {
        Write-Host "Relatorio pulado: o backup e criptografado ($([IO.Path]::GetFileName($File)))."
        exit 0
    }
    if (-not $Force -and -not $OutFile -and $Previous -and (Test-Path (Join-Path $AudDir 'ultimo.html')) -and
        (Get-FileHash $File).Hash -eq (Get-FileHash $Previous).Hash) {
        Write-Host 'Relatorio nao gerado: a configuracao nao mudou desde o backup anterior (o ultimo.html continua valido).'
        exit 0
    }
    $cfgX = New-Object Xml.XmlDocument; $cfgX.Load($File)
    $prevX = $null
    if ($Previous -and (Test-Path $Previous)) { try { $prevX = New-Object Xml.XmlDocument; $prevX.Load($Previous) } catch { $prevX = $null; $Previous = '' } }
    $html = New-Report $cfgX $prevX $File $Previous
    $enc = New-Object Text.UTF8Encoding($true)
    if ($OutFile) {
        [IO.File]::WriteAllText($OutFile, $html, $enc)
        Write-Host "Relatorio gerado: $OutFile"
    } else {
        $agora = Get-Date
        $dir = Join-Path $AudDir $agora.ToString('yyyy')
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $out = Join-Path $dir ("auditoria-$Name-" + $agora.ToString('yyyy-MM-dd_HHmm') + '.html')
        [IO.File]::WriteAllText($out, $html, $enc)
        Copy-Item $out (Join-Path $AudDir 'ultimo.html') -Force
        Write-Host "Relatorio gerado: $out"
    }
    exit 0
} catch {
    Write-Host "ERRO ao gerar o relatorio: $($_.Exception.Message)"
    exit 1
}
