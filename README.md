# pfSense-Backup

[![Testes](https://github.com/AlexandreAlan/pfSense-Backup/actions/workflows/testes.yml/badge.svg)](https://github.com/AlexandreAlan/pfSense-Backup/actions/workflows/testes.yml)
![Windows Server 2016+](https://img.shields.io/badge/Windows_Server-2016%2B-0078D6?logo=windows)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![pfSense 2.4+](https://img.shields.io/badge/pfSense-2.4%2B-212121)
[![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)](LICENSE)

Backup **automático e diário** do `config.xml` de firewalls **pfSense**, feito por um servidor **Windows** da rede (normalmente o AD do cliente), pela própria WebGUI. Não instala nada no pfSense.

## Recursos

- **Privilégio mínimo comprovado:** usa um usuário que só pode fazer backup, e o instalador testa isso de verdade.
- **Credenciais protegidas:** senha cifrada (AES‑256), fora da linha de comando, e **certificado fixado**. Se outro equipamento se passar pelo firewall, a senha não sai do servidor.
- **Backup validado:** só aceita um XML válido do pfSense. Falha de login nunca vira backup "vazio".
- **Retenção configurável:** apaga os antigos, mas sempre mantém os mais recentes.
- **Monitoramento simples:** três arquivos de status por firewall, prontos para o Zabbix, mais eventos no Log do Windows.
- **Vários firewalls** no mesmo servidor, cada um com seus backups, logs e status.
- **Cópia fora do servidor** (NAS), opcional, contra perda do servidor ou ransomware.
- **Instalação guiada e transparente:** identifica o Windows, explica cada pergunta e só baixa o curl (Server 2016) com a sua autorização.

## Como funciona

```
 Servidor Windows (AD)                               pfSense
 ┌──────────────────────────────┐   HTTPS (WebGUI)   ┌─────────────────────┐
 │ Tarefa diária (SYSTEM)       │ ─────────────────▶ │ login               │
 │  Backup-pfSense.ps1 + curl   │ ◀───────────────── │ Diagnostics › Backup│
 │                              │     config.xml     └─────────────────────┘
 │ backups\  logs\  status\     │──▶ Zabbix
 └──────────────────────────────┘
```

## Requisitos

| | |
|---|---|
| **Servidor** | Windows Server 2016+ ou Windows 10+, com Windows PowerShell 5.1 (já vem no Windows) |
| **Rede** | Acesso do servidor à WebGUI do pfSense (IP da LAN + porta HTTPS) |
| **pfSense** | 2.4+, com um grupo e um usuário de backup ([como criar](docs/instalacao.md#1-preparar-o-pfsense)) |
| **curl** | Já vem no Windows 10 1803+ e no Server 2019+. No Server 2016, o instalador oferece baixar o oficial |

## Instalação rápida

**1. No pfSense**, crie o grupo `BACKUP-PFSENSE` **só** com o privilégio `WebCfg - Diagnostics: Backup & Restore`, e o usuário `srvbackup-pfsense` membro **só** desse grupo.

**2. No servidor**, extraia este repositório e, no **PowerShell como Administrador**, rode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 172.16.10.1
```

**3. Responda as perguntas.** O padrão aparece entre colchetes, e ENTER aceita:

```
  Porta HTTPS da WebGUI [443]: 10443
  Horario do backup diario (HH:mm) [02:00]:
  Dias guardados (1 a 3650) [90]:
  Minimo de backups mantidos (1 a 1000) [10]:
```

O instalador então confere o usuário no pfSense, cria a tarefa diária e faz um **backup de teste**. Se algo estiver errado, ele **para e diz o que corrigir**. Passo a passo completo em [Instalação](docs/instalacao.md).

## Monitoramento

Cada firewall tem a sua pasta `C:\pfSense-Backup\status\<Nome>\`:

| Arquivo | Conteúdo |
|---|---|
| `status.txt` | `OK`, `AVISO` ou `ERRO` |
| `ultimo-ok.txt` | Data do último backup bom (segundos desde 1970) |
| `mensagem.txt` | Última mensagem (motivo do erro) |

No Zabbix: `vfs.file.contents["C:\pfSense-Backup\status\FWCLIENTE\status.txt"]` com trigger `="ERRO"`, e uma trigger para "sem backup bom há mais de 26 h". Itens e triggers prontos em [Monitoramento](docs/monitoramento.md).

## Documentação

| | |
|---|---|
| [Instalação](docs/instalacao.md) | Preparar o pfSense, rodar o instalador, validar, checklist |
| [Configuração](docs/configuracao.md) | Mudar horário/retenção, parâmetros, cópia externa, restaurar um backup |
| [Monitoramento](docs/monitoramento.md) | Arquivos de status, itens e triggers do Zabbix, eventos do Windows |
| [Segurança](docs/seguranca.md) | Como as credenciais são protegidas e o que o instalador faz no servidor |
| [Problemas comuns](docs/problemas.md) | Cada mensagem de erro e o que fazer |
| [Desenvolvimento](docs/desenvolvimento.md) | Estrutura, convenções e testes automáticos |

## Licença

[MIT](LICENSE)
