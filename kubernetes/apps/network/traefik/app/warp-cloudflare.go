// Package cloudflare contains a list of current Cloudflare IP ranges
package cloudflare

import (
	"bufio"
	"fmt"
	"net/http"
	"time"
)

// homeops patch (forge/config/edge/traefik-warp-failclosed.patch): a bounded
// fetch, and never the upstream fallback that trusted 192.168.0.0/16,
// 10.0.0.0/8 and 172.16.0.0/12 whenever Cloudflare's list was unreachable,
// which let any LAN client forge CF-Connecting-IP into X-Real-IP.
var client = &http.Client{Timeout: 10 * time.Second}

// lastGood is the most recent complete list, shared by every middleware
// instance in this plugin's interpreter.
var lastGood []string

// TrustedIPS fetches Cloudflare's current IP ranges (IPv4 + IPv6).
func TrustedIPS() []string {
	urls := []string{
		"https://www.cloudflare.com/ips-v4",
		"https://www.cloudflare.com/ips-v6",
	}

	var ipList []string
	complete := true
	for _, url := range urls {
		resp, err := client.Get(url)
		if err != nil {
			fmt.Println("Error fetching", url, ":", err)
			complete = false
			continue
		}
		if resp.StatusCode != http.StatusOK {
			fmt.Println("Error fetching", url, ": status", resp.StatusCode)
			resp.Body.Close()
			complete = false
			continue
		}

		scanner := bufio.NewScanner(resp.Body)
		for scanner.Scan() {
			ip := scanner.Text()
			if ip != "" {
				ipList = append(ipList, ip)
			}
		}
		if err := scanner.Err(); err != nil {
			fmt.Println("Error reading response from", url, ":", err)
			complete = false
		}
		resp.Body.Close()
	}

	// A failed or partial fetch keeps the last complete list; with none yet,
	// trust nobody, so X-Real-IP stays the socket IP.
	if !complete || len(ipList) == 0 {
		return lastGood
	}
	lastGood = ipList
	return ipList
}

const ClientIPHeaderName = "CF-Connecting-IP"
const CfVisitor = "CF-Visitor"
const XCfTrusted = "X-Is-Trusted"
