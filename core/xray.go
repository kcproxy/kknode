package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/kcproxy/kknode/api/panel"
	"github.com/kcproxy/kknode/common/task"
	"github.com/kcproxy/kknode/conf"
	"github.com/kcproxy/kknode/core/app/dispatcher"
	_ "github.com/kcproxy/kknode/core/distro/all"
	log "github.com/sirupsen/logrus"
	"github.com/xtls/xray-core/app/proxyman"
	"github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/inbound"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/routing"
	coreConf "github.com/xtls/xray-core/infra/conf"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type AddUsersParams struct {
	Tag   string
	Users []panel.UserInfo
	*panel.NodeInfo
}

type XrayCore struct {
	Config                      *conf.Conf
	Client                      *panel.ClientV2
	ApiDir                      string
	ReloadCh                    chan struct{}
	serverConfigMonitorPeriodic *task.Task
	access                      sync.Mutex
	Server                      *core.Instance
	users                       *UserMap
	ihm                         inbound.Manager
	ohm                         outbound.Manager
	dispatcher                  *dispatcher.DefaultDispatcher
}

type UserMap struct {
	uidMap  map[string]int
	mapLock sync.RWMutex
}

func New(config *conf.Conf, client *panel.ClientV2, apiDir string) *XrayCore {
	core := &XrayCore{
		Config: config,
		Client: client,
		ApiDir: apiDir,
		users: &UserMap{
			uidMap: make(map[string]int),
		},
	}
	return core
}

func (v *XrayCore) Start(serverconfig *panel.ServerConfigResponse, apiDir string, localOnly bool) error {
	v.access.Lock()
	defer v.access.Unlock()

	if !localOnly {
		// save node.json (previously panel.json) with cert_dns_env stripped out.
		// 敏感的 DNS 证书凭证(cert_dns_env)不再落盘；本地锁定模式下需要时
		// 从面板按需拉取并合并(见 cmd/server.go)。这里同时清理历史遗留的 sidecar。
		redacted, _ := panel.RedactCertDNSEnv(serverconfig)
		_ = os.Remove(filepath.Join(apiDir, panel.CertEnvFileName))
		if panelJSON, err := json.MarshalIndent(redacted, "", "  "); err == nil {
			_ = os.WriteFile(filepath.Join(apiDir, "node.json"), panelJSON, 0644)
		}

		config := getCoreConfig(v.Config, serverconfig, apiDir)

		// save core.json (previously node.json)
		m := protojson.MarshalOptions{Multiline: true}
		if nodeJSON, err := m.Marshal(config); err == nil {
			_ = os.WriteFile(filepath.Join(apiDir, "core.json"), nodeJSON, 0644)
		}
	}

	// load from file
	fileContent, err := os.ReadFile(filepath.Join(apiDir, "core.json"))
	if err != nil {
		return err
	}
	var fileConfig core.Config
	if err := protojson.Unmarshal(fileContent, &fileConfig); err != nil {
		return err
	}

	server, err := core.New(&fileConfig)
	if err != nil {
		return err
	}
	v.Server = server

	if err := v.Server.Start(); err != nil {
		return err
	}
	v.ihm = v.Server.GetFeature(inbound.ManagerType()).(inbound.Manager)
	v.ohm = v.Server.GetFeature(outbound.ManagerType()).(outbound.Manager)
	v.dispatcher = v.Server.GetFeature(routing.DispatcherType()).(*dispatcher.DefaultDispatcher)
	if !localOnly {
		v.startTasks(serverconfig)
	}
	return nil
}

func (v *XrayCore) Close() error {
	v.access.Lock()
	defer v.access.Unlock()
	if v.serverConfigMonitorPeriodic != nil {
		v.serverConfigMonitorPeriodic.Close()
	}
	v.Config = nil
	v.ihm = nil
	v.ohm = nil
	v.dispatcher = nil
	err := v.Server.Close()
	if err != nil {
		return err
	}
	return nil
}

func getCoreConfig(c *conf.Conf, serverconfig *panel.ServerConfigResponse, apiDir string) *core.Config {
	errorLog := c.LogConfig.Output
	if errorLog == "" {
		errorLog = filepath.Join(apiDir, "error.log")
	}
	accessLog := c.LogConfig.Access
	if accessLog == "none" || accessLog == "" {
		accessLog = filepath.Join(apiDir, "access.log")
	}
	// Log Config
	coreLogConfig := &coreConf.LogConfig{
		LogLevel:  c.LogConfig.Level,
		AccessLog: accessLog,
		ErrorLog:  errorLog,
	}
	// Custom config
	dnsConfig, outBoundConfig, routeConfig, err := GetCustomConfig(serverconfig)
	if err != nil {
		log.WithField("err", err).Panic("failed to build custom config")
	}
	// Inbound config
	var inBoundConfig []*core.InboundHandlerConfig

	// Policy config
	levelPolicyConfig := &coreConf.Policy{
		StatsUserUplink:   true,
		StatsUserDownlink: true,
		Handshake:         proto.Uint32(4),
		ConnectionIdle:    proto.Uint32(30),
		UplinkOnly:        proto.Uint32(2),
		DownlinkOnly:      proto.Uint32(4),
		BufferSize:        proto.Int32(64),
	}
	corePolicyConfig := &coreConf.PolicyConfig{}
	corePolicyConfig.Levels = map[uint32]*coreConf.Policy{0: levelPolicyConfig}
	policyConfig, _ := corePolicyConfig.Build()
	// Build Xray conf
	config := &core.Config{
		App: []*serial.TypedMessage{
			serial.ToTypedMessage(coreLogConfig.Build()),
			serial.ToTypedMessage(&dispatcher.Config{}),
			serial.ToTypedMessage(&stats.Config{}),
			serial.ToTypedMessage(&proxyman.InboundConfig{}),
			serial.ToTypedMessage(&proxyman.OutboundConfig{}),
			serial.ToTypedMessage(policyConfig),
			serial.ToTypedMessage(dnsConfig),
			serial.ToTypedMessage(routeConfig),
		},
		Inbound:  inBoundConfig,
		Outbound: outBoundConfig,
	}
	return config
}

func (c *XrayCore) startTasks(serverconfig *panel.ServerConfigResponse) {
	// fetch node info task
	pullinverval := serverconfig.Data.PullInterval
	if pullinverval <= 0 {
		pullinverval = 60
	}
	c.serverConfigMonitorPeriodic = &task.Task{
		Interval: time.Duration(pullinverval) * time.Second,
		Execute:  c.ServerConfigMonitor,
		ReloadCh: c.ReloadCh,
	}
	_ = c.serverConfigMonitorPeriodic.Start(false)
}

func (c *XrayCore) ServerConfigMonitor(ctx context.Context) (err error) {
	newServerConfig, err := panel.GetServerConfig(ctx, c.Client)
	if err != nil {
		log.WithField("err", err).Error("获取服务端配置失败")
		return nil
	}
	if newServerConfig != nil {
		log.Error("检测到服务端配置变更，正在重启节点...")
		// Non-blocking signal to avoid goroutine stuck when channel is full or nil
		if c.ReloadCh != nil {
			select {
			case c.ReloadCh <- struct{}{}:
			default:
			}
		}
	}
	return nil
}
