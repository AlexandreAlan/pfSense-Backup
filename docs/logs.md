# Coleta de logs

[← README](../README.md) · [Auditoria](auditoria.md) · [Atualização](atualizacao.md) · [Monitoramento](monitoramento.md) · [Problemas](problemas.md)

A partir da versão 2, o pfSense-Backup também **guarda os logs do pfSense** no servidor Windows, organizados por categoria e por dia, e monta a **planilha de acessos dos visitantes** do portal cativo.

Tudo passa pelo **mesmo caminho do backup**: a WebGUI, por HTTPS, com o **mesmo usuário**, a **mesma senha cifrada** e o **mesmo certificado fixado**. Nada é instalado no pfSense, e o servidor não abre nenhuma porta.

## O que é coletado

| Fonte (`LogSources`) | De onde vem | Privilégio no pfSense |
|---|---|---|
| `sistema` | Status › System Logs › General | `WebCfg - Status: Logs: System` |
| `portal` | … › Captive Portal Auth | `WebCfg - Status: System Logs: Portal Auth` |
| `openvpn` | … › OpenVPN | `WebCfg - Status: System Logs: OpenVPN` |
| `ipsec` | … › IPsec | `WebCfg - Status: System Logs: IPsec VPN` |
| `dhcp` | … › DHCP | `WebCfg - Status: Logs: DHCP` |
| `dns` | … › DNS Resolver | `WebCfg - Status: Logs: Resolver` |
| `gateways` | … › Gateways (quedas de link) | `WebCfg - Status: Logs: Gateways` |
| `firewall` | … › Firewall | `WebCfg - Status: Logs: Firewall` |
| `dhcp-concessoes` | Status › DHCP Leases (foto de quem está com cada IP) | `WebCfg - Status: DHCP leases` |
| `pfblockerng` | Firewall › pfBlockerNG › Logs (IP e DNSBL) | `WebCfg - Firewall: pfBlockerNG` |
| `suricata` | Services › Suricata › Logs View (alertas e bloqueios de cada interface) | `WebCfg - Services: suricata package.` |
| `squid`, `squidguard` | Status › Squid Proxy Monitor (acessos e bloqueios) | `WebCfg - Services: Squid package` |
| `ppp` (opcional) | … › PPP | no pfSense 2.7 aparece com o nome errado: o **segundo** `… System Logs: IPsec VPN` |
| LightSquid (opcional) | relatórios diários do pacote LightSquid | usuário e senha do próprio LightSquid |

> [!IMPORTANT]
> O pfSense confere o **endereço exato** de cada privilégio. `Status: Logs: System` libera **só** o log do sistema: cada outro log precisa do seu.

> [!WARNING]
> Os privilégios dos **pacotes** (pfBlockerNG, Suricata e Squid) também permitem **alterar** esses pacotes, porque o pfSense não tem "só leitura" para eles. Inclua só os pacotes que você vai coletar. Os privilégios dos logs do sistema são só de leitura.

**Fora da coleta:** o log *Authentication › General* (logins na WebGUI e no SSH) **não tem privilégio próprio** no pfSense, só administrador vê. Dar administrador ao usuário iria contra a verificação do instalador, que **reprova** um usuário capaz de abrir o gerenciador de usuários, as regras ou o prompt de comandos.

## Preparar o pfSense

Use o **mesmo usuário do backup** (`srvbackup-pfsense`):

1. **System › User Manager › Groups › Add**: grupo `LOGS-PFSENSE`, Scope *Local*.
2. Edite o grupo › **Assigned Privileges › Add**: marque os privilégios das fontes que você quer (tabela acima).
3. **Users** › edite o `srvbackup-pfsense` › **Group membership**: deixe-o em **`BACKUP-PFSENSE` e `LOGS-PFSENSE`** (e em nenhum outro).

## Ativar

Rode o instalador de novo, com o mesmo nome de perfil. Ele **detecta** que o perfil já existe e pergunta só o que é novo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE
```

Ou sem perguntas:

```powershell
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Logs -Yes
```

O instalador então:

1. **confere cada fonte** com o usuário real e mostra `OK` ou `FALTA <privilégio>`;
2. **reprova** se o usuário tiver privilégio de administrador;
3. cria a tarefa **`pfSense Logs - <Nome>`**, que roda como SYSTEM a cada 60 minutos;
4. faz a **primeira coleta**.

Se faltar privilégio para alguma fonte, as outras são coletadas normalmente, e o status fica em `AVISO` até você corrigir.

## Onde fica

Só aparecem as datas que tiverem dados:

```
C:\pfSense-Backup\
  logs-pfsense\FWCLIENTE\
      sistema\2026\11\2026-11-20.log
      portal-visitantes\2026\11\2026-11-20.log
      vpn-openvpn\...            vpn-ipsec\...         dhcp\...        dns\...
      gateways\...               firewall\...
      pfblockerng\ip_block\...   pfblockerng\dnsbl\...
      suricata\LAN_igb0-alerts\...   suricata\LAN_igb0-block\...
      squid-acessos\...          squidguard-bloqueios\...
      dhcp-concessoes\2026\11\2026-11-20.csv
  visitantes\FWCLIENTE\2026\acessos-2026-11.csv
  lightsquid\FWCLIENTE\2026\11\2026-11-20.html
