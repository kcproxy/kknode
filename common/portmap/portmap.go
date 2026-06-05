package portmap

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	log "github.com/sirupsen/logrus"
)

const commentPrefix = "FAMI_HOP"

// HopPortRange describes a single hop-port DNAT mapping rule.
type HopPortRange struct {
	StartPort   int
	EndPort     int
	ServicePort int
	Comment     string // iptables comment tag for precise cleanup
}

// ParseHopPorts parses a hop_ports string like "30001-60000" into start and end ports.
// Returns (0, 0, nil) if the string is empty.
func ParseHopPorts(hopPorts string) (start, end int, err error) {
	hopPorts = strings.TrimSpace(hopPorts)
	if hopPorts == "" {
		return 0, 0, nil
	}
	parts := strings.SplitN(hopPorts, "-", 2)
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("invalid hop_ports format: %q (expected START-END)", hopPorts)
	}
	start, err = strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return 0, 0, fmt.Errorf("invalid hop_ports start port: %v", err)
	}
	end, err = strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return 0, 0, fmt.Errorf("invalid hop_ports end port: %v", err)
	}
	if start < 1 || end < 1 || start > 65535 || end > 65535 {
		return 0, 0, fmt.Errorf("hop_ports out of range: %d-%d", start, end)
	}
	if start > end {
		return 0, 0, fmt.Errorf("hop_ports start (%d) > end (%d)", start, end)
	}
	return start, end, nil
}

// generateComment creates a unique iptables comment for a hop rule.
func generateComment(servicePort, startPort, endPort int) string {
	return fmt.Sprintf("%s_%d_%d_%d", commentPrefix, servicePort, startPort, endPort)
}

// ApplyHopPorts creates iptables and ip6tables DNAT rules for the given hop_ports range.
// Returns a HopPortRange record for later cleanup, or nil if hop_ports is empty.
func ApplyHopPorts(servicePort int, hopPorts string) (*HopPortRange, error) {
	start, end, err := ParseHopPorts(hopPorts)
	if err != nil {
		return nil, err
	}
	if start == 0 && end == 0 {
		return nil, nil // empty hop_ports, nothing to do
	}

	comment := generateComment(servicePort, start, end)
	portRange := fmt.Sprintf("%d:%d", start, end)

	removeByComment("iptables", comment)
	if err := runIptables("iptables", portRange, servicePort, comment); err != nil {
		return nil, fmt.Errorf("apply IPv4 hop rule failed: %v", err)
	}
	log.Infof("[PortMap] IPv4 DNAT 已添加: UDP %d-%d -> %d", start, end, servicePort)

	_ = exec.Command("modprobe", "ip6_tables").Run()
	_ = exec.Command("modprobe", "ip6table_nat").Run()
	removeByComment("ip6tables", comment)
	if err := runIptables("ip6tables", portRange, servicePort, comment); err != nil {
		log.Warnf("[PortMap] IPv6 DNAT 添加失败 (可能不支持): %v", err)
	} else {
		log.Infof("[PortMap] IPv6 DNAT 已添加: UDP %d-%d -> %d", start, end, servicePort)
	}

	return &HopPortRange{
		StartPort:   start,
		EndPort:     end,
		ServicePort: servicePort,
		Comment:     comment,
	}, nil
}

