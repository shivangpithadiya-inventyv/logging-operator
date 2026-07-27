#!/bin/sh

now=$(date -u +%s)
tmpdir=$(mktemp -d)

kubectl get pods -A -o json | jq -r '
  .items[] |
  select(
    any(.spec.containers[]?; .name=="istio-proxy") or
    any(.spec.initContainers[]?; .name=="istio-proxy")
  ) |
  "\(.metadata.namespace) \(.metadata.name)"
' | sort -u > "$tmpdir/pods_list.txt"

total=$(wc -l < "$tmpdir/pods_list.txt")
echo "Total unique pods with istio-proxy: $total"

i=0
maxjobs=30

while read -r ns pod; do
  [ -z "$ns" ] && continue
  i=$((i+1))

  (
    now=$(date -u +%s)
    token=$(kubectl exec -n "$ns" "$pod" -c istio-proxy -- \
      cat /var/run/secrets/tokens/istio-token 2>/dev/null)
    [ -z "$token" ] && exit 0

    payload=$(echo "$token" | cut -d. -f2)
    padded=$(echo "$payload" | tr '_-' '/+')
    mod=$(( ${#padded} % 4 ))
    [ "$mod" = "2" ] && padded="${padded}=="
    [ "$mod" = "3" ] && padded="${padded}="

    exp=$(echo "$padded" | base64 -d 2>/dev/null | jq -r '.exp' 2>/dev/null)
    [ -z "$exp" ] || [ "$exp" = "null" ] && exit 0

    secs_left=$(( exp - now ))
    exp_human=$(date -u -d @"$exp" +"%Y-%m-%d %H:%M:%S")
    printf "%s\t%s\t%s\t%s\n" "$ns" "$pod" "$exp_human" "$secs_left" > "$tmpdir/result_$i.txt"
  ) &

  # throttle: wait if we've hit maxjobs concurrent background jobs
  if [ $(( i % maxjobs )) -eq 0 ]; then
    wait
  fi

done < "$tmpdir/pods_list.txt"

wait

echo "---- TOP 10 SOONEST TO EXPIRE ----"
printf "NAMESPACE\tPOD\tEXP_UTC\t\tSECS_LEFT\n"
cat "$tmpdir"/result_*.txt 2>/dev/null | sort -t'	' -k4 -n | head -10

rm -rf "$tmpdir"
