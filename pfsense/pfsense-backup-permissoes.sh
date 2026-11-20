#!/bin/sh
# pfSense-Backup - permissoes dos logs para a coleta pelo SSH (roda NO pfSense, como root)
#
# Deixa os arquivos de log que a chave travada pode ler (lista fixa: os mesmos do
# comando forcado do Logs-pfSense.ps1) legiveis pelo GRUPO do usuario de backup -
# e por mais ninguem alem do root. Nao altera conteudo, nao muda donos, nao abre nada.
#
# Precisa rodar de tempos em tempos (cron a cada 10 min): quando um log gira, o
# pfSense recria o arquivo so para o root, e o script devolve a leitura ao grupo.
#
# Uso:  sh /root/bin/pfsense-backup-permissoes.sh [GRUPO]      (padrao: LOGS-PFSENSE)
#
# Instalar (Diagnostics > Command Prompt, ou SSH como admin):
#   mkdir -p /root/bin && fetch -o /root/bin/pfsense-backup-permissoes.sh \
#     https://raw.githubusercontent.com/AlexandreAlan/pfSense-Backup/main/pfsense/pfsense-backup-permissoes.sh
#   sh /root/bin/pfsense-backup-permissoes.sh
# e agende (pacote Cron: System > Cron > Add):  */10  *  *  *  *  root  /bin/sh /root/bin/pfsense-backup-permissoes.sh

G="${1:-LOGS-PFSENSE}"
if ! pw groupshow "$G" >/dev/null 2>&1; then
    echo "grupo '$G' nao existe no pfSense (System > User Manager > Groups)." >&2
    exit 1
fi

# pastas: o grupo precisa atravessar (x) e listar (r)
for d in /var/log/arquivo /var/log/suricata /var/log/pfblockerng /var/squidGuard/log /var/squid/logs; do
    [ -d "$d" ] || continue
    chgrp "$G" "$d" && chmod g+rx "$d"
done
for d in /var/log/suricata/suricata_*; do
    [ -d "$d" ] && chmod g+rx,o+rx "$d"
done

# arquivos: so os da lista da chave travada
for f in /var/log/system.log* /var/log/auth.log* /var/log/portalauth.log* /var/log/openvpn.log* \
         /var/log/ipsec.log* /var/log/dhcpd.log* /var/log/resolver.log* /var/log/gateways.log* \
         /var/log/filter.log* /var/log/ppp.log* /var/log/arquivo/* /var/log/pfblockerng/*.log \
         /var/log/suricata/suricata_*/alerts.log* /var/log/suricata/suricata_*/block.log* \
         /var/squidGuard/log/block.log* /var/squid/logs/access.log*; do
    [ -f "$f" ] || continue
    chgrp "$G" "$f" 2>/dev/null && chmod g+r "$f"
done
exit 0
