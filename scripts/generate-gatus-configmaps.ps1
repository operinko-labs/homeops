#!/usr/bin/env pwsh
# Generate Gatus ConfigMaps for all HTTPRoutes

$httproutes = @(
  @{app="headlamp"; namespace="tools"; scope="external"; path="/"},
  @{app="vaultwarden"; namespace="security"; scope="external"; path="/"},
  @{app="authentik"; namespace="security"; scope="external"; path="/"; subdomain="auth"},
  @{app="prometheus"; namespace="observability"; scope="internal"; path="/"},
  @{app="kromgo"; namespace="observability"; scope="internal"; path="/talos_version"},
  @{app="grafana"; namespace="observability"; scope="internal"; path="/"},
  @{app="goldilocks"; namespace="observability"; scope="external"; path="/"},
  @{app="gatus"; namespace="observability"; scope="external"; path="/"},
  @{app="traefik-dashboard"; namespace="network"; scope="external"; path="/dashboard/"; subdomain="traefik"},
  @{app="technitium"; namespace="network"; scope="internal"; path="/"},
  @{app="wizarr"; namespace="media"; scope="external"; path="/"},
  @{app="tvheadend"; namespace="media"; scope="external"; path="/status"},
  @{app="tautulli"; namespace="media"; scope="external"; path="/status"},
  @{app="spotarr"; namespace="media"; scope="internal"; path="/"},
  @{app="sonarr"; namespace="media"; scope="external"; path="/"},
  @{app="sabnzbd"; namespace="media"; scope="internal"; path="/"},
  @{app="readarr"; namespace="media"; scope="external"; path="/"},
  @{app="radarr"; namespace="media"; scope="external"; path="/"},
  @{app="prowlarr"; namespace="media"; scope="internal"; path="/"},
  @{app="huntarr"; namespace="media"; scope="internal"; path="/"},
  @{app="bazarr"; namespace="media"; scope="internal"; path="/"},
  @{app="homepage"; namespace="default"; scope="internal"; path="/"},
  @{app="echo"; namespace="default"; scope="external"; path="/"},
  @{app="audiobookshelf"; namespace="default"; scope="external"; path="/"},
  @{app="atuin"; namespace="default"; scope="external"; path="/"; subdomain="sh"}
)

function Generate-GatusConfigMap {
  param(
    [string]$app,
    [string]$namespace,
    [string]$scope,
    [string]$path = "/",
    [string]$subdomain = $null,
    [int]$status = 200
  )

  $hostname = if ($subdomain) { $subdomain } else { $app }
  $url = "https://${hostname}.vaderrp.com${path}"

  $configMap = @"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${app}-gatus-ep
  namespace: ${namespace}
  labels:
    gatus.io/enabled: "true"
data:
  config.yaml: |
"@

  if ($scope -eq "external") {
    $configMap += @"

    endpoints:
      - name: "${app} (external)"
        group: external
        url: "${url}"
        interval: 1m
        client:
          dns-resolver: tcp://1.1.1.1:53
          timeout: 15s
        conditions:
          - "[STATUS] == ${status}"

      - name: "${app} (internal)"
        group: internal
        url: "${url}"
        interval: 1m
        client:
          dns-resolver: tcp://192.168.5.8:53
          timeout: 15s
        conditions:
          - "[STATUS] == ${status}"
"@
  } else {
    # internal/guarded - DNS check only
    $configMap += @"

    endpoints:
      - name: "${app}"
        group: guarded
        url: 1.1.1.1
        interval: 1m
        ui:
          hide-hostname: true
          hide-url: true
        dns:
          query-name: "${hostname}.vaderrp.com"
          query-type: A
        conditions:
          - "len([BODY]) == 0"
"@
  }

  return $configMap
}

# Generate ConfigMaps
foreach ($route in $httproutes) {
  $appDir = "kubernetes/argocd/applications/$($route.namespace)/apps/$($route.app)"

  # Check if app directory exists
  if (Test-Path $appDir) {
    $outputFile = "$appDir/gatus-configmap.yaml"

    $params = @{
      app = $route.app
      namespace = $route.namespace
      scope = $route.scope
      path = $route.path
    }

    if ($route.subdomain) {
      $params.subdomain = $route.subdomain
    }

    $content = Generate-GatusConfigMap @params

    Set-Content -Path $outputFile -Value $content -NoNewline
    Write-Host "✅ Created: $outputFile"
  } else {
    Write-Host "⚠️  Directory not found: $appDir"
  }
}

Write-Host "`n✨ Done! Generated Gatus ConfigMaps for all HTTPRoutes."

