// 系统监控（preload 里从 main 进程转发，或直接在 preload 里 require('os')）
const os = require('os');

let lastCpus = null;
function cpuPercent() {
  const cpus = os.cpus();
  let total=0, idle=0;
  for (const c of cpus) {
    total += c.times.user + c.times.nice + c.times.sys + c.times.idle + c.times.irq;
    idle += c.times.idle;
  }
  if (lastCpus) {
    const [t2,i2] = lastCpus;
    const dT = total - t2, dI = idle - i2;
    lastCpus = [total, idle];
    if (dT <= 0) return 0;
    return Math.max(0, Math.min(100, Math.round((1 - dI/dT)*100)));
  }
  lastCpus = [total, idle];
  return 0;
}
function memory() {
  return { used: +((os.totalmem()-os.freemem())/1024/1024/1024).toFixed(1),
           total: +(os.totalmem()/1024/1024/1024).toFixed(1) };
}

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('petAPI', {
  dragStart: (mx, my) => ipcRenderer.invoke('drag:start', { mx, my }),
  dragMove: (mx, my) => ipcRenderer.invoke('drag:move', { mx, my }),
  dragEnd: () => ipcRenderer.invoke('drag:end'),
  getState: () => ipcRenderer.invoke('state:get'),
  setState: (v) => ipcRenderer.invoke('state:set', v),
  getCorosTokens: () => ipcRenderer.invoke('coros:tokens'),
  setCorosTokens: (v) => ipcRenderer.invoke('coros:setTokens', v),
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  system: { cpuPercent, memory, cores: () => os.cpus().length },
  onAction: (cb) => {
    ['toggleSession','resetSession','feed','showRecipe','openRunning'].forEach(type => {
      ipcRenderer.on('action:'+type, () => cb(type));
    });
    ipcRenderer.on('action:mood', (e, kind) => cb('mood', kind));
  },
});
