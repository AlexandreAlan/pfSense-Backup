# Segurança

[← README](../README.md) · [Instalação](instalacao.md) · [Configuração](configuracao.md) · [Monitoramento](monitoramento.md)

## Como as credenciais são protegidas

| Proteção | Como funciona |
|---|---|
| **Privilégio mínimo** | O usuário do pfSense só tem `WebCfg - Diagnostics: Backup & Restore`. O instalador **prova** isso: confere que ele baixa o backup e que **não** acessa gerenciador de usuários, regras nem prompt de comandos. |
| **Senha cifrada** | AES‑256, com chave aleatória por perfil, numa pasta que só `SYSTEM` e `Administradores` leem. Foi usada chave AES, e não DPAPI, para a senha poder ser gravada por um admin e lida pela tarefa como `SYSTEM`. |
| **Certificado fixado** | A WebGUI usa certificado autoassinado, então o curl roda com `-k`. Quem garante que é o firewall certo é o `--pinnedpubkey`, conferido **antes** de enviar qualquer dado. Se outro equipamento responder no lugar do pfSense, a senha não sai do servidor. |
| **Senha fora da linha de comando** | A senha vai para o `curl.exe` pela entrada padrão (`-K -`), em UTF‑8. Não aparece na lista de processos. |
| **Sessão encerrada** | O script faz logout no pfSense depois de cada backup. |
| **Sem bloqueio por tentativas** | Senha errada **não** é repetida, para não acionar o sshguard do pfSense. |

## Limites que você precisa conhecer

- **A senha do usuário de backup dá controle total do firewall.** O privilégio *Backup & Restore* também permite **restaurar** uma configuração modificada (outro admin, regras abertas, VPN nova). Trate-a como senha de admin.
- **Um administrador do servidor consegue ler a chave e a senha.** A proteção é contra usuários comuns e contra o vazamento do arquivo de senha sozinho.
- **O `config.xml` contém segredos:** hashes de senha, chaves de VPN e certificados. Fora do servidor, use `-Encrypt`.
- **Não aponte para um pfSense pela internet.** Use o IP da LAN ou uma VPN.
- **Nunca publique** `config\*.json`, `secrets\`, `backups\`, `logs\` ou `status\`. O `.gitignore` do repositório já bloqueia esses caminhos.

## O que o instalador faz no servidor

Tudo o que ele cria, altera ou baixa, e como desfazer:

| O quê | Onde | Como desfazer |
|---|---|---|
| Identifica o Windows | só leitura | — |
| Cria a pasta e restringe o acesso a `SYSTEM` + `Administradores` | `C:\pfSense-Backup` | `icacls C:\pfSense-Backup /reset /T` ou apagar a pasta |
| Copia os dois scripts | `C:\pfSense-Backup\*.ps1` | apagar a pasta |
| Baixa o curl oficial, **só se faltar e só se você concordar** | `C:\pfSense-Backup\bin\curl.exe` | apagar a pasta `bin` |
| Grava a chave e a senha cifrada | `secrets\<Nome>.key`, `.pass` | `-Uninstall` |
| Grava a configuração do perfil | `config\<Nome>.json` | `-Uninstall` |
| Registra a origem de eventos `pfSense-Backup` | Log de Aplicativo | `Remove-EventLog -Source pfSense-Backup` |
| Cria a tarefa diária, como `SYSTEM` | Agendador: `pfSense Backup - <Nome>` | `-Uninstall` |
| Grava log e status do Zabbix | `logs\<Nome>\`, `status\<Nome>\` | `-Uninstall` remove o status; o log fica |

O instalador **não** instala programas, **não** mexe no `PATH`, **não** abre portas no firewall do Windows, **não** cria usuários no Windows e **não** altera nada no pfSense.

## Internet

Só é usada se o curl precisar ser baixado (Server 2016 / 2012 R2), uma vez, na instalação, para `https://curl.se`, e só com a sua autorização. O backup diário não usa internet.
