package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	_ "net/http/pprof"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"

	"github.com/kcproxy/kknode/api/panel"
	"github.com/kcproxy/kknode/common/portmap"
	"github.com/kcproxy/kknode/conf"
	"github.com/kcproxy/kknode/core"
	"github.com/kcproxy/kknode/limiter"
	"github.com/kcproxy/kknode/node"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

var (
	config string
	watch  bool
)

var serverCommand = cobra.Command{
	Use:   "server",
	Short: "Run kknode server",
	Run:   serverHandle,
	Args:  cobra.NoArgs,
}

func init() {
	serverCommand.PersistentFlags().
		StringVarP(&config, "config", "c",
			"/etc/kknode/config.yml", "config file path")
	serverCommand.PersistentFlags().
		BoolVarP(&watch, "watch", "w",
			true, "watch file path change")
	command.AddCommand(&serverCommand)
}

type Backend struct {
	Config   conf.ServerApiConfig
	XrayCore *core.XrayCore
	Nodes    *node.Node
	ApiDir   string
	HopRules []*portmap.HopPortRange // iptables DNAT rules created for Hysteria2 port hopping
}

func serverHandle(_ *cobra.Command, _ []string) {
	showVersion()
	c := conf.New()
	err := c.LoadFromPath(config)
	log.SetFormatter(&log.TextFormatter{
		DisableTimestamp: true,
		DisableQuote:     true,
		PadLevelText:     false,
	})
	if err != nil {
		log.WithField("err", err).Error("读取配置文件失败")
		return
	}
	switch c.LogConfig.Level {
	case "debug":
		log.SetLevel(log.DebugLevel)
	case "info":
		log.SetLevel(log.InfoLevel)
	case "warn", "warning":
		log.SetLevel(log.WarnLevel)
	case "error":
		log.SetLevel(log.ErrorLevel)
	}
	if c.LogConfig.Output != "" {
		f, err := os.OpenFile(c.LogConfig.Output, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			log.WithField("err", err).Error("打开日志文件失败，使用stdout替代")
		}
		log.SetOutput(f)
	}
	// Enable pprof if configured
	if c.PprofPort != 0 {
		go func() {
			log.Infof("Starting pprof server on :%d", c.PprofPort)
			if err := http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", c.PprofPort), nil); err != nil {
				log.WithField("err", err).Error("pprof server failed")
			}
		}()
	}
	limiter.Init()

	var reloadCh = make(chan struct{}, 1)
	backends := startBackends(c, reloadCh)

	if watch {
		// On file change, just signal reload; do not run reload concurrently here
		err = c.Watch(config, func() {
			select {
			case reloadCh <- struct{}{}:
			default: // drop if a reload is already queued
			}
		})
		if err != nil {
			log.WithField("err", err).Error("start watch failed")
			return
		}
	}
	// clear memory
	runtime.GC()

	osSignals := make(chan os.Signal, 1)
	signal.Notify(osSignals, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case <-osSignals:
			for _, b := range backends {
				portmap.RemoveAllHopPorts(b.HopRules)
				b.Nodes.Close()
				_ = b.XrayCore.Close()
			}
			return
		case <-reloadCh:
			log.Info("收到重启信号，正在重新加载配置...")
			if err := reload(config, &backends, reloadCh); err != nil {
				log.WithField("err", err).Error("重启失败")
			}
		}
	}
}

