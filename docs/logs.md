# Coleta de logs

[← README](../README.md) · [Auditoria](auditoria.md) · [Atualização](atualizacao.md) · [Monitoramento](monitoramento.md) · [Problemas](problemas.md)

A partir da versão 2, o pfSense-Backup também **guarda os logs do pfSense** no servidor Windows, organizados por categoria e por dia, e monta a **planilha de acessos dos visitantes** do portal cativo.

Há **dois modos** de buscar os logs. O instalador pergunta qual usar:

| | **SSH com chave travada** (recomendado, v2.1) | **WebGUI** |
|---|---|---|
| Como | Lê os **arquivos** de log do pfSense, por SSH (criptografado) | Lê as telas de log, por HTTPS |
| Firewall | ✅ **completo**, mesmo com dezenas de milhares de linhas por hora | ⚠️ limitado a N linhas por coleta (a página do pfSense tem limite de memória) |
| Autenticação (logins na WebGUI e no SSH) | ✅ | ❌ (só admin vê) |
| Lacuna entre coletas | **nenhuma**: retoma do byte exato, inclusive quando o log gira | possível, com `AVISO` |
| Peso no pfSense | quase zero: só lê arquivos | monta páginas HTML |
| Privilégios no pfSense | shell (`User - System: Shell account access`) com a chave **travada** | um por log, e os de **pacote**, que também permitem **alterar** os pacotes |
| No servidor | OpenSSH (o instalador oferece baixar no Server 2016) | nada |

Nos dois modos: o **mesmo usuário** do backup, nada é instalado no pfSense como pacote, e o servidor não abre nenhuma porta.

## Modo SSH (recomendado)

### A chave travada

O instalador gera uma chave SSH **só deste servidor** e a linha pronta para colar no pfSense:

```
restrict,from="172.16.10.7",command="/bin/sh -c '...'" ssh-ed25519 AAAA... pfSense-Backup-FWCLIENTE@SERVIDOR
```

- `from=`: a chave **só funciona a partir do IP deste servidor**.
- `restrict`: **sem terminal**, sem túnel e sem redirecionamento.
- `command=`: o pfSense **ignora** qualquer comando enviado e roda só este, que aceita 3 pedidos sobre uma **lista fixa** de arquivos de log:
  - `list`: lista os arquivos;
  - `get <arquivo> <posição>`: lê a partir da posição;
  - `sig <arquivo>`: lê a 1ª linha, usada para reconhecer o log que girou.

  Qualquer outra coisa, caminho fora da lista ou `..`, é **recusada**. Mesmo roubada, a chave **não altera nada** e não lê senhas nem a configuração.
- A **chave SSH do pfSense** fica **fixada**, como o certificado da WebGUI. Se outro equipamento responder no lugar dele, a coleta para.

A verificação do instalador (`-CheckOnly`) **reprova** a chave se o pfSense executar um comando fora da lista.

### Preparar o pfSense

1. **System › User Manager › Users** › edite o `srvbackup-pfsense`:
   - **Authorized SSH Keys**: cole a linha **inteira** do arquivo `C:\pfSense-Backup\config\<Nome>-chave-ssh-pfsense.txt`, gerado pelo instalador. É uma linha só, começando com `restrict,from=`.
   - **Effective Privileges › Add**: `User - System: Shell account access`. É necessário para o comando travado rodar.
2. **Deixe os logs legíveis pelo grupo do usuário.** No pfSense, os logs são só do root. O script [`pfsense/pfsense-backup-permissoes.sh`](../pfsense/pfsense-backup-permissoes.sh) dá leitura **só ao grupo** `LOGS-PFSENSE` e só aos arquivos da lista. Rode uma vez e agende a cada 10 minutos (System › Cron), porque, quando um log gira, o pfSense recria o arquivo só para o root:
   ```sh
   mkdir -p /root/bin && fetch -o /root/bin/pfsense-backup-permissoes.sh https://raw.githubusercontent.com/AlexandreAlan/pfSense-Backup/main/pfsense/pfsense-backup-permissoes.sh
   sh /root/bin/pfsense-backup-permissoes.sh
   ```
   Cron: `*/10 * * * * root /bin/sh /root/bin/pfsense-backup-permissoes.sh`
3. **Recomendado:** SSH **só com chave** (System › Advanced › Admin Access › *SSHd Key Only*). Sem isso, a **senha** do usuário de backup também abre um terminal no pfSense.
4. Libere a porta SSH do pfSense para o IP do servidor, se ainda não estiver liberada.

No modo SSH, o grupo `LOGS-PFSENSE` **não precisa de privilégio nenhum na WebGUI**: ele só serve para dar a leitura dos arquivos. Os privilégios de pacote (pfBlockerNG, Suricata, Squid) podem ser **retirados**.

### Como a coleta funciona

- Cada log é lido **do byte exato onde a coleta anterior parou**. A última linha, se ainda estiver pela metade, fica para a próxima.
- Quando o log **gira** (vira `.0.bz2`, ou é arquivado em `/var/log/arquivo`), o arquivo antigo é reconhecido pela 1ª linha: a coleta **termina de ler o antigo** e depois lê o novo do começo. Nada se perde e nada duplica.
- Arquivos que o pacote **reescreve** (o pfBlockerNG apara os seus) são conferidos pelas últimas linhas, para não duplicar.
- Suricata **por interface**, com o nome da interface tirado do `config.xml` do último backup: `suricata\LAN\alertas`, `suricata\VISITANTES\bloqueios`.
- As concessões de DHCP vêm do próprio `dhcpd.leases`.

## Modo WebGUI

Tudo passa pelo **mesmo caminho do backup**: a WebGUI, por HTTPS, com o mesmo usuário, a mesma senha cifrada e o mesmo certificado fixado.

### O que é coletado (modo WebGUI)

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

### Preparar o pfSense (modo WebGUI)

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
      autenticacao\...          (so no modo SSH)
      suricata\LAN\alertas\...      suricata\LAN\bloqueios\...   suricata\VISITANTES\alertas\...
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

## Como a coleta funciona no modo WebGUI (incremental)

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
| `LogTransport` | `ssh` ou `web` | Modo da coleta |
| `SshPort`, `SshUser`, `SshFrom`, `SshPath` | 22, usuário do backup, IP do servidor, OpenSSH | Modo SSH: porta do pfSense, usuário, IP travado na chave, caminho do `ssh.exe` |
| `LogSources` | todas as da tabela, menos `ppp` | Fontes, separadas por vírgula |
| `LogEvery` | `60` | Minutos entre coletas (tarefa agendada) |
| `LogLines` | `10000` | (WebGUI) linhas pedidas por log a cada coleta |
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
