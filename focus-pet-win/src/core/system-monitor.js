// 跨平台系统监控：CPU 用 os.cpus() 两次采样算差值，内存用 totalmem - freemem
const os = require('os');

let lastCpus = null;
let lastCpuTotal = 0;
let lastCpuIdle = 0;

function sample() {
  const cpus = os.cpus();
  let total = 0, idle = 0;
  for (const c of cpus) {
    total += c.times.user + c.times.nice + c.times.sys + c.times.idle + c.times.irq;
    idle += c.times.idle;
  }
  const memUsed = (os.totalmem() - os.freemem()) / 1024 / 1024 / 1024;
  const memTotal = os.totalmem() / 1024 / 1024 / 1024;
  return { cpus, total, idle, memUsed, memTotal };
}

function cpuPercent() {
  const s = sample();
  const prev = lastCpus;
  lastCpus = s;
  if (!prev) { lastCpuTotal = s.total; lastCpuIdle = s.idle; return 0; }
  const totalDelta = s.total - lastCpuTotal;
  const idleDelta = s.idle - lastCpuIdle;
  lastCpuTotal = s.total;
  lastCpuIdle = s.idle;
  if (totalDelta <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((1 - idleDelta / totalDelta) * 100)));
}

function memoryGB() {
  const s = sample();
  return { used: +s.memUsed.toFixed(1), total: +s.memTotal.toFixed(1) };
}

module.exports = { cpuPercent, memoryGB };
