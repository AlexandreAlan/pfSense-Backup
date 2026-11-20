# Desenvolvimento e testes

[← README](../README.md)

## Estrutura do repositório

```
Backup-pfSense.ps1          motor: login na WebGUI, download, validação, retenção, status
Logs-pfSense.ps1            (v2) coleta incremental dos logs pela WebGUI
Relatorio-pfSense.ps1       (v2) relatório de auditoria HTML a partir do config.xml
Install-pfSenseBackup.ps1   instalador: perguntas, segredos, pinning, verificação, tarefa
config/EXEMPLO.json.example modelo do JSON de um perfil
docs/                       documentação
tests/                      testes automáticos
.github/workflows/          CI (workflow "Testes")
```

## Convenções

- **`.ps1` em ASCII puro**, sem acentos. O Windows PowerShell 5.1 lê arquivo sem BOM como ANSI. Nos `.md`, acentos à vontade.
- **Compatível com Windows PowerShell 4.0 a 5.1.** O PowerShell 7 não é o alvo.
- **Nunca escreva `"$variavel:"`** dentro de string: o `:` faz o PowerShell ler `$drive:variavel` e o script inteiro deixa de carregar. Use `"${variavel}:"`.
- **Nada de `$PSScriptRoot` como valor padrão no `param()`**: chega vazio em alguns Windows. Use `$MyInvocation.MyCommand.Definition`.
- **Segredos nunca na linha de comando**: sempre por `Invoke-Curl ... $Secrets` (stdin, `-K -`).
- **Resposta grande do curl vai para arquivo** (`-o`), nunca pelo pipe: o PS 5.1 converte a saída de exe nativo pela página de código do console e estraga os acentos.
- **Função devolvendo lista:** o PowerShell "desembrulha" uma lista de 1 item. Quem precisa de `.Count` ou `+` usa `@(Funcao ...)`.
- **Nada de função com nome de alias** (`h`, `r`, `gc`…): o alias vence a função.
- **Privilégios do pfSense conferem a URL exata** (`status_logs.php` ≠ `status_logs.php?logfile=x`): parâmetros extras vão no corpo do POST.

## Testes

O workflow **Testes** roda a cada push e PR:

| Teste | Onde | O que confere |
|---|---|---|
| Sintaxe (`tests/Test-Sintaxe.ps1`) | Windows, **Windows PowerShell 5.1** real | Parser nos dois scripts e ASCII puro |
| Lint (`tests/Test-Sintaxe.ps1 -Analyzer`) | Windows, pwsh | PSScriptAnalyzer + compatibilidade de sintaxe 4.0 / 5.1 |
| Funcional (`tests/run-funcional.sh`) | Linux | As **funções reais** dos scripts contra um pfSense simulado (`tests/mock_pfsense.py`) |

Cenários do teste funcional, com uma senha "difícil" (`"`, `\`, `$`, `:`, crase, espaço e acento):

1. Pin do certificado calculado pelo instalador = pin do `openssl`.
2. Login + download + validação do XML + logout.
3. Backup criptografado com senha de criptografia difícil.
4. `-CheckOnly` aprova um usuário só com o privilégio de backup.
5. Senha errada: para na hora, sem nova tentativa.
6. Certificado diferente: o curl recusa e a senha **não** chega no servidor.
7. Arquivos de status: `OK` → `ERRO`, com o `ultimo-ok.txt` preservado no erro.

Versão 2 (`tests/Test-Logs.ps1`, mesmo pfSense simulado, que ganhou as telas de log):

8. Datas de todos os formatos de log (syslog sem ano, ISO, Suricata, Squid, pfBlockerNG) e o algoritmo que acha onde a coleta parou.
9. `-CheckOnly` dos logs: aponta a fonte sem privilégio e não acusa administrador.
10. Primeira coleta: cada fonte na sua pasta e dia, a planilha de visitantes (BOM, acento, CPF, voucher) e as concessões de DHCP.
11. Coletas seguintes: nada duplica, linhas novas entram uma vez só e a lacuna vira `AVISO`.
12. Relatório de auditoria com os `config.xml` de exemplo de `tests/fixtures/`: seções, mudanças, pontos de atenção e **nenhum segredo** no HTML.

O motor de logs é carregado nos testes por *dot-source* (`. .\Logs-pfSense.ps1 -Name X`). Nesse modo o script para antes do `main`. Mantenha o `main` depois da linha que confere `$MyInvocation.InvocationName`.

Rodar na mão:

```powershell
.\tests\Test-Sintaxe.ps1 -Analyzer
```

```bash
bash tests/run-funcional.sh    # precisa de pwsh, python3, openssl e curl
```

**Não cobertos** (dependem de um Windows real com um pfSense real): `icacls`, Agendador de Tarefas, Log de Eventos, download do curl no Server 2016 e o curl do Windows. Por isso o instalador sempre faz um backup de teste no fim.
