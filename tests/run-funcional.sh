#!/usr/bin/env bash
# Sobe o pfSense simulado (HTTPS com certificado autoassinado novo) e roda os
# testes funcionais. Precisa de: pwsh, python3, openssl e curl.
# Uso: tests/run-funcional.sh            (PWSH=/caminho/pwsh para outro pwsh)
set -euo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
PWSH="${PWSH:-pwsh}"
PORTA="${PORTA:-18443}"
WORK="$(mktemp -d)"
trap 'kill "${MOCK:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Senhas com tudo que ja quebrou ou poderia quebrar: aspas, barra no meio e no
# fim, $, :, crase, espaco, acento, % e &.
SENHA='Abc"12\3 ção$x:`y'
ENC='Enc"\\ ção%20&='

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/O=pfSense/CN=pfSense-mock" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PIN="$(openssl x509 -in "$WORK/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der |
       openssl dgst -sha256 -binary | base64)"

python3 "$AQUI/mock_pfsense.py" "$SENHA" "$ENC" "$PORTA" "$WORK/cert.pem" "$WORK/key.pem" &
MOCK=$!
for _ in $(seq 1 50); do curl -sk -o /dev/null "https://127.0.0.1:$PORTA/stats" && break; sleep 0.2; done

"$PWSH" -NoProfile -File "$AQUI/Test-Funcional.ps1" -Senha "$SENHA" -SenhaEnc "$ENC" \
    -PinOpenssl "$PIN" -Porta "$PORTA" -WorkDir "$WORK"
