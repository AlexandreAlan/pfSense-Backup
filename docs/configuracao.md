# Configuração e operação

[← README](../README.md) · [Instalação](instalacao.md) · [Monitoramento](monitoramento.md) · [Problemas](problemas.md)

## Mudar uma configuração

Rode o instalador de novo **só com `-Name`**. Ele mostra os valores atuais entre colchetes. ENTER mantém, ou digite o valor novo. Senha, chave e certificado fixado **não** são pedidos de novo.

```powershell
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE
```

```
  Porta HTTPS da WebGUI [10443]:
  Horario do backup diario (HH:mm) [02:00]: 23:30
  Dias guardados (1 a 3650) [90]: 180
  Minimo de backups mantidos (1 a 1000) [10]:
    OK  backup diario as 23:30; apaga os com mais de 180 dia(s), mas mantem sempre os 10 mais recentes
```

## Operação do dia a dia

Em PowerShell como Administrador, na pasta `C:\pfSense-Backup`:

| Quero… | Comando |
|---|---|
| Rodar um backup agora | `schtasks /Run /TN "pfSense Backup - FWCLIENTE"` |
| Ver o log | `Get-Content .\logs\FWCLIENTE\FWCLIENTE.log -Tail 20` |
| Ver o status | `Get-Content .\status\FWCLIENTE\status.txt` |
| Mudar horário, retenção ou porta | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE` e responder |
| Trocar a senha do pfSense | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -UpdatePassword` |
| Aceitar o certificado renovado do pfSense | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -TrustNewCert` |
| Adicionar outro firewall | rodar o instalador com outro `-Name` |
| Listar perfis | `Get-ChildItem .\config\*.json` |
| Remover um perfil (mantém backups e log) | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Uninstall` |

## Parâmetros do instalador

| Parâmetro | Padrão | Para que serve |
|---|---|---|
| `-Name` | — | **Obrigatório.** Nome do perfil |
| `-FwHost` | — | IP ou nome do pfSense (obrigatório no primeiro cadastro) |
| `-Port` | `443` | Porta HTTPS da WebGUI. Perguntado se faltar |
| `-Time` | `02:00` | Horário do backup diário. Perguntado se faltar |
| `-KeepDays` | `90` | Apaga backups mais velhos que N dias. Perguntado se faltar |
| `-MinKeep` | `10` | Sempre mantém os N mais recentes. Perguntado se faltar |
| `-User` | `srvbackup-pfsense` | Usuário do pfSense (`admin` e `root` são recusados) |
| `-GroupName` | `BACKUP-PFSENSE` | Nome do grupo, usado só nas instruções |
| `-Encrypt` | desligado | Backup criptografado pelo pfSense (`.xml.enc`). Pede a senha de criptografia. **Sem ela o backup não restaura**: guarde fora do servidor |
| `-CopyTo` | vazio | Copia cada backup para fora do servidor (ver abaixo). `-CopyTo ''` desliga |
| `-IncludeRRD` | desligado | Inclui os gráficos RRD (arquivo bem maior) |
| `-UpdatePassword` | — | Pede de novo a senha do pfSense (e a de criptografia) |
| `-TrustNewCert` | — | Aceita um certificado da WebGUI diferente do fixado |
| `-CurlPath` | procura sozinho | Caminho do `curl.exe` |
| `-BaseDir` | `C:\pfSense-Backup` | Pasta de instalação (sem espaços) |
| `-Yes` | — | Não pergunta nada: usa os padrões/valores salvos, aceita o certificado no 1º cadastro e autoriza baixar o curl |
| `-NoTest` | — | Pula a verificação do usuário e o backup de teste (não recomendado) |
| `-Uninstall` | — | Remove tarefa, JSON, segredos e status do perfil; mantém backups e log |

**Padrões da sua empresa:** os valores padrão ficam num bloco `PADROES` no topo do `Install-pfSenseBackup.ps1`. Edite uma vez (ex.: outro nome de usuário) e todos os cadastros novos passam a usar.

## Retenção

A cada backup, os arquivos com mais de **`KeepDays`** dias são apagados, **exceto** os **`MinKeep`** mais recentes, que nunca são apagados.

| Exemplo | Resultado |
|---|---|
| 90 dias, mínimo 10, backup diário | Ficam ~90 arquivos (os últimos 3 meses) |
| 90 dias, mínimo 10, backup parou há 4 meses | Os 10 últimos backups bons continuam lá |

## Cópia fora do servidor

Se o servidor morrer ou for atingido por ransomware, os backups do firewall vão junto. Com `-CopyTo`, cada backup validado também é copiado para outro lugar (NAS, outro servidor), em `<CopyTo>\<Nome>\`, com a mesma retenção:

```powershell
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Encrypt -CopyTo \\NAS01\Backups\pfSense
```

- O compartilhamento fica **no NAS**. A pasta `C:\pfSense-Backup` **não** é compartilhada.
- A tarefa roda como `SYSTEM`, que acessa a rede como a **conta do computador** (`DOMINIO\SERVIDOR$`). Dê permissão de gravação a ela no compartilhamento.
- Use com **`-Encrypt`**: fora do servidor, a proteção da pasta não acompanha os arquivos.
- Se a cópia falhar, o backup local continua valendo e o status vira `AVISO`.

## Arquivo `config\<Nome>.json`

Criado pelo instalador. Pode ser editado à mão, e rodar o instalador de novo **preserva** os valores editados. Modelo: [`config/EXEMPLO.json.example`](../config/EXEMPLO.json.example).

| Campo | Descrição |
|---|---|
| `Host`, `Port`, `User` | Onde e como entrar no pfSense |
| `Time` | Horário do backup diário |
| `KeepDays`, `MinKeep` | Retenção |
| `IncludeRRD`, `Encrypt` | Opções do download |
| `CopyTo` | Pasta da cópia externa (vazio = desligado) |
| `PubKeyPin` | Chave fixada do certificado da WebGUI (`sha256//...`) |
| `ConnectTimeout` | Timeout de conexão, em segundos (15) |
| `MaxTime` | Tempo máximo de cada requisição, em segundos (300) |
| `Retries`, `RetryDelay` | Novas tentativas em falha de rede (3, a cada 60 s) |
| `CurlPath` | Caminho do curl, quando não é o do Windows |

## Estrutura no servidor

```
C:\pfSense-Backup\
├── Backup-pfSense.ps1           motor (roda todo dia)
├── Install-pfSenseBackup.ps1    cadastro / alteração / remoção
├── bin\curl.exe                 só no Server 2016 / 2012 R2
├── config\FWCLIENTE.json        configuração do perfil
├── secrets\                     chave e senha cifrada
├── backups\FWCLIENTE\           config-FWCLIENTE-AAAA-MM-DD_HHMM.xml
├── logs\FWCLIENTE\              FWCLIENTE.log (um por firewall)
└── status\FWCLIENTE\            status.txt, ultimo-ok.txt, mensagem.txt (Zabbix)
```

## Restaurar um backup

No pfSense: *Diagnostics › Backup & Restore › Restore Backup*

1. **Restore area:** *All* (ou só a seção desejada).
2. Escolha o arquivo `config-<Nome>-<data>.xml`.
3. Se for `.xml.enc`, marque **Configuration file is encrypted** e informe a senha de criptografia.
4. **Restore Configuration**. O firewall reinicia.

> Em hardware novo, os nomes das placas de rede (`igb0`, `em0`…) podem mudar. O pfSense pede para reatribuir as interfaces.