func startBackends(c *conf.Conf, reloadCh chan struct{}) []*Backend {
	var backends []*Backend
	var usedRanges []portmap.PortRangeRecord // unified port range conflict detection

	for _, apiConf := range c.Nodes {
		var err error
		if _, err = url.Parse(apiConf.ApiHost); err != nil {
			log.WithField("err", err).Errorf("解析ApiHost失败: %s", apiConf.ApiHost)
			continue
		}

		apiDir := apiConf.ApiDir()
		if err := os.MkdirAll(apiDir, 0755); err != nil {
			log.WithField("err", err).Errorf("创建目录失败: %s", apiDir)
			continue
		}

		p := panel.NewClientV2(&apiConf)
		var serverconfig *panel.ServerConfigResponse
		var err_c error

		// 判断是否需要读取本地旧配置（开启了本地锁定且文件存在）
		_, err1 := os.Stat(filepath.Join(apiDir, "node.json"))
		_, err2 := os.Stat(filepath.Join(apiDir, "core.json"))
		hasLocalFiles := err1 == nil && err2 == nil

		if !apiConf.LocalConfig || !hasLocalFiles {
			serverconfig, err_c = panel.GetServerConfig(context.Background(), p)
			if err_c != nil {
				log.WithField("err", err_c).Errorf("获取服务端配置失败: %s", apiConf.ApiHost)
				continue
			}
			if serverconfig == nil || serverconfig.Data == nil || serverconfig.Data.Protocols == nil {
				continue
			}
		} else {
			nodeData, err := os.ReadFile(filepath.Join(apiDir, "node.json"))
			if err != nil {
				log.WithField("err", err).Errorf("读取本地 node.json 失败: %s", apiConf.ApiHost)
				continue
			}
			err = json.Unmarshal(nodeData, &serverconfig)
			if err != nil {
				log.Errorf("解析本地 node.json 失败 (%s): %s", apiDir, err)
				continue
			}
			if serverconfig == nil || serverconfig.Data == nil || serverconfig.Data.Protocols == nil {
				log.Errorf("本地 node.json 格式错误或缺少协议信息 (%s)", apiDir)
				continue
			}
		}

		xraycore := core.New(c, p, apiDir)
		xraycore.ReloadCh = reloadCh
		isLocal := apiConf.LocalConfig && hasLocalFiles

		// 收集端口信息用于冲突检测（不在此处输出日志）
		for _, proto := range *serverconfig.Data.Protocols {
			if !proto.Enable {
				continue
			}
			usedRanges = append(usedRanges, portmap.PortRangeRecord{
				Start: proto.Port, End: proto.Port, Host: apiConf.ApiHost, Label: fmt.Sprintf("%s/port", proto.Type),
			})
			if proto.HopPorts != "" {
				hopStart, hopEnd, parseErr := portmap.ParseHopPorts(proto.HopPorts)
				if parseErr != nil {
					log.WithField("err", parseErr).Errorf("解析 hop_ports 失败: %s", apiConf.ApiHost)
				} else if hopStart > 0 {
					usedRanges = append(usedRanges, portmap.PortRangeRecord{
						Start: hopStart, End: hopEnd, Host: apiConf.ApiHost, Label: fmt.Sprintf("%s/hop_ports", proto.Type),
					})
				}
			}
		}

		err = xraycore.Start(serverconfig, apiDir, isLocal)
		if err != nil {
			log.WithField("err", err).Errorf("启动Xray核心失败: %s", apiConf.ApiHost)
			continue
		}

		apiConfCopy := apiConf // prevent pointer capture in loop
		nodes, err := node.New(xraycore, &apiConfCopy, serverconfig, apiDir)
		if err != nil {
			log.WithField("err", err).Errorf("获取节点配置失败: %s", apiConf.ApiHost)
			xraycore.Close()
			continue
		}
		err = nodes.Start()
		if err != nil {
			log.WithField("err", err).Errorf("启动节点失败: %s", apiConf.ApiHost)
			xraycore.Close()
			continue
		}

		// Apply Hysteria2 hop_ports DNAT rules
		var hopRules []*portmap.HopPortRange
		for _, proto := range *serverconfig.Data.Protocols {
			if !proto.Enable || proto.HopPorts == "" {
				continue
			}
			if proto.Type == "hysteria" || proto.Type == "hysteria2" {
				rule, hopErr := portmap.ApplyHopPorts(proto.Port, proto.HopPorts)
				if hopErr != nil {
					log.WithField("err", hopErr).Errorf("[PortMap] 应用端口映射失败: %s port=%d hop=%s", apiConf.ApiHost, proto.Port, proto.HopPorts)
				} else if rule != nil {
					hopRules = append(hopRules, rule)
				}
			}
		}

		log.Infof("API %s 已启动 %d 个节点", apiConf.ApiHost, serverconfig.Data.Total)
		backends = append(backends, &Backend{
			Config:   apiConfCopy,
			XrayCore: xraycore,
			Nodes:    nodes,
			ApiDir:   apiDir,
			HopRules: hopRules,
		})
	}

	// 统一检测并输出端口冲突
	conflicts := portmap.FindAllConflicts(usedRanges)
	for _, line := range portmap.FormatConflicts(conflicts) {
		log.Warnf("[警告] %s", line)
	}

	return backends
}

func reload(configFile string, backends *[]*Backend, reloadCh chan struct{}) error {
	for _, b := range *backends {
		portmap.RemoveAllHopPorts(b.HopRules)
		b.Nodes.Close()
		if err := b.XrayCore.Close(); err != nil {
			log.WithField("err", err).Error("关闭Xray核心失败")
		}
	}
	*backends = nil

	newConf := conf.New()
	if err := newConf.LoadFromPath(configFile); err != nil {
		return err
	}

	*backends = startBackends(newConf, reloadCh)
	log.Infof("全部节点重启成功，当前运行 %d 个后端", len(*backends))
	runtime.GC()
	return nil
}
