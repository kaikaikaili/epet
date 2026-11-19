// App 主入口：宠物 Canvas + DOM 气泡 + HUD + 均衡器
import { PetBrain, FLAVORS } from '../core/pet-brain.js';
import ChatClient from '../core/chat-client.js';
import { systemMonitor } from './system-monitor-client.js';

const brain = new PetBrain();
const chat = new ChatClient();

// ==== DOM ====
const root = document.getElementById('root');
root.innerHTML = `
  <div id="wrap" class="drag" style="width:210px;height:380px;position:relative;overflow:visible">
    <!-- 聊天气泡区 -->
    <div id="chatArea" class="no-drag" style="position:absolute;top:0;left:0;right:0;height:150px;pointer-events:none;display:flex;flex-direction:column-reverse;align-items:center;gap:4px;padding:6px 4px"></div>
    <!-- 宠物 Canvas -->
    <canvas id="pet" class="drag" style="position:absolute;top:145px;left:20px;width:170px;height:170px;pointer-events:none"></canvas>
    <!-- HUD -->
    <div id="hud" class="no-drag" style="position:absolute;bottom:0;left:0;right:0;height:64px;padding:6px 10px;display:flex;flex-direction:column;gap:3px;color:white;font-size:11px">
      <div id="hudTop" style="display:flex;justify-content:space-between">
        <span id="sessionTime">休息中 · 00:00</span>
        <span id="stageName">糯米粉一团</span>
      </div>
      <div style="height:4px;background:rgba(255,255,255,0.2);border-radius:2px;overflow:hidden">
        <div id="stageBar" style="height:100%;width:0%;background:#a8f0c6;border-radius:2px;transition:width 0.5s"></div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center">
        <span>🍙 <span id="riceCount">0</span></span>
        <div id="playBtn" class="no-drag" style="padding:2px 8px;background:rgba(168,240,198,0.9);color:#0f2a1f;border-radius:6px;cursor:pointer;font-size:11px">▶</div>
      </div>
    </div>
    <!-- 侧边均衡器 -->
    <div id="eqBox" class="no-drag" style="position:absolute;left:4px;top:200px;display:flex;flex-direction:column;gap:1px;align-items:center;opacity:0.95">
      <div style="display:flex;align-items:flex-end;gap:2px;height:16px">
        <div id="eq0" style="width:3.5px;background:#7ee8a5;border-radius:1px;transition:height 0.55s ease-out;height:2px"></div>
        <div id="eq1" style="width:3.5px;background:#7ee8a5;border-radius:1px;transition:height 0.55s ease-out;height:2px"></div>
        <div id="eq2" style="width:3.5px;background:#7ee8a5;border-radius:1px;transition:height 0.55s ease-out;height:2px"></div>
      </div>
      <div style="font-family:monospace;font-size:9px;font-weight:700;color:#7ee8a5;text-align:center;line-height:1.1">C<span id="cpuPct">0</span>%</div>
      <div style="font-family:monospace;font-size:9px;font-weight:700;color:#7ee8a5;text-align:center;line-height:1.1">M<span id="memPct">0</span>%</div>
    </div>
    <!-- 悬浮输入框 -->
    <div id="chatInputWrap" class="no-drag" style="position:absolute;top:130px;left:10px;right:10px;display:none;gap:4px;align-items:center">
      <input id="chatInput" type="text" placeholder="和麻薯说话…" style="flex:1;height:26px;padding:0 10px;border:none;border-radius:13px;background:rgba(20,30,25,0.72);color:white;font-size:12px;outline:none;backdrop-filter:blur(6px);box-shadow:0 2px 8px rgba(0,0,0,0.2)"/>
      <button id="chatSend" style="width:26px;height:26px;border:none;border-radius:13px;background:#7ee8a5;color:#0f2a1f;cursor:pointer;font-size:13px">↑</button>
    </div>
  </div>
`;

const chatArea = document.getElementById('chatArea');
const chatInputWrap = document.getElementById('chatInputWrap');
const chatInput = document.getElementById('chatInput');
const chatSend = document.getElementById('chatSend');

// ==== Canvas 宠物 ====
const canvas = document.getElementById('pet');
const ctx = canvas.getContext('2d');
let breathe = 0, blink = 0, blinking = false, near = false, look = {x:0, y:0}, sleep = false, sweat = 0;

