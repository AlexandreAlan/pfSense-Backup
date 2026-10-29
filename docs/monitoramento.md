# Monitoramento (Zabbix)

[← README](../README.md) · [Instalação](instalacao.md) · [Configuração](configuracao.md) · [Problemas](problemas.md)

Cada execução do backup grava **três arquivos de status** por firewall, em `C:\pfSense-Backup\status\<Nome>\`. Cada arquivo tem **um valor só, sem quebra de linha**, e pode ser lido direto pelo agente do Zabbix:

| Arquivo | Conteúdo | Exemplo |
|---|---|---|
| `status.txt` | `OK`, `AVISO` ou `ERRO` | `OK` |
| `ultimo-ok.txt` | Segundos desde 1970 (UTC) do último backup bom | `1793152803` |
| `mensagem.txt` | Data + última mensagem | `2026-10-30T02:00:03  Backup OK: C:\...\config-FWAGF-2026-10-30_0200.xml (2210,5 KB)` |

| Status | Significa |
|---|---|
| `OK` | Backup baixado e validado |
| `AVISO` | Backup local OK, mas a [cópia externa](configuracao.md#cópia-fora-do-servidor) falhou |
| `ERRO` | Backup falhou. O motivo está em `mensagem.txt`. O `ultimo-ok.txt` **não** muda |

## Itens no Zabbix

No host do servidor Windows (agente Zabbix), crie um item para cada arquivo, trocando `FWAGF` pelo nome do perfil:

| Item | Chave | Tipo de informação |
|---|---|---|
| Status do backup | `vfs.file.contents["C:\pfSense-Backup\status\FWAGF\status.txt"]` | Texto |
| Último backup OK | `vfs.file.contents["C:\pfSense-Backup\status\FWAGF\ultimo-ok.txt"]` | Numérico (inteiro sem sinal), unidade `unixtime` |
| Mensagem | `vfs.file.contents["C:\pfSense-Backup\status\FWAGF\mensagem.txt"]` | Texto |

Intervalo sugerido: 5 minutos.

## Triggers

Sintaxe do Zabbix 6 ou mais novo (troque `SERVIDOR` pelo nome do host):

| Trigger | Expressão | Severidade |
|---|---|---|
| Backup do pfSense falhou | `last(/SERVIDOR/vfs.file.contents["C:\pfSense-Backup\status\FWAGF\status.txt"])="ERRO"` | Alta |
| Cópia externa do backup falhou | `last(/SERVIDOR/vfs.file.contents["C:\pfSense-Backup\status\FWAGF\status.txt"])="AVISO"` | Aviso |
| Sem backup bom há mais de 26 h | `now()-last(/SERVIDOR/vfs.file.contents["C:\pfSense-Backup\status\FWAGF\ultimo-ok.txt"])>93600` | Alta |

A terceira trigger pega também o caso em que o backup **nem rodou** (tarefa desativada, servidor desligado às 02:00). Em **Dados operacionais** da trigger, use o item *Mensagem* para o alerta já mostrar o motivo.

> O agente do Zabbix roda como `Local System` por padrão e consegue ler a pasta. Se ele rodar com outra conta, dê permissão de leitura a ela em `C:\pfSense-Backup\status`.

## Alternativa: Log de Eventos do Windows

Cada execução também grava um evento no **Log de Aplicativo**, origem `pfSense-Backup`:

| ID | Tipo | Quando |
|---|---|---|
| 1000 | Informação | Backup OK |
| 1001 | Erro | Backup falhou |
| 1002 | Aviso | Backup OK, cópia externa falhou |

Itens do agente Zabbix (ativos):

- `eventlog[Application,,"Error",pfSense-Backup,1001,,skip]`, com trigger em qualquer valor novo;
- `eventlog[Application,,"Information",pfSense-Backup,1000,,skip]`, com trigger `nodata(26h)=1`.

Ver os últimos eventos no servidor:

```powershell
Get-EventLog -LogName Application -Source pfSense-Backup -Newest 10
```

O código de saída do `Backup-pfSense.ps1` também aparece no Agendador de Tarefas (*Last Run Result*): `0` = OK, `1` = erro.
