# Instalação

[← README](../README.md) · [Configuração](configuracao.md) · [Monitoramento](monitoramento.md) · [Problemas](problemas.md)

Passo a passo para cadastrar um firewall pfSense no backup automático.

## 1. Preparar o pfSense

O backup usa um **usuário dedicado** que só tem permissão de backup. O instalador confere isso e **se recusa** a continuar se o usuário não conseguir baixar o backup ou se tiver permissão demais.

**Grupo:** *System › User Manager › Groups › Add*

| Campo | Valor |
|---|---|
| Group name | `BACKUP-PFSENSE` |
| Scope | `Local` |
| Assigned Privileges | **somente** `WebCfg - Diagnostics: Backup & Restore` |

> ⚠️ Não use os itens `WebCfg - Services: Auto Config Backup…`. Eles parecem certos, mas são do backup na nuvem da Netgate, outro recurso. Com eles o login funciona e o backup falha.

**Usuário:** *System › User Manager › Users › Add*

| Campo | Valor |
|---|---|
| Username | `srvbackup-pfsense` |
| Password | uma senha forte (você vai digitá-la no instalador) |
| Group membership | **só** `BACKUP-PFSENSE`, nunca `admins` |
| Effective Privileges | vazio (a permissão vem do grupo) |

> ⚠️ **Trate essa senha como senha de admin.** O privilégio *Backup & Restore* também permite **restaurar** uma configuração, o que dá controle total do firewall. Veja [Segurança](seguranca.md).

## 2. Liberar o acesso (se precisar)

Na mesma LAN, normalmente já funciona. Se o servidor estiver em outra rede, VLAN ou VPN, crie uma regra liberando `IP do servidor → IP do pfSense : porta da WebGUI (TCP)`. Para testar:

```powershell
Test-NetConnection 172.16.10.1 -Port 10443
```

## 3. Copiar os scripts para o servidor

Baixe o repositório (**Code › Download ZIP**), extraia em qualquer pasta do servidor e desbloqueie os arquivos:

```powershell
Get-ChildItem .\*.ps1 | Unblock-File
```

## 4. Rodar o instalador

Abra o **Windows PowerShell como Administrador**, entre na pasta dos scripts e rode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 172.16.10.1
```

| Parâmetro | Para que serve |
|---|---|
| `-Name FWCLIENTE` | Nome do cadastro (só letras, números, `-` e `_`). Vira o nome da pasta de backups, do log e da tarefa. Use um por firewall. |
| `-FwHost 172.16.10.1` | IP do pfSense, como o servidor enxerga. Obrigatório só na primeira vez. |

O resto o instalador **pergunta**, sempre mostrando o padrão entre colchetes. **ENTER mantém** o valor:

| Pergunta | Padrão | Explicação |
|---|---|---|
| Porta HTTPS da WebGUI | `[443]` | O número depois de `:` no endereço do pfSense (`https://172.16.10.1:10443` → `10443`). Sem número, é 443. |
| Horário do backup diário | `[02:00]` | Formato 24h (`HH:mm`). Prefira fora do expediente. |
| Dias guardados | `[90]` | Backups mais velhos que isso são apagados sozinhos. |
| Mínimo de backups mantidos | `[10]` | Os N mais recentes **nunca** são apagados, mesmo que velhos. Protege se o backup parar de funcionar por semanas. |
| Pré-requisito no pfSense feito? | — | Responda `S` depois do passo 1. |
| Senha do usuário do pfSense | — | Digitada duas vezes, gravada cifrada. |
| A impressão digital do certificado confere? | — | Compare com o que o navegador mostra (cadeado › certificado › detalhes) e responda `S`. |

> Valores digitados errado (porta `abc`, horário `25:00`) são recusados e a pergunta se repete. Qualquer resposta pode vir pronta no comando (`-Port 10443 -Time 03:00 -KeepDays 180 -MinKeep 20`). Com `-Yes`, nada é perguntado. Todos os parâmetros estão em [Configuração](configuracao.md).