function drawPet(s) {
  const W = 170, H = 170;
  const t = Date.now() / 1000;
  // 呼吸：2.4s 循环
  const breathScale = 1 + Math.sin(t * 2*Math.PI/2.4) * 0.015;
  // 眨眼
  if (!blinking && Math.random() < 0.003) { blinking=true; setTimeout(()=>blinking=false, 150); }

  // 阴影
  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.16)';
  ctx.beginPath(); ctx.ellipse(W/2, 155, 58, 6, 0, 0, Math.PI*2); ctx.fill();
  ctx.restore();

  // 身体
  const bw = 100 + s.stage * 7, bh = 99 + s.stage * 6;
  const x0 = (W - bw)/2, y0 = (H - bh)/2;
  let bodyColor;
  if (s.hunger < 22) bodyColor = [158, 209, 183];
  else if (s.sessionRunning) bodyColor = [97, 230, 181];
  else bodyColor = [120, 218, 176];

  ctx.save();
  ctx.translate(W/2, H/2);
  ctx.scale(breathScale, breathScale*1.02);
  ctx.translate(-W/2, -H/2);

  roundRect(x0, y0, bw, bh, bw*0.47);
  ctx.fillStyle = `rgb(${bodyColor.join(',')})`;
  ctx.fill();

  // 馅（stage >= 3）
  if (s.stage >= 3) {
    ctx.save();
    ctx.fillStyle = 'rgba(184,91,82,0.55)';
    ctx.beginPath(); ctx.ellipse(W/2, y0+bh*0.80, bw*0.41, bh*0.24, 0, 0, Math.PI*2); ctx.fill();
    ctx.restore();
  }

  // 眼睛：跟随鼠标
  const eyeY = y0 + bh*0.35;
  const eyeOffX = look.x * 3.5, eyeOffY = -bh*0.09 - look.y*3;
  ctx.fillStyle = '#1a332a';
  if (sleep) {
    // 睡着：细横条
    ctx.fillRect(W/2 - 20, eyeY, 12, 2.5);
    ctx.fillRect(W/2 + 8, eyeY, 12, 2.5);
  } else {
    roundRect(W/2 - 20 + eyeOffX, eyeY + eyeOffY, 12, 16, 6);
    roundRect(W/2 + 8 + eyeOffX, eyeY + eyeOffY, 12, 16, 6);
    ctx.fill();
    // 高光
    ctx.fillStyle = 'rgba(255,255,255,0.9)';
    ctx.beginPath();
    ctx.arc(W/2 - 14 + eyeOffX + look.x*1.8, eyeY+eyeOffY-4 + look.y*1.8, 1.75, 0, Math.PI*2); ctx.fill();
    ctx.beginPath();
    ctx.arc(W/2 + 14 + eyeOffX + look.x*1.8, eyeY+eyeOffY-4 + look.y*1.8, 1.75, 0, Math.PI*2); ctx.fill();
    // 眨眼
    if (blinking) {
      ctx.fillStyle = `rgb(${bodyColor.join(',')})`;
      ctx.fillRect(W/2 - 22, eyeY+6+eyeOffY, 44, 8);
    }
  }

  // 腮红
  ctx.fillStyle = 'rgba(255,170,160,0.5)';
  ctx.beginPath();
  ctx.ellipse(W/2 - 28, y0+bh*0.55, 7, 3.5, 0, 0, Math.PI*2); ctx.fill();
  ctx.ellipse(W/2 + 28, y0+bh*0.55, 7, 3.5, 0, 0, Math.PI*2); ctx.fill();

  // 嘴
  ctx.strokeStyle = '#1a332a';
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(W/2 - 4, y0+bh*0.68);
  ctx.quadraticCurveTo(W/2, y0+bh*0.72, W/2 + 4, y0+bh*0.68);
  ctx.stroke();

  // 草莓（stage 4）
  if (s.stage >= 4) {
    ctx.fillStyle = '#e85848';
    ctx.beginPath();
    ctx.moveTo(W/2 - 6, y0-10);
    ctx.quadraticCurveTo(W/2, y0-22, W/2+6, y0-10);
    ctx.quadraticCurveTo(W/2, y0-4, W/2-6, y0-10);
    ctx.fill();
  }
  // 芽（stage >= 1）
  if (s.stage >= 1) {
    ctx.fillStyle = '#5bbf7a';
    ctx.beginPath();
    ctx.moveTo(W/2, y0-10);
    ctx.quadraticCurveTo(W/2-5, y0-20, W/2-9, y0-15);
    ctx.quadraticCurveTo(W/2-3, y0-14, W/2, y0-10);
    ctx.fill();
  }

  ctx.restore();

  // 冒汗珠
  if (sweat > 0) {
    ctx.fillStyle = 'rgba(120,180,255,0.85)';
    ctx.beginPath();
    ctx.moveTo(W/2 + bw/2 + 5, y0);
    ctx.quadraticCurveTo(W/2 + bw/2 + 10, y0-5, W/2 + bw/2 + 10, y0+2);
    ctx.quadraticCurveTo(W/2 + bw/2 + 12, y0+8, W/2 + bw/2 + 5, y0+4);
    ctx.fill();
  }
}

function roundRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x+r, y);
  ctx.arcTo(x+w, y, x+w, y+h, r);
  ctx.arcTo(x+w, y+h, x, y+h, r);
  ctx.arcTo(x, y+h, x, y, r);
  ctx.arcTo(x, y, x+w, y, r);
  ctx.closePath();
}

