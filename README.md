# pfSense-Backup

Backup automático e diário do `config.xml` de firewalls **pfSense**, feito por um servidor **Windows** (normalmente o AD do cliente), usando a própria WebGUI do pfSense.

- Não precisa instalar nada no pfSense, só criar um **grupo `BACKUP-PFSENSE`** e um **usuário dedicado** com permissão exclusiva de backup. O instalador confere se ficou certo.
- A senha fica cifrada (AES‑256) e a tarefa roda como `SYSTEM`, então funciona até em Controlador de Domínio.
- **Certificado fixado (pinning):** no cadastro, o instalador grava a chave do certificado da WebGUI. Se outro equipamento responder no lugar do pfSense, o backup se recusa a conectar **antes** de enviar a senha.
- Um mesmo servidor pode fazer backup de **vários firewalls**. Cada um é um *perfil* com nome próprio (`FWMATRIZ`, `FWFILIAL`…).
- Antes de aceitar o arquivo, o script confere se ele é um XML válido do pfSense. Se o login falhar, nenhum backup "vazio" é salvo.
- Apaga os backups antigos e sempre preserva os mais recentes.
- Repete sozinho quando há falha de rede. Erro de senha ou de permissão **não** é repetido, para não fazer o pfSense bloquear o servidor.
- Opcionalmente **copia cada backup para fora do servidor** (NAS ou outro servidor), para não perder tudo se o AD morrer ou for atingido por ransomware.
- Grava log por perfil e um evento no Visualizador de Eventos, para ser monitorado por Zabbix ou similar.

---

## Início rápido

