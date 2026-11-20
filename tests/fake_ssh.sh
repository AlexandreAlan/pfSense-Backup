#!/usr/bin/env bash
# ssh simulado para os testes do modo SSH: ignora as opcoes, junta o comando remoto
# (o que vem depois de usuario@host) e roda o COMANDO FORCADO de verdade, gerado pelo
# proprio Logs-pfSense.ps1 (New-ForcedCommand) e salvo em $FAKE_FORCED - igual ao sshd
# do pfSense faz com o command="..." do authorized_keys.
cmd=""; achou=0
for a in "$@"; do
  if [ $achou -eq 1 ]; then cmd="$cmd $a"; elif [[ "$a" == *@* && "$a" != -* ]]; then achou=1; fi
done
export SSH_ORIGINAL_COMMAND="${cmd# }"
exec sh -c "$(cat "$FAKE_FORCED")"