function render() {
  const s = brain.state;
  ctx.clearRect(0,0,170,170);
  drawPet(s);

  // HUD
  const mm = Math.floor(s.sessionRemaining/60), ss = s.sessionRemaining%60;
  document.getElementById('sessionTime').textContent = `${s.sessionRunning ? '专注中' : '休息中'} · ${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
  const stageNames = ['小种子','发芽','圆团','软糯','带馅成品'];
  document.getElementById('stageName').textContent = stageNames[s.stage] || '糯米粉一团';
  document.getElementById('stageBar').style.width = `${(s.xp % 10 / 10) * 100}%`;
  document.getElementById('riceCount').textContent = s.rice;
  document.getElementById('playBtn').textContent = s.sessionRunning ? '⏸' : '▶';

  // CPU/内存
  const cpu = systemMonitor.cpuPercent();
  const mem = systemMonitor.memory();
  const memPct = Math.round(mem.used / mem.total * 100);
  document.getElementById('cpuPct').textContent = cpu;
  document.getElementById('memPct').textContent = memPct;
  const levelColor = cpu >= 80 ? '#ff6b6b' : cpu >= 50 ? '#ffa94d' : cpu >= 25 ? '#ffd43b' : '#7ee8a5';
  ['eq0','eq1','eq2'].forEach((id,i) => {
    const el = document.getElementById(id);
    const h = Math.max(2, Math.min(14, (cpu/100 + i*0.04) * 14));
    el.style.height = h + 'px';
    el.style.background = levelColor;
  });
  document.getElementById('eqBox').style.color = levelColor;
  // load level → sweat
  sweat = cpu >= 50 ? 1 : 0;
}

// ==== 气泡 ====
function addBubble(text, side='me', duration=5000) {
  const div = document.createElement('div');
  div.textContent = text;
  div.style.cssText = `max-width:180px;padding:4px 10px;border-radius:12px;font-size:11px;color:white;
    background:${side==='me'?'rgba(126,232,165,0.85)':'rgba(40,55,48,0.88)'};
    align-self:${side==='me'?'flex-end':'flex-start'};
    box-shadow:0 2px 6px rgba(0,0,0,0.2);margin-top:4px;animation:bubbleIn 0.25s ease-out`;
  chatArea.appendChild(div);
  setTimeout(() => {
    div.style.transition = 'opacity 1.2s, transform 1.2s';
    div.style.opacity = '0';
    div.style.transform = 'translateY(-12px)';
    setTimeout(() => div.remove(), 1200);
  }, duration);
  // 只留 6 条
  while (chatArea.children.length > 6) chatArea.removeChild(chatArea.lastChild);
}

// ==== 鼠标靠近 → 输入框 ====
document.addEventListener('mousemove', (e) => {
  const winW = window.innerWidth, winH = window.innerHeight;
  const cx = winW/2, cy = winH * 0.45;
  const dx = e.screenX - (window.screenX + cx);
  const dy = e.screenY - (window.screenY + cy);
  const dist = Math.sqrt(dx*dx + dy*dy);
  near = dist < 165;
  look.x = Math.max(-1, Math.min(1, dx/110));
  look.y = Math.max(-1, Math.min(1, dy/110));
  chatInputWrap.style.display = near ? 'flex' : 'none';
  if (near) chatInput.focus();
});

// ==== 拖拽：整个窗口可拖，只有 hud / 气泡区放行点击 ====
let dragging = false, dragOffset = null;
document.addEventListener('mousedown', (e) => {
  if (e.target.closest('.no-drag')) return;
  dragging = true;
  const rect = document.getElementById('wrap').getBoundingClientRect();
  dragOffset = { x: e.screenX - window.screenX, y: e.screenY - window.screenY };
  window.petAPI.dragStart(e.screenX, e.screenY);
});
document.addEventListener('mousemove', (e) => {
  if (dragging) window.petAPI.dragMove(e.screenX, e.screenY);
});
document.addEventListener('mouseup', () => { dragging=false; window.petAPI.dragEnd(); });

// ==== 聊天 ====
chatSend.onclick = sendChat;
chatInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') sendChat(); });
async function sendChat() {
  const text = chatInput.value.trim();
  if (!text) return;
  addBubble(text, 'me');
  chatInput.value = '';
  try {
    const sys = `你是一只叫麻薯的桌面宠物。性格温柔、不抬杠、简洁，回答控制在30字内。当前状态：${JSON.stringify(brain.state)}`;
    const history = JSON.parse(localStorage.getItem('chatHistory') || '[]');
    history.push({role:'user', content:text});
    const reply = await chat.chat([{role:'system', content:sys}, ...history.slice(-7)]);
    addBubble(reply, 'pet');
    history.push({role:'assistant', content:reply});
    localStorage.setItem('chatHistory', JSON.stringify(history.slice(-14)));
  } catch (err) {
    addBubble('麻薯还没醒：' + err.message.slice(0,30), 'pet');
  }
}

// ==== 主循环 ====
setInterval(render, 1000);
render();

// ==== 菜单动作回调 ====
window.petAPI.onAction((type, payload) => {
  switch(type) {
    case 'toggleSession': brain.toggleSession(); break;
    case 'resetSession': brain.resetSession(); break;
    case 'feed': brain.feed(); addBubble('唔……好香', 'pet', 3000); break;
    case 'mood': brain.mood(payload); break;
  }
});

// play 按钮
document.getElementById('playBtn').onclick = () => brain.toggleSession();
