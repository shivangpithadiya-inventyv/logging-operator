#!/bin/bash

now=$(date -u +%s)

kubectl get pods -A -o json | jq -r '
  .items[] |
  select(
    any(.spec.containers[]?; .name=="istio-proxy") or
    any(.spec.initContainers[]?; .name=="istio-proxy")
  ) |
  "\(.metadata.namespace) \(.metadata.name)"
' | sort -u > /tmp/pods_list.txt

echo "Total unique pods with istio-proxy: $(wc -l < /tmp/pods_list.txt)"

check_pod() {
  ns="$1"
  pod="$2"
  now=$(date -u +%s)

  token=$(kubectl exec -n "$ns" "$pod" -c istio-proxy -- \
    cat /var/run/secrets/tokens/istio-token 2>/dev/null)
  [ -z "$token" ] && return

  exp=$(python3 -c "
import base64, json
token = '''$token'''.strip()
try:
    payload = token.split('.')[1]
    padded = payload + '=' * (-len(payload) % 4)
    data = json.loads(base64.urlsafe_b64decode(padded))
    print(data.get('exp',''))
except Exception:
    print('')
" 2>/dev/null)

  [ -z "$exp" ] && return

  secs_left=$(( exp - now ))
  exp_human=$(date -u -d @"$exp" +"%Y-%m-%d %H:%M:%S")
  printf "%s\t%s\t%s\t%s\n" "$ns" "$pod" "$exp_human" "$secs_left"
}
export -f check_pod

echo "---- TOP 10 SOONEST TO EXPIRE ----"
printf "NAMESPACE\tPOD\tEXP_UTC\t\tSECS_LEFT\n"

cat /tmp/pods_list.txt | xargs -P 30 -n2 bash -c 'check_pod "$@"' _ \
  | sort -t$'\t' -k4 -n \
  | head -10
