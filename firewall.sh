#!/bin/sh
# Drop what a job container starts toward the host, the cloud metadata service and private networks.
# Idempotent; the service re-runs it whenever Docker restarts. Replies are not matched (-i docker0 is container-originated only).
set -eu

rule() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
rule6() { ip6tables -C "$@" 2>/dev/null || ip6tables -I "$@"; }

rule INPUT -i docker0 -m conntrack --ctstate NEW -j DROP
for net in 169.254.0.0/16 168.63.129.16/32 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
  rule DOCKER-USER -i docker0 -d "$net" -j DROP
done

# Docker's IPv6 is off, so a container has no v6 route; this keeps it that way if someone turns it on.
if command -v ip6tables >/dev/null 2>&1; then
  rule6 INPUT -i docker0 -j DROP
  if ip6tables -S DOCKER-USER >/dev/null 2>&1; then
    rule6 DOCKER-USER -i docker0 -j DROP
  else
    rule6 FORWARD -i docker0 -j DROP
  fi
fi
