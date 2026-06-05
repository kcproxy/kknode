package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/kcproxy/kknode/api/panel"
	"github.com/kcproxy/kknode/common/portmap"
	"github.com/kcproxy/kknode/conf"
	"github.com/spf13/cobra"
)

var checkCmd = &cobra.Command{
	Use:   "check",
	Short: "检查端口冲突",
	Run: func(cmd *cobra.Command, args []string) {
		configPath, _ := cmd.Flags().GetString("config")
		c := conf.New()
		if err := c.LoadFromPath(configPath); err != nil {
			fmt.Printf("读取配置文件失败: %s\n", err)
			os.Exit(1)
		}

		if c.Nodes == nil || len(c.Nodes) == 0 {
			fmt.Println("未配置任何后端节点")
			return
		}

		// 收集所有端口记录
		var usedRanges []portmap.PortRangeRecord

		for _, apiConf := range c.Nodes {
			apiDir := apiConf.ApiDir()
			nodeConfigPath := filepath.Join(apiDir, "node.json")

			nodeData, err := os.ReadFile(nodeConfigPath)
			if err != nil {
				// 如果文件不存在, 可能是还没启动过, 跳过检测
				continue
			}

			var serverconfig panel.ServerConfigResponse
			if err := json.Unmarshal(nodeData, &serverconfig); err != nil {
				continue
			}

			if serverconfig.Data == nil || serverconfig.Data.Protocols == nil {
				continue
			}

			for _, proto := range *serverconfig.Data.Protocols {
				if !proto.Enable {
					continue
				}

				usedRanges = append(usedRanges, portmap.PortRangeRecord{
					Start: proto.Port,
					End:   proto.Port,
					Host:  apiConf.ApiHost,
					Label: fmt.Sprintf("%s/port", proto.Type),
				})

				if proto.HopPorts != "" {
					start, end, err := portmap.ParseHopPorts(proto.HopPorts)
					if err == nil && start > 0 {
						usedRanges = append(usedRanges, portmap.PortRangeRecord{
							Start: start,
							End:   end,
							Host:  apiConf.ApiHost,
							Label: fmt.Sprintf("%s/hop_ports", proto.Type),
						})
					}
				}
			}
		}

		// 统一检测冲突
		conflicts := portmap.FindAllConflicts(usedRanges)
		if len(conflicts) > 0 {
			for _, line := range portmap.FormatConflicts(conflicts) {
				fmt.Printf("[警告] %s\n", line)
			}
			os.Exit(1)
		}
		fmt.Println("未检测到端口冲突")
	},
}

func init() {
	checkCmd.Flags().StringP("config", "c", "/etc/kknode/config.yml", "config file path")
	command.AddCommand(checkCmd)
}
