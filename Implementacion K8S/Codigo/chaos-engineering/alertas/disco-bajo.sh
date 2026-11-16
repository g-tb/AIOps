#!/usr/bin/env bash
# Crea un ext4 de solo 128 MiB; nunca llena el disco real de Minikube.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash disco-bajo.sh [--restore]. Filesystem temporal ext4 al >85% por 360 segundos.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
[[ $(kubectl config current-context) == minikube ]] || { echo 'Selecciona el contexto minikube.'; exit 1; }
POD=caos-alerta-disco
limpiar() { kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true; }
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
[[ $(kubectl get nodes -o name | wc -l) == 1 ]] || { echo 'Requiere un unico nodo.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Privilegios solo para montar/desmontar el disco de prueba en el nodo.
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: caos-alerta-disco
  namespace: pharmago
  labels:
    caos: alertas
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 30
  containers:
    - name: disco
      image: alpine:3.20
      securityContext:
        privileged: true
      readinessProbe:
        exec:
          command: [sh, -c, 'test -f /tmp/listo']
        periodSeconds: 2
      volumeMounts:
        - name: disco
          mountPath: /disco
          mountPropagation: Bidirectional
      command: [sh, -ec]
      args:
        - |
          apk add --no-cache e2fsprogs util-linux
          test ! -e /disco/prueba.img
          # Dejar al menos 256 MiB libres antes de crear el disco de 128 MiB.
          df -Pk /disco | awk 'NR == 2 {if ($4 < 262144) exit 1}'
          mkdir -p /disco/montaje
          limpiar() {
            if mountpoint -q /disco/montaje; then
              umount /disco/montaje || return 1
            fi
            rm -f /disco/prueba.img
          }
          trap limpiar EXIT
          trap 'exit 143' TERM
          trap 'exit 130' INT
          truncate -s 128M /disco/prueba.img
          mkfs.ext4 -F -m 0 /disco/prueba.img
          mount -o loop /disco/prueba.img /disco/montaje
          dd if=/dev/zero of=/disco/montaje/relleno bs=1M count=100
          sync
          df -h /disco/montaje
          touch /tmp/listo
          echo 'Filesystem temporal ocupado. Se desmonta y elimina en 360 segundos.'
          sleep 360 &
          wait $!
  volumes:
    - name: disco
      hostPath:
        path: /tmp/caos-alerta-disco
        type: DirectoryOrCreate
YAML
kubectl wait -n pharmago --for=condition=Ready "pod/$POD" --timeout=150s
# El bind mount original de node-exporter debe reconocer el nuevo filesystem.
kubectl delete pod -n pharmago -l app=node-exporter --wait=true
kubectl rollout status daemonset/node-exporter -n pharmago --timeout=120s
echo 'Buscar mountpoint=/tmp/caos-alerta-disco/montaje en Prometheus.'
kubectl logs -n pharmago -f "$POD"
kubectl wait -n pharmago --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=15s
