# Problemas comuns

[← README](../README.md) · [Instalação](instalacao.md) · [Configuração](configuracao.md) · [Monitoramento](monitoramento.md)

A mensagem aparece no log (`C:\pfSense-Backup\logs\<Nome>\<Nome>.log`), em `status\<Nome>\mensagem.txt` e no evento 1001.

## Conexão

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `curl falhou (exit 7)` / `(exit 28)` | Não conectou ou deu timeout | Conferir IP, porta e regra de firewall (`Test-NetConnection <ip> -Port <porta>`) |
| `curl falhou (exit 35)` / `(exit 60)` | Problema de TLS | Conferir se a porta é mesmo a HTTPS da WebGUI |
| `nao achei o token CSRF na tela de login` | Não é um pfSense, ou a porta é HTTP | Conferir host e porta |
| `tentativa 1 de 3 falhou: ...` | Falha temporária de rede | Nada: o script tenta de novo sozinho |
| `XML invalido/incompleto` | Download cortado | Já é repetido. Se continuar, aumentar `MaxTime` no JSON |

## Certificado

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `chave do certificado do pfSense NAO confere` (exit 90) | O certificado da WebGUI foi renovado **ou** outro equipamento está respondendo no lugar do firewall. A senha **não** foi enviada | Confirmar se houve troca do certificado. Se sim: instalador com `-TrustNewCert`. Se não: investigar a rede |
| `A chave do certificado do pfSense MUDOU desde o cadastro` | A mesma situação, detectada no instalador | Idem |
| `AVISO: perfil sem PubKeyPin` | O instalador não conseguiu ler o certificado | Rodar o instalador de novo com o pfSense acessível |

## Usuário e permissões no pfSense

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `login recusado` | Senha errada ou usuário desativado | Conferir no pfSense e rodar `-UpdatePassword` |
| `logou mas NAO tem acesso a pagina de backup` | Privilégio errado, quase sempre os itens **Auto Config Backup** | Deixar **só** `WebCfg - Diagnostics: Backup & Restore` no grupo |
| `tem privilegio DEMAIS (acessa: …)` | Usuário no grupo `admins` ou com privilégios extras | Deixar só no `BACKUP-PFSENSE`, sem privilégios próprios |
| `Nao use 'admin'` | Tentou usar o admin | Criar o usuário dedicado ([Instalação](instalacao.md)) |
| `Verificacao REPROVADA - a tarefa NAO foi criada` | Uma das linhas acima | Ler a mensagem logo acima dela |
| `arquivo pequeno demais` | O pfSense devolveu uma página de erro | Ver o "Inicio:" na mensagem; normalmente é login ou privilégio |
| IP do servidor bloqueado após vários erros | sshguard do pfSense | Corrigir a senha e liberar em *Diagnostics › Tables › sshguard* |

## Logs (versão 2)

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `FALTA <fonte> -> inclua no grupo: ...` | Falta o privilégio daquela fonte | Incluir no grupo `LOGS-PFSENSE` o privilégio mostrado. Lembre: `Logs: System` **não** libera os outros logs |
| `<fonte>: sem acesso ...` no status `AVISO` | Mesmo caso, durante a coleta | Idem, ou tirar a fonte com `-LogSources` |
| `possivel lacuna (mais de N linhas ...)` | O pfSense gerou mais linhas do que o pedido entre duas coletas | Aumentar `-LogLines` (ex.: 20000) ou diminuir `-LogEvery` (ex.: 15) |
| `verificacao dos logs REPROVADA` | Login falhou ou o usuário ficou com privilégio administrativo | Ler a mensagem acima; o backup continua normal |
| `a chave SSH NAO esta travada` | A linha colada no pfSense não é a gerada pelo instalador (sem o `command=`) | Colar a linha inteira de `config\<Nome>-chave-ssh-pfsense.txt` |
| `o pfSense recusou a chave SSH do servidor` | Chave não colada no usuário, ou sem `Shell account access` | Ver [Logs › Modo SSH](logs.md#preparar-o-pfsense) |
| `a chave SSH do pfSense NAO confere` | pfSense reinstalado ou outro equipamento no lugar | Conferir e rodar o instalador com `-TrustNewSshKey` |
| `FALTA <fonte> -> nao encontrado ou sem permissao de leitura` | Script de permissões não rodou, ou o pacote não existe | Rodar `pfsense-backup-permissoes.sh` no pfSense e agendar |
| `o pfSense nao respondeu ao SSH` | SSH desligado, porta errada ou regra bloqueando | Conferir a porta (`-SshPort`) e a regra para o IP do servidor |
| `lightsquid: usuario/senha do LightSquid recusados` | Senha do LightSquid mudou | `-UpdateLightSquidPassword` |
| `outra coleta deste firewall ainda esta rodando` | A coleta anterior ainda não terminou | Normal de vez em quando; se for sempre, aumente `-LogEvery` |
| Relatório não gerado: `configuracao nao mudou` | Nada mudou desde o backup anterior | Normal: o `ultimo.html` continua valendo. `-Force` gera mesmo assim |
| Relatório pulado: `backup e criptografado` | Perfil com `-Encrypt` | O `.xml.enc` não pode ser lido. É esperado |

## curl

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `curl.exe nao encontrado` | Server 2016 / 2012 R2 | Responder `S` quando o instalador oferecer baixar, ou copiar o `curl.exe` para `C:\pfSense-Backup\bin\` |
| `nao consegui baixar o curl` | Sem internet, proxy ou TLS bloqueado | Copiar o curl na mão ([Instalação](instalacao.md#windows-server-2016-e-2012-r2-o-curl)) |
| `... antigo demais` / `curl falhou (exit 2)` | curl anterior ao 7.44 | Baixar o atual em https://curl.se/windows/ |

## Windows

| Mensagem | Causa provável | O que fazer |
|---|---|---|
| `O acesso ao caminho ... foi negado` | Instalação feita com uma versão antiga do instalador | Rodar o instalador atual de novo. Se persistir: `takeown /F C:\pfSense-Backup /R /A /D S` (Windows em inglês: `/D Y`) |
| `icacls falhou ao aplicar a heranca` | Arquivos com outro dono | `takeown` acima e rodar o instalador de novo |
| `Key not valid for use in specified state` | Chave e senha não combinam | `-UpdatePassword` |
| Funciona no teste, falha na tarefa | Permissão diferente para `SYSTEM` | Rodar o instalador de novo e testar com `schtasks /Run` |
| Status `AVISO` / evento 1002 | Cópia externa falhou | Dar permissão de gravação a `DOMINIO\SERVIDOR$` no compartilhamento |

## Ver o que está acontecendo

Rodar o backup no console mostra cada passo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\pfSense-Backup\Backup-pfSense.ps1 -Name FWCLIENTE
```
