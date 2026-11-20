# Relatório de auditoria

[← README](../README.md) · [Logs](logs.md) · [Atualização](atualizacao.md)

A cada backup que **muda a configuração**, o pfSense-Backup gera uma página HTML com tudo o que um auditor pede sobre o firewall, montada a partir do `config.xml` que acabou de ser baixado. Não precisa de nenhum privilégio novo no pfSense.

```
C:\pfSense-Backup\auditoria\FWCLIENTE\
    ultimo.html                                     sempre o mais recente
    2026\auditoria-FWCLIENTE-2026-11-20_0200.html   um por mudança de configuração
```

Abre em qualquer navegador e imprime bem (Ctrl+P › Salvar como PDF).

## O que tem no relatório

| Seção | Conteúdo |
|---|---|
| **Resumo** | Números do firewall e **pontos de atenção** encontrados automaticamente |
| **Mudanças** | O que mudou desde o backup anterior: regras criadas, alteradas e removidas; usuários; grupos; aliases; VPNs; NAT; certificados revogados |
| **Interfaces e VLANs** | Cada rede, porta física, tag de VLAN e endereço |
| **Gateways** | Links, monitoramento, grupos de failover e gateway padrão |
| **Regras do firewall** | Por interface, **na ordem em que o pfSense avalia**, com ação, origem, destino, log, descrição e ID. As desativadas aparecem riscadas |
| **NAT** | Redirecionamentos de porta e NAT de saída |
| **Aliases** | Nome, tipo e conteúdo |
| **Usuários e grupos** | Status, grupos, privilégios e chave SSH. **Administradores em destaque** |
| **OpenVPN** | Cada servidor: porta, rede do túnel, redes liberadas, criptografia, CA, lista de revogação e desconexão por inatividade |
| **Certificados** | CAs e certificados com validade (vencido, vence em breve, válido) e revogados |
| **IPsec** | Túneis e redes da fase 2 |
| **Portal cativo** | Zonas, interface, autenticação, tempos e vouchers |
| **DHCP** | Faixas, "só aparelhos cadastrados" e reservas (IP fixo por MAC) |
| **Acesso administrativo** | WebGUI, regra anti-bloqueio, SSH, fuso, DNS e syslog remoto |
| **Pacotes** | Pacotes instalados e versões |

### Pontos de atenção (automáticos)

- Certificado **vencido** ou vencendo em menos de 60 dias.
- Usuário **desativado** que continua no grupo de administradores.
- VPN **sem lista de revogação**: um certificado vazado não pode ser cancelado.
- SSH aceitando **senha**.
- Regras ativas **sem descrição**.
- **Redirecionamentos de porta** ativos, para conferência.

## Segurança

O relatório **nunca** mostra senhas, hashes de senha, chaves privadas, chaves de VPN (TLS), PSK do IPsec, segredo do RADIUS nem comunidade SNMP. Isso é conferido nos testes automáticos.

Mesmo assim, ele descreve a rede inteira. Trate como documento interno.

## Quando é gerado

- Pelo `Backup-pfSense.ps1`, logo depois de um backup bom. Se a configuração **não mudou** desde o backup anterior, nenhum relatório novo é criado: o `ultimo.html` continua valendo.
- Pelo instalador, uma vez, no fim da instalação ou atualização.
- **Backup criptografado** (`-Encrypt`): o `.xml.enc` não pode ser lido, então o relatório é pulado.
- Uma falha no relatório **nunca** derruba o backup: ela só vira uma linha no log.

Para desligar: instalador com `-NoReport`. Para gerar na mão:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\pfSense-Backup\Relatorio-pfSense.ps1 -Name FWCLIENTE -Force
```
