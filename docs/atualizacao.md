# Atualizar uma instalação

[← README](../README.md) · [Logs](logs.md) · [Auditoria](auditoria.md)

Para atualizar, **não é preciso desinstalar nem refazer nada**. Basta copiar a versão nova dos scripts para o servidor e rodar o instalador com o **mesmo nome de perfil**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE
```

## O que o instalador faz numa atualização

Ele identifica a versão do perfil pelo campo `SchemaVersion` do `config\<Nome>.json`. Um perfil sem esse campo é da versão 1.

```
==> Atualizacao: perfil 'FWCLIENTE' da versao 1 encontrado -> versao 2 (2.0.0)
    OK  mantidos sem perguntar: firewall, porta, usuario, chave, senha, certificado fixado, horario, retencao e tarefa do backup
    OK  sera feito: copiar os scripts novos, completar o config JSON e perguntar SO o que e novo (logs e relatorio)
```

| | Na atualização |
|---|---|
| Firewall, porta, usuário | mantidos |
| Chave AES e senha cifrada | mantidas (não pergunta a senha) |
| Certificado fixado (pin) | mantido. Se o certificado mudou, o instalador **para** e pede `-TrustNewCert`, como sempre |
| Horário, retenção, cópia externa, criptografia | mantidos (não pergunta) |
| Campos editados à mão no JSON | preservados |
| Scripts em `C:\pfSense-Backup` | substituídos pelos novos |
| Campos novos no JSON | acrescentados com o valor padrão |
| **Perguntas** | **só o que é novo**: ativar a coleta de logs (e o LightSquid, se existir) |
| Tarefa do backup | recriada com os mesmos valores |
| Verificação do usuário e backup de teste | feitos, como numa instalação |

Rodar de novo um perfil **já atualizado** funciona como antes: o instalador mostra cada valor atual entre colchetes, e ENTER mantém.

## Sem perguntas (vários servidores)

```powershell
# atualiza e mantem os logs desligados
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Yes

# atualiza e ja liga os logs
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Logs -Yes
```

## Versões

| Versão | `SchemaVersion` | Novidades |
|---|---|---|
| 1 | (sem o campo) | Backup diário do `config.xml`, pinning, status para o Zabbix, cópia externa, criptografia |
| 2.0.0 | `2` | [Relatório de auditoria](auditoria.md), [coleta de logs](logs.md) (com a planilha de visitantes e o LightSquid) e atualização sem refazer o processo |
