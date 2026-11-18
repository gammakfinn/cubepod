# DIAGNOSTIC ONLY (branch diag/fc-eio-hotplug, never merged): samples guest-side
# block capacity around Firecracker drive PATCH hotplugs inside one Kata FC VM.
kata_fc_hotplug_probe() {
  [[ "$KATA_VMM" == fc ]] || return 0
  local start; start=$(date -u '+%Y-%m-%d %H:%M:%S')
  local victims=''
  for i in 1 2 3 4 5; do victims+="
  - name: victim$i
    image: docker.io/cubepod-kind/sandbox:$CLUSTER_NAME
    imagePullPolicy: Never
    command: [sh, -c, 'echo VICTIM${i}_OK; sleep 3600']"; done
  cat <<YAML | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: fc-hotplug-probe, namespace: default}
spec:
  runtimeClassName: kata-fc-e2e
  automountServiceAccountToken: false
  restartPolicy: Always
  containers:
  - name: watcher
    image: docker.io/cubepod-kind/sandbox:$CLUSTER_NAME
    imagePullPolicy: Never
    securityContext: {privileged: true}
    command:
    - bash
    - -c
    - |
      read -r up _ </proc/uptime; echo "CLOCK epoch=\$EPOCHREALTIME uptime=\$up"
      declare -A last; end=\$((SECONDS+150))
      while (( SECONDS < end )); do
        for f in /sys/block/vd*/size; do
          n=\${f#/sys/block/}; n=\${n%/size}; read -r v <"\$f"
          if [[ "\${last[\$n]:-x}" != "\$v" ]]; then read -r up _ </proc/uptime; echo "SIZE epoch=\$EPOCHREALTIME uptime=\$up dev=\$n sectors=\$v"; last[\$n]=\$v; fi
        done
      done
      echo DMESG_BEGIN; dmesg 2>&1 || timeout 2 cat /dev/kmsg; echo DMESG_END
      grep -E ' /run/kata-containers| /dev/vd' /proc/self/mountinfo /proc/mounts 2>/dev/null | head -50
      sleep 3600$victims
YAML
  local deadline=$((SECONDS + 200))
  while (( SECONDS < deadline )); do
    if kubectl --context "kind-$CLUSTER_NAME" --request-timeout=5s logs fc-hotplug-probe -c watcher 2>/dev/null | grep -q DMESG_END; then break; fi
    sleep 5
  done
  k logs fc-hotplug-probe -c watcher >"$ARTIFACTS/diag-hotplug-watcher.log" 2>&1 || true
  k get pod fc-hotplug-probe -o yaml >"$ARTIFACTS/diag-hotplug-pod.yaml" 2>&1 || true
  k describe pod fc-hotplug-probe >"$ARTIFACTS/diag-hotplug-describe.txt" 2>&1 || true
  k get events -n default --sort-by=.lastTimestamp >"$ARTIFACTS/diag-hotplug-events.txt" 2>&1 || true
  kata_node journalctl --no-pager --since "$start" -u containerd >"$ARTIFACTS/diag-hotplug-containerd.log" 2>&1 || true
  kata_node journalctl --no-pager --since "$start" -t kata >"$ARTIFACTS/diag-hotplug-kata.log" 2>&1 || true
  k delete pod fc-hotplug-probe --wait=true --timeout=90s || true
}