Para quem só quer fazer funcionar. O passo a passo detalhado está [mais abaixo](#cadastrar-um-firewall-novo-passo-a-passo).

**1. No pfSense:** crie o grupo `BACKUP-PFSENSE` só com o privilégio `WebCfg - Diagnostics: Backup & Restore`, e o usuário `srvbackup-pfsense` membro só desse grupo ([detalhes](#passo-2-criar-o-grupo-e-o-usuário-de-backup-no-pfsense-obrigatório)).

**2. No servidor Windows**, abra o *Windows PowerShell* **como Administrador**, vá até a pasta dos scripts e rode trocando só o nome e o IP:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 192.168.1.1
```

**3. Responda `S`** quando ele perguntar do pré-requisito, confirme a **porta da WebGUI** (aperte ENTER se for 443, ou digite a porta, ex.: `11443`) e **digite a senha** do usuário do pfSense duas vezes.

Pronto. Ele confere tudo, cria a tarefa diária e faz o primeiro backup. Se algo estiver errado, ele **para e diz o que corrigir**.

> A porta da interface web do pfSense não é 443? O instalador pergunta (veja [Porta da WebGUI](#porta-da-webgui)), ou já passe `-Port <porta>` no comando. O usuário tem outro nome? Acrescente `-User <usuario>`. Veja [Entendendo o comando](#entendendo-o-comando).

---

## Sumário

1. [Como funciona](#como-funciona)
2. [Requisitos](#requisitos)
3. [Cadastrar um firewall novo (passo a passo)](#cadastrar-um-firewall-novo-passo-a-passo)
   - [Personalizar os nomes padrão](#personalizar-os-nomes-padrão)
4. [Operação do dia a dia](#operação-do-dia-a-dia)
5. [Restaurar um backup](#restaurar-um-backup)
6. [Monitoramento](#monitoramento)
7. [Problemas comuns](#problemas-comuns)
8. [Segurança](#segurança)
9. [Referência dos arquivos](#referência-dos-arquivos)
10. [Checklist rápido](#checklist-rápido)

---

## Como funciona

```
 Servidor Windows (AD)                                pfSense
 ┌───────────────────────────────┐   HTTPS (WebGUI)   ┌──────────────────────┐
 │ Tarefa agendada (SYSTEM)      │ ─────────────────▶ │ /index.php  (login)  │
 │  └─ Backup-pfSense.ps1 -Name X│                    │ /diag_backup.php     │
 │       curl.exe                │ ◀───────────────── │   (Download XML)     │
 │                               │    config.xml      └──────────────────────┘
 │ C:\pfSense-Backup\backups\X\  │
 └───────────────────────────────┘
```

A cada execução, o `Backup-pfSense.ps1`:

1. lê `config\<Nome>.json` e decifra a senha com a chave `secrets\<Nome>.key`;
2. abre a tela de login do pfSense e pega o token CSRF. Em **todas** as conexões, o curl confere se a chave do certificado é a fixada no cadastro (`PubKeyPin`);
3. faz o login. A senha vai para o curl pela entrada padrão, nunca na linha de comando;
4. abre `diag_backup.php`, pega o segundo token e confirma que o login entrou;
5. baixa o backup em `backups\<Nome>\config-<Nome>-AAAA-MM-DD_HHMM.xml` e encerra a sessão (logout);
6. valida o arquivo (tamanho, XML bem formado, raiz `<pfsense>`). Se for inválido, apaga o arquivo e registra erro;
7. apaga os backups com mais de `KeepDays` dias, preservando sempre os `MinKeep` mais recentes;
8. se `CopyTo` estiver configurado, copia o backup para `<CopyTo>\<Nome>\` e aplica a mesma retenção lá;
9. grava o resultado em `logs\<Nome>.log` e no Log de Aplicativo do Windows.

Se os passos 2 a 6 falharem por rede, timeout ou download cortado, o script tenta de novo (padrão: 3 tentativas, com 60 s entre elas). Senha errada, falta de privilégio e certificado diferente param na hora.

Estrutura no servidor, depois de instalado:

```
C:\pfSense-Backup\
├── Backup-pfSense.ps1          motor (roda todo dia)
├── Install-pfSenseBackup.ps1   cadastro/remoção de perfis
├── bin\curl.exe                (só no Server 2016/2012 R2, que não trazem o curl)
├── config\
│   └── FWCLIENTE.json              host, porta, usuário, retenção…
├── secrets\                    (somente SYSTEM + Administradores)
│   ├── FWCLIENTE.key               chave AES de 32 bytes
│   ├── FWCLIENTE.pass              senha do pfSense cifrada
│   └── FWCLIENTE.encpass           (opcional) senha de criptografia do backup
├── backups\
│   └── FWCLIENTE\
│       └── config-FWCLIENTE-2026-10-30_0200.xml
└── logs\
    └── FWCLIENTE.log
```

---

## Requisitos

| Item | Detalhe |
|---|---|
| Windows | Server 2016+ ou Windows 10+ (Server 2012 R2 funciona com WMF 4/5 e `CurlPath`) |
| PowerShell | **Windows PowerShell 4.0 a 5.1** (`powershell.exe`). O PowerShell 7 (`pwsh`) não é suportado. |
| curl.exe | Já vem no Windows 10 1803+ e Server 2019+. No **Server 2016 / 2012 R2** não vem: veja [curl no Server 2016](#curl-no-windows-server-2016-e-anteriores). Precisa ser o curl **7.44 ou mais novo** (o instalador confere). |
| Rede | O servidor precisa alcançar a WebGUI do pfSense (IP da LAN + porta HTTPS). |
| pfSense | 2.4 ou mais novo (testado na lógica do 2.7.0). Precisa de um usuário com o privilégio de backup (ver abaixo). No **CE 2.8 / Plus 24.x‑25.x**, o formulário de backup ganhou campos novos: confira o primeiro backup de cada cliente nessas versões (o instalador já faz um backup de teste). |

---

## Cadastrar um firewall novo (passo a passo)

### Passo 1: levantar os dados do firewall

Anote:

- **IP da LAN do pfSense**, como o servidor enxerga (ex.: `192.168.1.1`);
- **porta da WebGUI**, em *System › Advanced › Admin Access › TCP port*. Se estiver vazia, é 443;
- **nome curto do perfil**, sem espaços (ex.: `FWCLIENTE`);
- **servidor Windows** onde o backup vai rodar.

### Passo 2: criar o grupo e o usuário de backup no pfSense (obrigatório)

O backup **sempre** usa um usuário dedicado, membro de um grupo que só tem permissão de backup. O instalador **confere isso de verdade** e se recusa a criar a tarefa se o usuário não conseguir baixar o backup ou se tiver permissão demais (ex.: for admin).

Nomes padrão (dá para trocar, veja [Personalizar os nomes padrão](#personalizar-os-nomes-padrão)):

| O quê | Nome padrão |
|---|---|
| Grupo | `BACKUP-PFSENSE` |
| Usuário | `srvbackup-pfsense` |

#### 2.1 Criar o grupo

1. *System › User Manager › **Groups** › **Add***
2. **Group name:** `BACKUP-PFSENSE`
3. **Scope:** `Local`
4. **Description:** `Backup automatico do config.xml (somente leitura de backup)`
5. **Save**
6. Clique no lápis do grupo para editar de novo. Em **Assigned Privileges**, clique em **Add**.
7. Na lista, selecione **somente** `WebCfg - Diagnostics: Backup & Restore` › **Save** › **Save**.

> ⚠️ **Erro comum:** escolher os itens `WebCfg - Services: Auto Config Backup…`. Eles parecem certos pelo nome, mas são do **AutoConfigBackup** (backup na nuvem da Netgate), outro recurso. Com eles o usuário loga e o backup **falha** com *"NAO tem acesso a pagina de backup"*. O único privilégio necessário é **`WebCfg - Diagnostics: Backup & Restore`**.

#### 2.2 Criar o usuário

1. *System › User Manager › **Users** › **Add***
2. **Username:** `srvbackup-pfsense`
3. **Password / Confirm:** uma senha forte. Você vai digitá-la no instalador.
4. **Full name:** `Backup automatico pfSense`
5. **Group membership:** selecione `BACKUP-PFSENSE` em *Not member of* e clique em **Move to "Member of" list**. Não coloque em nenhum outro grupo, **nunca** em `admins`.
6. **Effective Privileges:** deixe **vazio**. A permissão vem do grupo.
7. **Save**

#### 2.3 Como deve ficar

```
Groups  › BACKUP-PFSENSE   Members: srvbackup-pfsense
                           Privileges: WebCfg - Diagnostics: Backup & Restore   (só isso)

Users   › srvbackup-pfsense   Member of: BACKUP-PFSENSE   (só esse)
                              Effective Privileges (próprios): nenhum
```

> **Por que assim?** O usuário não acessa as telas de regras, VPN, usuários nem o prompt de comandos, e seus logins ficam separados dos do admin no log do pfSense. Usar grupo (em vez de privilégio direto no usuário) deixa o padrão igual em todos os clientes, e fica fácil auditar. Também não use o `admin`: o instalador recusa, e trocar a senha do admin quebraria o backup.

> ⚠️ **Trate essa senha como senha de admin.** O privilégio *Backup & Restore* também permite **restaurar** uma configuração. Quem tiver a senha pode subir um `config.xml` modificado, com outro admin, regras abertas ou VPN nova, e assim ganha **controle total do firewall**. É por isso que o backup fixa o certificado do pfSense (ninguém na rede consegue capturar a senha se passando pelo firewall) e envia a senha pela entrada padrão do curl.

### Passo 3: liberar o acesso (se precisar)

- Se o servidor estiver **na mesma LAN** do pfSense, normalmente já funciona, por causa da regra *anti‑lockout* ou das regras de LAN.
- Se estiver **em outra rede, VLAN ou VPN**, crie uma regra liberando `IP do servidor → IP do pfSense : porta da WebGUI (TCP)`.

Para testar no servidor:

```powershell
Test-NetConnection 192.168.1.1 -Port 443
```

### Passo 4: copiar os scripts para o servidor

#### curl no Windows Server 2016 e anteriores

O Server 2016 e o 2012 R2 **não trazem o `curl.exe`**. O instalador confere isso logo no começo, antes de pedir senha, e para com estas instruções se não achar:

1. Baixe o **curl oficial para Windows** (64-bit) em https://curl.se/windows/ e extraia o ZIP.
2. Crie a pasta `C:\pfSense-Backup\bin` e copie para ela o arquivo **`bin\curl.exe`** do ZIP. O resultado é `C:\pfSense-Backup\bin\curl.exe`.
3. Rode o instalador de novo.

O instalador e o backup procuram o curl nesta ordem: `-CurlPath` (ou `CurlPath` no JSON) › `C:\Windows\System32\curl.exe` › `C:\pfSense-Backup\bin\curl.exe` › `PATH`. Se você preferir deixar o curl em outra pasta, use `-CurlPath C:\caminho\curl.exe`.

Copie `Backup-pfSense.ps1` e `Install-pfSenseBackup.ps1` para qualquer pasta do servidor, por exemplo a Área de Trabalho ou um `git clone` deste repositório.

Se o Windows bloquear os arquivos por terem vindo da internet:

```powershell
Get-ChildItem .\*.ps1 | Unblock-File
```

### Passo 5: rodar o instalador

Abra o **Windows PowerShell como Administrador** (menu Iniciar › digite *PowerShell* › botão direito › *Executar como administrador*), entre na pasta dos scripts e rode:

```powershell
cd C:\Users\<voce>\Desktop\pfSense-Backup      # pasta onde voce copiou os scripts
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 192.168.1.1
```

#### Entendendo o comando

O instalador é **genérico**, serve para qualquer cliente. Os parâmetros dizem **qual firewall** cadastrar e **como entrar nele**:

| Parte | Para que serve | Obrigatório? |
|---|---|---|
| `.\` | O PowerShell não roda script da pasta atual sem o `.\` na frente, por segurança. | sim |
| `-Name FWCLIENTE` | **Nome do cadastro**, você escolhe. Vira o nome do arquivo de configuração, da pasta `backups\FWCLIENTE\`, do log e da tarefa agendada (*pfSense Backup - FWCLIENTE*). Use um nome por firewall; assim o mesmo servidor faz backup de vários. Só letras, números, `-` e `_`. | **sim** |
| `-FwHost 192.168.1.1` | **IP do pfSense**, como o servidor enxerga (normalmente o IP da LAN, o gateway da rede). Cada cliente tem o seu. | **sim**, na primeira vez |
| `-Port 11443` | Porta da interface web do pfSense. O padrão é **443**. Se você não informar, o instalador **pergunta** e mostra `[443]`: ENTER mantém, ou digite a porta certa. Informando no comando, ele não pergunta. Veja [Porta da WebGUI](#porta-da-webgui). | não (pergunta se faltar) |
| `-User nome` | Usuário criado no passo 2. O padrão é **`srvbackup-pfsense`**. Só informe se você criou com outro nome. | só se não for o padrão |

Exemplos:

```powershell
# Cliente que segue os padrões (porta 443, usuario srvbackup-pfsense)
.\Install-pfSenseBackup.ps1 -Name FWMATRIZ -FwHost 192.168.1.1

# Cliente com a interface web na porta 10443
.\Install-pfSenseBackup.ps1 -Name FWFILIAL -FwHost 10.0.0.1 -Port 10443

# Cliente com porta e usuario diferentes
.\Install-pfSenseBackup.ps1 -Name FWLOJA -FwHost 172.20.0.1 -Port 8443 -User backup.loja
```

> **"A execução de scripts foi desabilitada neste sistema"?** Use a forma completa abaixo. Ela libera só esta execução, sem mudar a política do servidor:
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 192.168.1.1
> ```

> **Rodando de novo depois:** IP, porta e usuário ficam gravados em `config\<Nome>.json`. Nas próximas vezes basta o `-Name` mais o que quiser mudar (ex.: `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -UpdatePassword` para trocar a senha). Veja [Operação do dia a dia](#operação-do-dia-a-dia).

#### Porta da WebGUI

A porta é o número depois de `:` no endereço que você usa para abrir o pfSense no navegador. Sem número no endereço, ela é **443**. No pfSense, ela fica em *System › Advanced › Admin Access › TCP port* (vazio = 443).

| Endereço no navegador | Porta | O que fazer na pergunta |
|---|---|---|
| `https://172.16.10.1` | 443 | só apertar **ENTER** |
| `https://172.16.10.1:11443` | 11443 | digitar `11443` e ENTER |

Na tela aparece assim:

```
  PORTA DA WebGUI DO pfSENSE
  --------------------------
  E o numero depois de ":" no endereco que voce usa para abrir o pfSense
  no navegador. Sem numero no endereco, a porta e 443.
     https://172.16.10.1        -> 443   (so aperte ENTER)
     https://172.16.10.1:11443  -> digite 11443
  No pfSense: System > Advanced > Admin Access > TCP port (vazio = 443).
  Porta HTTPS da WebGUI [443]: 11443
    OK  porta da WebGUI: 11443
```

Como funciona cada caso:

| Situação | O que o instalador faz |
|---|---|
| Cadastro novo, sem `-Port` | Pergunta, com `[443]` como padrão. ENTER = 443 |
| Perfil que já existe, sem `-Port` | Pergunta, com a **porta já salva** como padrão. ENTER mantém |
| Com `-Port 11443` no comando | Não pergunta, usa 11443 |
| Com `-Yes` (automação) | Não pergunta: usa a porta salva, ou 443 num cadastro novo |
| Digitou algo que não é número de 1 a 65535 | Avisa e pergunta de novo |

A porta fica gravada em `config\<Nome>.json` e é usada todo dia pelo backup. Se o teste de porta disser *sem resposta*, o instalador lembra de conferir a porta. Basta rodar de novo e digitar a porta certa: chave e senha já salvas são mantidas.

#### O que acontece ao rodar

Ele mostra o pré-requisito do passo 2 e pergunta se já foi feito (responda `S`). Se você não passou `-Port`, pergunta a **porta da WebGUI**, mostrando o padrão `[443]` (veja [Porta da WebGUI](#porta-da-webgui)). Depois pede a senha do pfSense duas vezes e faz sozinho:

- cria `C:\pfSense-Backup` e tranca as permissões: só SYSTEM e Administradores, por SID, então funciona em Windows em português. A permissão vai na pasta, e tudo dentro dela herda;
- copia os scripts para lá;
- gera a chave e grava a senha cifrada;
- grava `config\FWCLIENTE.json`;
- registra a origem de eventos `pfSense-Backup`;
- testa a porta e mostra o **certificado da WebGUI** (titular, validade e impressão digital SHA‑256). Confira a impressão digital com a que o navegador mostra ao abrir o pfSense (cadeado › certificado › detalhes) e responda `S`. A chave dele fica fixada no perfil;
- **verifica o usuário no pfSense**: loga, confere o acesso à página de backup e confere que ele **não** acessa páginas administrativas (gerenciador de usuários, regras, prompt de comandos). Se reprovar, **para aqui e não cria a tarefa**, mostrando o motivo;
- cria a tarefa **`pfSense Backup - FWCLIENTE`** (diária, 02:00, como SYSTEM);
- roda um **backup de teste**.

#### Outros parâmetros (opcionais)

| Parâmetro | Padrão | Para que serve |
|---|---|---|
| `-User nome` | `srvbackup-pfsense` | usuário dedicado do pfSense (`admin`/`root` são recusados) |
| `-Port 11443` | `443` (pergunta se faltar) | porta HTTPS da WebGUI. Sem ela, o instalador pergunta mostrando o padrão ([detalhes](#porta-da-webgui)) |
| `-GroupName NOME` | `BACKUP-PFSENSE` | nome do grupo mostrado nas instruções |
| `-Time 03:30` | `02:00` | horário da tarefa diária |
| `-KeepDays 180` | `90` | idade máxima dos backups |
| `-MinKeep 20` | `10` | quantidade mínima de backups preservados, mesmo antigos |
| `-IncludeRRD` | desligado | inclui os gráficos RRD (arquivo bem maior) |
| `-Encrypt` | desligado | pede o backup criptografado pelo pfSense (`.xml.enc`) |
| `-CopyTo \\NAS01\Backups\pfSense` | vazio | copia cada backup validado para `<CopyTo>\<Nome>\`, com a mesma retenção (veja [Cópia fora do servidor](#cópia-fora-do-servidor)). `-CopyTo ''` desliga |
| `-TrustNewCert` | — | aceita um certificado da WebGUI diferente do fixado (depois de uma renovação legítima) |
| `-BaseDir D:\Backups\pfSense` | `C:\pfSense-Backup` | pasta de instalação (sem espaços) |
| `-CurlPath C:\tools\curl.exe` | procura sozinho | caminho do `curl.exe`, se ele não estiver no Windows nem em `<BaseDir>\bin\curl.exe` ([detalhes](#curl-no-windows-server-2016-e-anteriores)) |
| `-Yes` | — | não pergunta nada: pré-requisito, porta (usa a salva, ou 443) e confirmação do certificado (útil em automação) |
| `-NoTest` | — | pula a verificação do usuário e o backup de teste (não recomendado) |

> Na verificação, o pfSense registra no log de sistema linhas como *"srvbackup-pfsense attempted to access system_usermanager.php but does not have access"*. Isso é **esperado**: é o teste confirmando que o usuário não tem acesso. Só acontece na instalação, não no backup diário.

### Personalizar os nomes padrão

Os scripts são genéricos. Os nomes padrão ficam num bloco só, no topo do `Install-pfSenseBackup.ps1`:

```powershell
    # ======================= PADROES (edite aqui) =======================
    [string]$User      = 'srvbackup-pfsense',   # usuario dedicado no pfSense
    [string]$GroupName = 'BACKUP-PFSENSE',      # grupo com o privilegio de backup
    [int]$Port = 443,                           # porta HTTPS da WebGUI
    [string]$Time = '02:00',
    [int]$KeepDays = 90,
    [int]$MinKeep = 10,
    [string]$BaseDir = 'C:\pfSense-Backup',
    # ===================================================================
```

Você tem duas opções:

- **Mudar o padrão da sua empresa:** edite esse bloco uma vez (ex.: `$User = 'svc-pfbackup'`). Todos os cadastros novos passam a usar esse valor.
- **Mudar só para um cliente:** não edite nada e passe o parâmetro na hora (ex.: `-User backup.cliente -Port 10443`). Fica gravado no `config\<Nome>.json` daquele perfil.

O que pode ser mudado sem quebrar nada:

| Item | Onde | Observação |
|---|---|---|
| Nome do usuário | `-User` ou bloco PADROES | precisa ser igual ao criado no pfSense |
| Nome do grupo | `-GroupName` ou bloco PADROES | só aparece nas instruções. O script verifica pelo **privilégio**, não pelo nome do grupo |
| Nome do perfil/firewall | `-Name` | vira nome de arquivo, pasta de backup e tarefa (`pfSense Backup - <Nome>`) |
| Pasta de instalação | `-BaseDir` ou bloco PADROES | sem espaços no caminho |
| Páginas "proibidas" do teste | `$ForbiddenPages` no topo do `Backup-pfSense.ps1` | páginas que o usuário de backup **não** pode acessar |

> Se o usuário de um perfil já cadastrado mudar, rode `.\Install-pfSenseBackup.ps1 -Name <Nome> -User <novo> -UpdatePassword`.

### Passo 6: validar como SYSTEM

O teste do passo 5 roda com o **seu** usuário. Para confirmar que a execução agendada também funciona:

```powershell
schtasks /Run /TN "pfSense Backup - FWCLIENTE"
Start-Sleep 10
Get-Content C:\pfSense-Backup\logs\FWCLIENTE.log -Tail 5
```

O esperado é algo assim:

```
2026-10-30T02:00:01  [FWCLIENTE]  Iniciando backup - https://192.168.1.1:443 - usuario 'srvbackup-pfsense'
2026-10-30T02:00:03  [FWCLIENTE]  OK  C:\pfSense-Backup\backups\FWCLIENTE\config-FWCLIENTE-2026-10-30_0200.xml  (412.7 KB)
2026-10-30T02:00:03  [FWCLIENTE]  Concluido.
```

### Passo 7: registrar

Anote em local interno (não neste repositório público): cliente, servidor, perfil, IP/porta, usuário do pfSense e, se usou `-Encrypt`, onde está guardada a senha de criptografia.

---

## Operação do dia a dia

| Quero… | Comando (PowerShell como Admin, em `C:\pfSense-Backup`) |
|---|---|
| Rodar um backup agora | `schtasks /Run /TN "pfSense Backup - FWCLIENTE"` |
| Ver o log | `Get-Content .\logs\FWCLIENTE.log -Tail 20` |
| Listar perfis | `Get-ChildItem .\config\*.json` |
| Listar tarefas | `schtasks /Query /FO TABLE \| findstr /I "pfSense"` |
| Trocar a senha do pfSense | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -UpdatePassword` |
| Mudar horário ou retenção | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Time 04:00 -KeepDays 180` |
| Mudar IP ou porta | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -FwHost 10.0.0.1 -Port 11443` (ou rode só com `-Name` e digite a porta nova quando ele perguntar) |
| Adicionar outro firewall no mesmo servidor | rodar o instalador com outro `-Name` |
| Ligar a cópia para fora do servidor | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Encrypt -CopyTo \\NAS01\Backups\pfSense` |
| Aceitar o certificado novo do pfSense (renovado) | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -TrustNewCert` |
| Remover um perfil (mantém os backups) | `.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Uninstall` |

Rodar o instalador de novo para um perfil existente **não** pede senha, não troca a chave e não troca o certificado fixado. Ele só atualiza o JSON e a tarefa. Os parâmetros não informados continuam com os valores atuais, inclusive os campos que você editou à mão no JSON (`Retries`, `MaxTime`...).

> Renovou o certificado da WebGUI (*System › Cert. Manager* ou *System › Advanced › Admin Access*)? O próximo backup vai falhar com *"chave do certificado do pfSense NAO confere"*. Isso é o pinning funcionando. Rode o instalador com `-TrustNewCert`, confira a impressão digital nova e pronto.

### Cópia fora do servidor

Os backups ficam no próprio servidor. Se ele morrer ou for atingido por ransomware, os backups do firewall vão junto, justo quando você mais precisa deles. Com `-CopyTo`, cada backup validado também é copiado para outro lugar:

```powershell
.\Install-pfSenseBackup.ps1 -Name FWCLIENTE -Encrypt -CopyTo \\NAS01\Backups\pfSense
```

- A tarefa roda como `SYSTEM`, que acessa a rede como a **conta do computador** (`DOMINIO\SERVIDOR$`). No compartilhamento e na pasta, dê permissão de **gravação** para essa conta, não para o seu usuário.
- Use junto com **`-Encrypt`**: fora do servidor, a ACL restrita da pasta não vale mais, e o `config.xml` tem hashes de senha e chaves de VPN.
- Se a cópia falhar, o backup local continua valendo e o Windows registra o evento **1002** (aviso).
- O teste do instalador roda com o seu usuário, então para validar a cópia **como SYSTEM** use o [passo 6](#passo-6-validar-como-system).

> Trocou a senha do usuário de backup no pfSense? Rode `-UpdatePassword`. Senão, o próximo backup falha com "login recusado".

---

## Restaurar um backup

No pfSense: *Diagnostics › Backup & Restore › **Restore Backup***

1. **Restore area:** *All* (ou só a seção desejada);
2. escolha o arquivo `config-<Nome>-<data>.xml`;
3. se o backup for `.xml.enc`, marque **Configuration file is encrypted** e informe a senha de criptografia;
4. **Restore Configuration**. O firewall reinicia.

> Em hardware novo, os nomes das placas de rede (`igb0`, `em0`…) podem mudar. O pfSense pede para reatribuir as interfaces depois do restore.

---

## Monitoramento

Cada execução grava um evento em **Log de Aplicativo**, origem `pfSense-Backup`:

| ID | Tipo | Quando |
|---|---|---|
| 1000 | Informação | backup OK (caminho e tamanho na mensagem) |
| 1001 | Erro | backup falhou (motivo na mensagem) |
| 1002 | Aviso | backup local OK, mas a cópia para o `CopyTo` falhou |

Ver os últimos eventos:

```powershell
Get-EventLog -LogName Application -Source pfSense-Backup -Newest 10
```

**Zabbix (agente Windows, item ativo):** dá para alertar quando aparece um erro ou quando falta sucesso.

- Erro: `eventlog[Application,,"Error",pfSense-Backup,1001,,skip]` + trigger em qualquer valor novo.
- Ausência de sucesso: `eventlog[Application,,"Information",pfSense-Backup,1000,,skip]` + trigger `nodata(26h)=1`.
- Cópia externa: `eventlog[Application,,"Warning",pfSense-Backup,1002,,skip]` + trigger em qualquer valor novo.

---

## Problemas comuns

| Mensagem no log | Causa provável | O que fazer |
|---|---|---|
| `curl falhou (exit 7)` / `(exit 28)` | Não conectou ou deu timeout | Conferir IP, porta da WebGUI e regra de firewall (`Test-NetConnection`) |
| `curl falhou (exit 35)` / `(exit 60)` | Problema de TLS | Conferir se a porta é mesmo HTTPS da WebGUI |
| `chave do certificado do pfSense NAO confere` (exit 90) | O certificado da WebGUI foi renovado **ou** outro equipamento está respondendo no lugar do firewall. A senha **não** foi enviada | Confirmar com o cliente se houve troca do certificado. Se sim, rodar o instalador com `-TrustNewCert` e conferir a impressão digital. Se não, investigar a rede |
| `A chave do certificado do pfSense MUDOU desde o cadastro` (no instalador) | Mesma situação, detectada ao rodar o instalador | Idem: `-TrustNewCert` só depois de confirmar |
| `AVISO: perfil sem PubKeyPin` | Perfil criado antes do pinning, ou o instalador não conseguiu ler o certificado | Rodar o instalador de novo com o pfSense acessível |
| `curl falhou (exit 2)` | `curl.exe` antigo demais (sem `--pinnedpubkey` ou `-K -`) | Usar o curl do Windows 10 1803+/Server 2019+, ou um curl recente em `CurlPath` |
| `tentativa 1 de 3 falhou: ...` | Falha temporária (rede, timeout). O script vai tentar de novo sozinho | Nada, se a tentativa seguinte der OK. Se todas falharem, vira o erro da última |
| `AVISO: copia externa para '...' falhou` (evento 1002) | Compartilhamento fora do ar ou sem permissão para a conta do computador | Dar permissão de gravação para `DOMINIO\SERVIDOR$` no compartilhamento e na pasta; testar com `schtasks /Run` |
| `nao achei o token CSRF na tela de login` | A URL não é um pfSense, ou a porta é HTTP | Conferir host e porta |
| `login recusado` | Senha errada ou usuário desativado | Conferir o usuário no pfSense, rodar `-UpdatePassword` |
| `logou mas NAO tem acesso a pagina de backup` | O grupo não tem o privilégio certo. Quase sempre foram marcados os itens **Auto Config Backup** | No grupo `BACKUP-PFSENSE`, deixar **só** `WebCfg - Diagnostics: Backup & Restore` (passo 2.1) |
| `tem privilegio DEMAIS (acessa: …)` | Usuário no grupo `admins` ou com privilégios extras | Tirar de qualquer outro grupo e zerar os privilégios próprios; deixar só no `BACKUP-PFSENSE` |
| `Nao use 'admin'` | Tentou usar o admin | Criar o usuário dedicado (passo 2.2) |
| `Verificacao REPROVADA - a tarefa NAO foi criada` | Uma das linhas acima | Ler a mensagem logo acima dela, corrigir no pfSense e rodar o instalador de novo |
| `XML invalido/incompleto` | Download cortado (rede) | Já é repetido sozinho. Se continuar, aumentar `MaxTime` (e/ou `ConnectTimeout`) no JSON |
| `arquivo pequeno demais` | O pfSense devolveu uma página de erro em vez do XML | Ver o "Inicio:" na mensagem; normalmente é login ou privilégio |
| `curl.exe nao encontrado` | Server 2016 / 2012 R2, que não trazem o curl | Copiar o curl oficial para `C:\pfSense-Backup\bin\curl.exe` e rodar o instalador de novo ([passo a passo](#curl-no-windows-server-2016-e-anteriores)) |
| `... e o curl 7.xx: antigo demais` | Curl sem suporte a fixar o certificado | Baixar o curl atual em https://curl.se/windows/ |
| `Key not valid for use in specified state` | Chave e senha não combinam (arquivo trocado ou copiado de outro servidor) | Rodar `-UpdatePassword` |
| Funciona no teste manual mas não na tarefa | Diferença de permissão ou ACL | Rodar o instalador de novo (reaplica a ACL); ver o histórico da tarefa no Agendador |
| `O acesso ao caminho 'C:\pfSense-Backup\Backup-pfSense.ps1' foi negado` e `icacls` mostra o arquivo **sem nenhuma permissão** | Instalação feita com uma versão antiga do instalador, que deixava os arquivos sem ACL | Baixar a versão atual e rodar o instalador de novo: ele reaplica a permissão na pasta e faz o conteúdo herdar. Se mesmo assim der *acesso negado*, assumir a posse antes: `takeown /F C:\pfSense-Backup /R /A /D S` (Windows em inglês: `/D Y`) |
| `icacls falhou ao aplicar a heranca` | Arquivos com outro dono (pasta copiada de outra máquina) | `takeown /F C:\pfSense-Backup /R /A /D S` (inglês: `/D Y`) e rodar o instalador de novo |
| Bloqueio por excesso de logins errados | O pfSense bloqueia o IP após várias falhas (sshguard) | Corrigir a senha e esperar o desbloqueio, ou liberar em *Diagnostics › Tables › sshguard* |

Debug detalhado (mostra cada passo no console):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\pfSense-Backup\Backup-pfSense.ps1 -Name FWCLIENTE
```

---

## Segurança

- **A senha fica cifrada com AES‑256**, com uma chave aleatória por perfil. Chave e senha ficam numa pasta que só `SYSTEM` e `Administradores` leem. Isso protege contra leitura casual por usuários comuns e contra vazamento do arquivo de senha sozinho. **Não** protege contra um administrador do servidor, que consegue ler os dois arquivos. Por isso o usuário do pfSense só tem o privilégio de backup.
- Usamos chave AES (e não DPAPI) para a senha poder ser gravada por um admin e lida pela tarefa como `SYSTEM`, que não tem senha nem perfil do admin.
- O `config.xml` contém **hashes de senha, chaves de VPN e certificados**. A pasta `backups\` herda a mesma ACL restrita. Se você copiar os backups para outro lugar (NAS, nuvem), use `-Encrypt` ou proteja o destino.
- **A senha dá controle total do firewall**, porque o privilégio *Backup & Restore* permite restaurar uma configuração modificada. Trate-a como senha de admin.
- **Certificado fixado (pinning).** A WebGUI usa certificado autoassinado, então o curl roda com `-k`. Quem garante que é o firewall certo é o `--pinnedpubkey`, que o curl confere **mesmo com `-k`**, antes de enviar qualquer dado. A chave é capturada pelo instalador, que mostra a impressão digital para você conferir no navegador. Mesmo assim, não aponte para um pfSense pela internet.
- **A senha não aparece na lista de processos.** Ela vai para o `curl.exe` pela entrada padrão (`-K -`), em UTF‑8, e não pela linha de comando. Isso também evita um bug do Windows PowerShell 5.1 que corrompia senhas com aspas (`"`).
- O script encerra a sessão no pfSense (logout) depois de cada backup.
- Com `-CopyTo`, use `-Encrypt`: fora do servidor, a ACL restrita da pasta não acompanha os arquivos.
- **Nunca publique** `config\*.json`, `secrets\`, `backups\` ou `logs\`. O `.gitignore` deste repositório já bloqueia esses caminhos.

---

## Referência dos arquivos

### `config\<Nome>.json`

Criado pelo instalador. Pode ser editado à mão. Modelo em [`config/EXEMPLO.json.example`](config/EXEMPLO.json.example).

| Campo | Tipo | Descrição |
|---|---|---|
| `Name` | texto | nome do perfil (informativo) |
| `Host` | texto | IP ou nome do pfSense |
| `Port` | número | porta HTTPS da WebGUI |
| `User` | texto | usuário do pfSense |
| `KeepDays` | número | apaga backups mais velhos que isso… |
| `MinKeep` | número | …mas sempre mantém essa quantidade dos mais recentes |
| `IncludeRRD` | bool | inclui os gráficos RRD |
| `Encrypt` | bool | baixa criptografado (requer `secrets\<Nome>.encpass`) |
| `CopyTo` | texto | pasta fora do servidor para a cópia de cada backup (vazio = desligado) |
| `PubKeyPin` | texto | chave fixada do certificado da WebGUI (`sha256//...`), gravada pelo instalador. Vazio = sem verificação (não recomendado) |
| `ConnectTimeout` | número | timeout de conexão em segundos (padrão 15) |
| `MaxTime` | número | tempo máximo de cada requisição em segundos (padrão 300; aumente se usar `IncludeRRD`) |
| `Retries` | número | tentativas em caso de falha de rede (padrão 3) |
| `RetryDelay` | número | segundos entre as tentativas (padrão 60) |
| `CurlPath` | texto | caminho do curl.exe, gravado pelo instalador quando não é o do Windows; vazio = `C:\Windows\System32\curl.exe`, ou `<BaseDir>\bin\curl.exe` se o do Windows não existir |

Rodar o instalador de novo preserva os valores editados à mão.

### Códigos de saída

`Backup-pfSense.ps1` sai com `0` em caso de sucesso e `1` em caso de erro. O Agendador de Tarefas mostra isso em *Last Run Result*.

---

## Checklist rápido

Para um cliente novo:

- [ ] IP da LAN e porta da WebGUI anotados
- [ ] Grupo `BACKUP-PFSENSE` criado no pfSense, **só** com `WebCfg - Diagnostics: Backup & Restore` (não Auto Config Backup)
- [ ] Usuário `srvbackup-pfsense` criado, membro **só** desse grupo, sem privilégios próprios
- [ ] `Test-NetConnection <ip> -Port <porta>` OK a partir do servidor
- [ ] Scripts copiados e desbloqueados (`Unblock-File`)
- [ ] `Install-pfSenseBackup.ps1 -Name ... -FwHost ... -Port ... -User ...` rodado como Admin
- [ ] Impressão digital do certificado conferida com o navegador e fixada
- [ ] Instalador mostrou `usuario correto: acessa o backup e nada alem disso`
- [ ] Backup de teste OK
- [ ] `schtasks /Run` + log OK (execução como SYSTEM)
- [ ] (Recomendado) `-Encrypt -CopyTo` para uma cópia fora do servidor, com permissão para a conta do computador
- [ ] Monitoramento do evento 1001 / ausência do 1000 (e 1002, se usar `CopyTo`) configurado
- [ ] Dados do cadastro registrados internamente (fora deste repo)

---

## Licença

[MIT](LICENSE): use, modifique e redistribua livremente.