func runIptables(cmd string, portRange string, servicePort int, comment string) error {
	args := []string{
		"-t", "nat", "-A", "PREROUTING",
		"-p", "udp",
		"--dport", portRange,
		"-j", "DNAT",
		"--to-destination", fmt.Sprintf(":%d", servicePort),
		"-m", "comment", "--comment", comment,
	}
	out, err := exec.Command(cmd, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %s", cmd, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// RemoveHopPorts removes a single hop-port DNAT rule from both iptables and ip6tables.
func RemoveHopPorts(rule *HopPortRange) error {
	if rule == nil {
		return nil
	}
	removeByComment("iptables", rule.Comment)
	removeByComment("ip6tables", rule.Comment)
	log.Infof("[PortMap] DNAT 已清理: UDP %d-%d -> %d", rule.StartPort, rule.EndPort, rule.ServicePort)
	return nil
}

// RemoveAllHopPorts removes all hop-port DNAT rules in the list.
func RemoveAllHopPorts(rules []*HopPortRange) {
	for _, r := range rules {
		_ = RemoveHopPorts(r)
	}
}

// removeByComment finds and deletes all PREROUTING NAT rules matching the given comment.
// Uses -S to list rules, then -D to delete the exact rule spec.
func removeByComment(cmd string, comment string) {
	// List all rules in PREROUTING chain as rule specs
	out, err := exec.Command(cmd, "-t", "nat", "-S", "PREROUTING").CombinedOutput()
	if err != nil {
		return
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, comment) {
			continue
		}
		// line looks like: -A PREROUTING -p udp --dport 30001:60000 -j DNAT ...
		// Replace -A with -D to build the delete command
		if strings.HasPrefix(line, "-A ") {
			deleteSpec := "-D " + line[3:]
			args := strings.Fields(deleteSpec)
			delCmd := exec.Command(cmd, append([]string{"-t", "nat"}, args...)...)
			if delOut, delErr := delCmd.CombinedOutput(); delErr != nil {
				log.Warnf("[PortMap] 删除规则失败 (%s): %s", cmd, strings.TrimSpace(string(delOut)))
			}
		}
	}
}

// PortRangeRecord records a registered port or port range for conflict detection.
type PortRangeRecord struct {
	Start int
	End   int
	Host  string
	Label string // e.g. "vless/port" or "hysteria/hop_ports"
}

// String returns a human-readable representation of the record.
// Single ports display as [port], ranges display as [start-end].
func (r PortRangeRecord) String() string {
	if r.Start == r.End {
		return fmt.Sprintf("%s [%d] (%s)", r.Label, r.Start, r.Host)
	}
	return fmt.Sprintf("%s [%d-%d] (%s)", r.Label, r.Start, r.End, r.Host)
}

// PortConflictGroup represents a group of records that overlap on the same port/range.
type PortConflictGroup struct {
	Start   int
	End     int
	Records []PortRangeRecord
}

// overlaps checks whether two ranges overlap.
func overlaps(aStart, aEnd, bStart, bEnd int) bool {
	return aStart <= bEnd && aEnd >= bStart
}

// FindAllConflicts collects all port range records, groups overlapping ones,
// and returns only groups with 2+ records (i.e. actual conflicts).
func FindAllConflicts(ranges []PortRangeRecord) []PortConflictGroup {
	// Use union-find style grouping: for each record, find all existing groups it overlaps with
	var groups []PortConflictGroup

	for _, r := range ranges {
		// Find all groups this record overlaps with
		var mergeIndices []int
		for i, g := range groups {
			if overlaps(r.Start, r.End, g.Start, g.End) {
				mergeIndices = append(mergeIndices, i)
			}
		}

		if len(mergeIndices) == 0 {
			// No overlap, create a new group
			groups = append(groups, PortConflictGroup{
				Start:   r.Start,
				End:     r.End,
				Records: []PortRangeRecord{r},
			})
		} else {
			// Merge into the first overlapping group
			target := mergeIndices[0]
			groups[target].Records = append(groups[target].Records, r)
			if r.Start < groups[target].Start {
				groups[target].Start = r.Start
			}
			if r.End > groups[target].End {
				groups[target].End = r.End
			}

			// Merge any additional overlapping groups into the first one
			for i := len(mergeIndices) - 1; i >= 1; i-- {
				idx := mergeIndices[i]
				groups[target].Records = append(groups[target].Records, groups[idx].Records...)
				if groups[idx].Start < groups[target].Start {
					groups[target].Start = groups[idx].Start
				}
				if groups[idx].End > groups[target].End {
					groups[target].End = groups[idx].End
				}
				// Remove merged group
				groups = append(groups[:idx], groups[idx+1:]...)
			}
		}
	}

	// Filter to only groups with actual conflicts (2+ records)
	var conflicts []PortConflictGroup
	for _, g := range groups {
		if len(g.Records) >= 2 {
			conflicts = append(conflicts, g)
		}
	}
	return conflicts
}

// FormatConflicts formats conflict groups into human-readable log lines.
// Single port: "检测到端口 10001 冲突: api.xxx (vless/port), api2.xxx (vless/port, ss/port)"
// Range: "检测到端口范围 30001-60000 冲突: api1 (hysteria/hop_ports 30001-50000), api2 (hysteria/hop_ports 40001-50000)"
func FormatConflicts(conflicts []PortConflictGroup) []string {
	var lines []string
	for _, g := range conflicts {
		// Determine port display
		var portDisplay string
		isGroupRange := g.Start != g.End
		if isGroupRange {
			portDisplay = fmt.Sprintf("端口范围 %d-%d", g.Start, g.End)
		} else {
			portDisplay = fmt.Sprintf("端口 %d", g.Start)
		}

		// Group records by host, preserving order of first appearance
		type hostEntry struct {
			Host   string
			Labels []string
		}
		hostOrder := make([]string, 0)
		hostMap := make(map[string]*hostEntry)
		for _, r := range g.Records {
			if _, exists := hostMap[r.Host]; !exists {
				hostMap[r.Host] = &hostEntry{Host: r.Host}
				hostOrder = append(hostOrder, r.Host)
			}
			// 当组内包含范围时，在 label 后附带各自的实际范围
			label := r.Label
			if r.Start != r.End {
				label = fmt.Sprintf("%s %d-%d", r.Label, r.Start, r.End)
			} else if isGroupRange {
				// 单端口落在范围组里时，也显示具体端口
				label = fmt.Sprintf("%s %d", r.Label, r.Start)
			}
			hostMap[r.Host].Labels = append(hostMap[r.Host].Labels, label)
		}

		// Build output parts
		var parts []string
		for _, host := range hostOrder {
			e := hostMap[host]
			parts = append(parts, fmt.Sprintf("%s (%s)", e.Host, strings.Join(e.Labels, ", ")))
		}

		lines = append(lines, fmt.Sprintf("检测到%s冲突: %s", portDisplay, strings.Join(parts, ", ")))
	}
	return lines
}
