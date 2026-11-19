// 跨平台 PetBrain：专注状态机、饭团盲盒、XP、心情打卡、本地持久化
const DAY_FMT = new Intl.DateTimeFormat('en-CA', { year:'numeric', month:'2-digit', day:'2-digit' });

const FLAVORS = [
  { key:'seaweed', name:'海苔',    emoji:'🍙', weight:30 },
  { key:'redbean', name:'红豆',    emoji:'🫘', weight:25 },
  { key:'matcha',  name:'抹茶',    emoji:'🍵', weight:20 },
  { key:'sesame',  name:'芝麻',    emoji:'🌰', weight:15 },
  { key:'pudding', name:'焦糖布丁', emoji:'🍮', weight:8 },
];

function rollFlavor() {
  const total = FLAVORS.reduce((s,f)=>s+f.weight,0);
  let roll = Math.floor(Math.random()*total);
  for (const f of FLAVORS) { if ((roll -= f.weight) < 0) return f; }
  return FLAVORS[0];
}

function todayKey() { return DAY_FMT.format(new Date()); }

class PetBrain {
  constructor() {
    this.listeners = new Set();
    this.load();
    this.lastGreeted = this.state.lastGreetedKey;
    setInterval(() => this.tick(), 1000);
  }
  subscribe(fn) { this.listeners.add(fn); fn(this.state); return () => this.listeners.delete(fn); }
  emit() { this.listeners.forEach(fn => fn(this.state)); }

  load() {
    const raw = window.petAPI?.getState();
    if (raw) { this.state = { ...this.defaults(), ...raw }; }
    else { this.state = this.defaults(); }
  }
  save(force=false) {
    if (!force && Date.now() - (this.state._lastSave||0) < 5000) return;
    this.state._lastSave = Date.now();
    window.petAPI?.setState(this.state);
  }
  defaults() {
    return {
      xp: 0, level: 1, stage: 0,
      hunger: 80, rice: 0,
      flavors: {}, streakDays: 0, lastActiveDay: null,
      sessionRunning: false, sessionRemaining: 1500, sessionTotal: 1500,
      totalFocusMinutes: 0,
      moods: {}, // { 'YYYY-MM-DD': 'happy'|... }
      _lastSave: 0, lastGreetedKey: null,
    };
  }

  tick() {
    if (!this.state.sessionRunning) { this.state.hunger = Math.max(0, this.state.hunger - 10/3600); }
    else {
      this.state.sessionRemaining -= 1;
      this.state.xp += 1/60;
      this.state.hunger = Math.max(0, this.state.hunger - 20/3600);
      if (this.state.sessionRemaining <= 0) this.completeSession();
    }
    this.state.level = Math.floor(1 + this.state.xp / 10);
    this.state.stage = Math.min(4, this.state.level - 1);
    this.save();
    this.emit();
  }

  completeSession() {
    const flavor = rollFlavor();
    this.state.xp += 5;
    this.state.rice += 1;
    this.state.totalFocusMinutes += this.state.sessionTotal / 60;
    const dict = this.state.flavors || {};
    dict[flavor.key] = (dict[flavor.key]||0) + 1;
    this.state.flavors = dict;
    this.state.sessionRemaining = this.state.sessionTotal;
    this.state.sessionRunning = false;
    // streak
    const today = todayKey();
    if (this.state.lastActiveDay !== today) {
      if (this.state.lastActiveDay) {
        const y = new Date(Date.now()-86400000);
        const yk = DAY_FMT.format(y);
        this.state.streakDays = (this.state.lastActiveDay === yk) ? this.state.streakDays+1 : 1;
      } else { this.state.streakDays = 1; }
      this.state.lastActiveDay = today;
    }
    this.save(true);
  }

  toggleSession() {
    this.state.sessionRunning = !this.state.sessionRunning;
    if (!this.state.sessionRunning && this.state.sessionRemaining <= 0) this.state.sessionRemaining = this.state.sessionTotal;
    this.save(true); this.emit();
  }
  resetSession() {
    this.state.sessionRunning = false;
    this.state.sessionRemaining = this.state.sessionTotal;
    this.save(true); this.emit();
  }
  feed() {
    if (this.state.rice <= 0 || this.state.hunger >= 99) return;
    const dict = { ...this.state.flavors };
    let topKey = null, topCount = -1;
    for (const [k,v] of Object.entries(dict)) if (v>topCount) { topCount=v; topKey=k; }
    if (topKey) dict[topKey] = Math.max(0, dict[topKey]-1);
    this.state.flavors = dict;
    this.state.rice -= 1;
    this.state.hunger = Math.min(100, this.state.hunger + 25);
    this.save(true); this.emit();
  }
  mood(kind) {
    const key = todayKey();
    this.state.moods = { ...this.state.moods, [key]: kind };
    this.save(true); this.emit();
  }
}

module.exports = { PetBrain, FLAVORS };
