#!/usr/bin/env bash
# Prueba de autorrecuperacion. Uso: bash circuit-breaker.sh
# Borra pods de PharmacyService SIN modificar las replicas del Deployment.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash circuit-breaker.sh. Borra pods de PharmacyService sin cambiar replicas y comprueba la recuperacion.'
    echo 'Puerto opcional: LOCAL_PORT=15002 bash circuit-breaker.sh'
    exit 0
fi
[[ $# == 0 ]] || { echo 'Uso: bash circuit-breaker.sh'; exit 1; }

DIRECTORIO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIRECTORIO/chaos-requests.sh"
NAMESPACE=pharmago
DEPLOYMENT=pharmago-pharmacy-service
PUERTO=${LOCAL_PORT:-15001}
[[ "$PUERTO" =~ ^[1-9][0-9]*$ ]] && (( PUERTO < 65536 )) || { echo 'LOCAL_PORT invalido'; exit 1; }
RUN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SALIDA="$DIRECTORIO/../../../evidencias/autorrecuperacion/$RUN"
PF_PID='' LOG_PID='' LINEAS_LOG=0

limpiar() {
    local resultado=$?
    trap - EXIT
    for pid in "$PF_PID" "$LOG_PID"; do
        if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
    rm -f -- "$SALIDA/headers.tmp" "$SALIDA/body.tmp"
    echo "Evidencias: $SALIDA"
    exit "$resultado"
}

for comando in kubectl curl awk sed wc; do command -v "$comando" >/dev/null; done
mkdir -p "$SALIDA"
: > "$SALIDA/users.jsonl"
echo 'timestamp_utc,fase,ruta,http,segundos,circuito' > "$SALIDA/requests.csv"
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo '1. Verificando replicas y eligiendo un pod de UsersService...'
REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
[[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]] || { echo 'PharmacyService debe tener replicas activas'; exit 1; }
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
UIDS_ANTES=$(kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[*].metadata.uid}')
kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o wide > "$SALIDA/pods-antes.txt"
USERS_POD=$(kubectl get pods -n "$NAMESPACE" -l app=pharmago-users-service \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl wait --for=condition=Ready "pod/$USERS_POD" -n "$NAMESPACE" --timeout=30s

echo "2. Abriendo consultas y logs contra $USERS_POD en puerto $PUERTO..."
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' kubectl port-forward \
    -n "$NAMESPACE" "pod/$USERS_POD" "$PUERTO:80" > "$SALIDA/port-forward.log" 2>&1 &
PF_PID=$!
LISTO=0
for (( intento=1; intento<=20; intento++ )); do
    sleep 1
    kill -0 "$PF_PID" 2>/dev/null || { echo 'Port-forward fallo: revisar su log o cambiar LOCAL_PORT'; exit 1; }
    if curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:$PUERTO/health"; then LISTO=1; break; fi
done
(( LISTO == 1 )) || { echo 'No se pudo conectar a UsersService'; exit 1; }
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' kubectl logs -n "$NAMESPACE" \
    "$USERS_POD" -f --since=1s > "$SALIDA/users.jsonl" 2> "$SALIDA/log-follow.log" &
LOG_PID=$!
consultar antes
[[ "$HTTP" == 200 && "$ESTADO" == closed ]] || { echo 'La prueba requiere HTTP 200 y circuito cerrado al inicio'; exit 1; }

echo "3. Borrando los pods de PharmacyService. El Deployment conserva $REPLICAS replicas."
kubectl delete pod -n "$NAMESPACE" -l app="$DEPLOYMENT" --wait=false
consultar users-independiente /api/roles/ping
[[ "$HTTP" == 200 ]] || { echo 'FAIL: la ruta independiente de UsersService no responde'; exit 1; }

echo '4. Enviando consultas mientras Kubernetes crea los reemplazos...'
RECUPERADO=0
for (( intento=1; intento<=40; intento++ )); do
    consultar "recuperacion-$intento"
    DISPONIBLES=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}')
    UIDS_AHORA=$(kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[*].metadata.uid}')
    NUEVOS=1
    for uid in $UIDS_ANTES; do
        if [[ " $UIDS_AHORA " == *" $uid "* ]]; then NUEVOS=0; fi
    done
    if [[ "$DISPONIBLES" == "$REPLICAS" && "$NUEVOS" == 1 && "$HTTP" == 200 && "$ESTADO" == closed ]]; then
        RECUPERADO=1; break
    fi
    sleep 2
done
(( RECUPERADO == 1 )) || { echo 'FAIL: no se verifico la recuperacion dentro del plazo'; exit 1; }
[[ $(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}') == "$REPLICAS" ]] ||
    { echo 'FAIL: cambio la cantidad deseada de replicas durante la prueba'; exit 1; }
kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o wide | tee "$SALIDA/pods-despues.txt"
sleep 1
mostrar_logs
echo "PASS: pods nuevos, $REPLICAS replicas disponibles y HTTP 200. Kubernetes se recupero sin escalar."
echo 'Si no se abrio el circuito, la interrupcion fue demasiado breve para alcanzar su umbral.'
