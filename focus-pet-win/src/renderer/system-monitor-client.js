// 客户端系统监控：通过 preload 暴露的 window.petAPI.system
export const systemMonitor = {
  cpuPercent: () => { try { return window.petAPI?.system?.cpuPercent?.() ?? 0; } catch { return 0; } },
  memory: () => { try { return window.petAPI?.system?.memory?.() ?? {used:0,total:1}; } catch { return {used:0,total:1}; } },
  cores: () => { try { return window.petAPI?.system?.cores?.() ?? 4; } catch { return 4; } },
};
