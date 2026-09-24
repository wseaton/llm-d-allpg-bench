#!/bin/sh
# sampler.sh EPP_METRICS_HOSTPORT VCR_IP... : every 2 s, EPP flow-control saturation and queue sizes and
# each engine's running/waiting counts, prefixed by a "T <unix seconds>" line.
epp=$1; shift
while true; do
  echo "T $(date +%s)"
  wget -T 3 -qO- "http://$epp/metrics" | grep -E '^llm_d_epp_flow_control_(pool_saturation|queue_size|requests_total)'
  for ip in "$@"; do
    wget -T 3 -qO- "http://$ip:8000/metrics" | grep -E '^vllm:num_requests_(running|waiting)' | sed "s/^/$ip /"
  done
  sleep 2
done
