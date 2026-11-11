#!/usr/bin/env bash
# Auxiliar de circuit-breaker.sh: consulta UsersService, guarda CSV y muestra logs de Polly.

consultar() {
    local fase=$1 ruta=${2:-/api/roles/pharmacy-status} resultado
    resultado=$(curl -sS --max-time 35 \
        -H "X-Correlation-ID: chaos-$RUN-$fase" \
        -D "$SALIDA/headers.tmp" -o "$SALIDA/body.tmp" \
        -w '%{http_code},%{time_total}' \
        "http://127.0.0.1:$PUERTO$ruta") || true
    HTTP=${resultado%%,*}
    SEGUNDOS=${resultado#*,}
    ESTADO=$(awk -F ': *' 'tolower($1)=="x-circuit-state" {gsub("\r", "", $2); print $2}' "$SALIDA/headers.tmp")
    printf '%s,%s,%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$fase" "$ruta" "${HTTP:-000}" "$SEGUNDOS" "$ESTADO" >> "$SALIDA/requests.csv"
    printf '[%s] %s HTTP=%s tiempo=%ss circuito=%s\n' "$fase" "$ruta" "${HTTP:-000}" "$SEGUNDOS" "${ESTADO:-n/a}"
    mostrar_logs
}

mostrar_logs() {
    local total
    total=$(wc -l < "$SALIDA/users.jsonl")
    if (( total > LINEAS_LOG )); then
        sed -n "$((LINEAS_LOG + 1)),${total}p" "$SALIDA/users.jsonl" |
            awk -F '"Message":"' '/"Category":"PharmaGo.Resilience.PharmacyServiceClient"/ {
                split($2, texto, "\""); print "[LOG] " texto[1]
            }'
        LINEAS_LOG=$total
    fi
}