```

- Cada `.log` tem as linhas **daquele dia**, pela data registrada na própria linha (e não pela hora em que foram coletadas).
- `dhcp-concessoes`: uma linha por concessão vista no dia (IP, MAC, nome, início, fim), com a hora em que ela apareceu pela primeira vez.
- **Retenção:** `LogKeepDays`, padrão **400 dias**, um pouco mais de 13 meses. É acima dos 6 meses que o Marco Civil da Internet exige para registros de acesso. Arquivos mais velhos são apagados sozinhos.

## Planilha de visitantes

`visitantes\<Nome>\AAAA\acessos-AAAA-MM.csv`, uma por mês. Abre direto no Excel, com acentos (UTF-8 com BOM) e `;` como separador:

| data | hora | zona | evento | cpf | nome | mac | ip | detalhe |
|---|---|---|---|---|---|---|---|---|
| 2026-11-19 | 16:51:15 | visitantes | ACCEPT | 52998224725 | Maria Ávila | aa:bb:… | 10.10.30.5 | |
| 2026-11-19 | 17:02:40 | visitantes | VOUCHER | 00232772380 | José Silva | aa:bb:… | 10.10.30.6 | codigo ABC123, 60 min |

- O **CPF** é reconhecido quando o login do portal começa com 11 dígitos (`<cpf> <nome>`), como no portal personalizado. Em portais que pedem só o nome, a coluna fica vazia.
- Eventos comuns: `ACCEPT` (entrou), `VOUCHER` (entrou com código), `DISCONNECT`/`LOGOUT` (saiu), `TIMEOUT`, `IDLE TIMEOUT`, `FAILURE`.

> [!CAUTION]
> **LGPD:** a planilha tem nome e CPF. A pasta já é restrita a SYSTEM e Administradores pelo instalador. Combine com o cliente quem pode consultá-la.

## Como a coleta funciona (incremental)

A cada execução, o script pede as **últimas N linhas** de cada log (`LogLines`, padrão 5000), acha **onde a coleta anterior parou** e grava **só o que é novo**. O controle fica em `state\<Nome>\`.

- **pfBlockerNG e Suricata:** o arquivo inteiro é baixado e só as linhas novas são gravadas.
- **Lacuna:** se entre duas coletas o pfSense gerar mais linhas do que `LogLines` (comum no **firewall** e no **DNS** em redes grandes), parte se perde. O status vira `AVISO` com "possível lacuna". Resolva aumentando `LogLines` (ex.: `-LogLines 20000`) ou rodando mais vezes (`-LogEvery 15`).
- **Uma coleta por vez:** se a anterior ainda estiver rodando, a nova sai sem fazer nada.

## LightSquid

Se o pfSense tiver o pacote **LightSquid**, o instalador pergunta o endereço (padrão `http://<pfSense>:7445`), o usuário e a senha dele. A senha fica cifrada em `secrets\<Nome>.lightsquid.pass`.

- Guarda a página de **cada dia que existir** (`lightsquid\<Nome>\AAAA\MM\AAAA-MM-DD.html`) e o índice de cada mês.
- Dias antigos são baixados **uma vez só**. Os 2 últimos dias são atualizados a cada coleta.
- As páginas apontam para o LightSquid para carregar estilos e gráficos. Os números e as tabelas ficam no arquivo.

> [!WARNING]
> Por padrão, o LightSquid responde em **HTTP**, e a senha dele trafega aberta na rede. Ative o SSL no pacote (Services › Squid › LightSquid) e use `https://` no endereço.

## Configuração (`config\<Nome>.json`)

| Campo | Padrão | Para que serve |
|---|---|---|
| `Logs` | `false` | Liga a coleta |
| `LogSources` | todas as da tabela, menos `ppp` | Fontes, separadas por vírgula |
| `LogEvery` | `60` | Minutos entre coletas (tarefa agendada) |
| `LogLines` | `5000` | Linhas pedidas por log a cada coleta |
| `LogKeepDays` | `400` | Dias guardados |
| `LogMaxTime` | `600` | Tempo máximo de cada download, em segundos |
| `LightSquidUrl`, `LightSquidUser` | vazio | LightSquid (opcional) |

Para mudar, rode o instalador com o parâmetro (`-LogSources`, `-LogEvery`, `-LogLines`, `-LogKeepDays`, `-LightSquidUrl`, `-LightSquidUser`, `-UpdateLightSquidPassword`). Para desligar a coleta: `-NoLogs`.

## Rodar na mão

```powershell
# conferir os privilegios (nao grava nada)
powershell -NoProfile -ExecutionPolicy Bypass -File C:\pfSense-Backup\Logs-pfSense.ps1 -Name FWCLIENTE -CheckOnly

# coletar agora, como a tarefa faz
schtasks /Run /TN "pfSense Logs - FWCLIENTE"
Get-Content C:\pfSense-Backup\logs\FWCLIENTE\FWCLIENTE-logs.log -Tail 5
```