### Windows Server 2016 e 2012 R2: o curl

A **primeira coisa** que o instalador faz é identificar o Windows. O curl (ferramenta open source que o backup usa para falar com a WebGUI) vem de fábrica só a partir do build 17134:

| Windows | curl de fábrica? | O que acontece |
|---|---|---|
| Windows 10 1803+ / 11, Server 2019 / 2022 / 2025 | ✅ | Nada é baixado |
| Server 2016 (build 14393), Server 2012 R2 | ❌ | O instalador explica e **pergunta** antes de baixar |

Quando falta o curl, ele **para antes de pedir senha** e mostra o que vai fazer: baixar o ZIP oficial de `https://curl.se` por HTTPS, extrair **só** o `curl.exe` para `C:\pfSense-Backup\bin\curl.exe` e exibir o SHA‑256 do arquivo. Nada é instalado no Windows: sem instalador, sem `PATH`, sem registro. Para remover, basta apagar a pasta `bin`.

**Servidor sem internet?** Num PC com internet, baixe o curl em https://curl.se/windows/, copie o `bin\curl.exe` do ZIP para `C:\pfSense-Backup\bin\curl.exe` e rode o instalador de novo.

### O que o instalador faz depois das perguntas

1. Cria `C:\pfSense-Backup` e restringe o acesso a `SYSTEM` e `Administradores`.
2. Gera a chave e grava a senha cifrada.
3. Fixa a chave do certificado da WebGUI (pinning).
4. **Verifica o usuário no pfSense**: loga, confere o acesso ao backup e confere que ele **não** acessa páginas administrativas. Se reprovar, **para e não cria a tarefa**.
5. Cria a tarefa agendada diária, como `SYSTEM`.
6. Faz um **backup de teste** e mostra um resumo do perfil.

A lista completa do que é criado no servidor, e como desfazer, está em [Segurança](seguranca.md#o-que-o-instalador-faz-no-servidor).

> Na verificação, o pfSense registra linhas como *"srvbackup-pfsense attempted to access system_usermanager.php but does not have access"*. É esperado: é o teste confirmando que o usuário não tem acesso.

## 5. Validar como SYSTEM

O teste do instalador roda com o **seu** usuário. Para confirmar a execução agendada:

```powershell
schtasks /Run /TN "pfSense Backup - FWCLIENTE"
```

```powershell
Start-Sleep 10; Get-Content C:\pfSense-Backup\logs\FWCLIENTE\FWCLIENTE.log -Tail 5
```

O esperado:

```
2026-10-30T02:00:01  [FWCLIENTE]  Iniciando backup - https://172.16.10.1:10443 - usuario 'srvbackup-pfsense'
2026-10-30T02:00:03  [FWCLIENTE]  OK  C:\pfSense-Backup\backups\FWCLIENTE\config-FWCLIENTE-2026-10-30_0200.xml  (412.7 KB)
2026-10-30T02:00:03  [FWCLIENTE]  Concluido.
```

## 6. Monitorar

Configure o alerta no Zabbix: [Monitoramento](monitoramento.md).

## Checklist

- [ ] Grupo `BACKUP-PFSENSE` só com `WebCfg - Diagnostics: Backup & Restore`
- [ ] Usuário `srvbackup-pfsense` só nesse grupo, sem privilégios próprios
- [ ] `Test-NetConnection` OK a partir do servidor
- [ ] Instalador mostrou `usuario correto: acessa o backup e nada alem disso`
- [ ] Impressão digital do certificado conferida
- [ ] Backup de teste OK e `schtasks /Run` OK
- [ ] Alerta no Zabbix configurado
- [ ] (Recomendado) cópia fora do servidor com `-Encrypt -CopyTo` ([Configuração](configuracao.md#cópia-fora-do-servidor))
- [ ] Cadastro anotado em local interno (cliente, servidor, IP/porta, onde está a senha de criptografia)
