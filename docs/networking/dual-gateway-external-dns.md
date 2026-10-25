Dual-Gateway + external-dns Setup

Overview
- Two Gateways on the same Traefik controller/VIP stack
  - gateway-public (VIP 192.168.7.5): publishes public CNAMEs in Cloudflare via external-dns
    - metadata.annotations: external-dns.alpha.kubernetes.io/target=external.vaderrp.com
    - external-dns (Cloudflare): --sources=gateway-httproute --gateway-name=gateway-public
  - gateway-internal (VIP 192.168.7.4): publishes internal A records via external-dns RFC2136 to Technitium
    - No external-dns annotations on the Gateway
    - internal-dns (RFC2136): --sources=gateway-httproute --gateway-name=gateway-internal
- HTTPRoutes attach to the appropriate Gateway via spec.parentRefs
- Split-horizon:
  - Public DNS (Cloudflare) resolves external services to CNAME external.vaderrp.com (Cloudflare Tunnel)
  - Internal DNS (Technitium/CoreDNS) resolves internal services to 192.168.7.4

Route Labeling
- All HTTPRoutes are labeled for clarity
  - route.scope=external | route.scope=internal (based on parentRef)

Gatus Monitoring
- Each app can be monitored via two endpoints to validate both paths
  - External: DNS resolver 1.1.1.1, URL https://<app>.vaderrp.com
  - Internal: DNS resolver 192.168.5.8 (ns1), URL https://<app>.vaderrp.com
  - File: kubernetes/components/gatus/external/config.yaml

Operational Notes
- Avoid per-HTTPRoute external-dns target annotations; gateway-httproute source uses Gateway annotations
- If a service moves between internal/external, update the HTTPRoute parentRef and optionally label
- To verify resolution paths:
  - nslookup app.vaderrp.com 1.1.1.1 (public path)
  - nslookup app.vaderrp.com 192.168.5.8 (internal path)
  - traceroute app.vaderrp.com

