const { app, BrowserWindow, Tray, Menu, ipcMain, screen, shell } = require('electron');
const path = require('path');
const Store = require('electron-store');
const store = new Store({ name: 'focus-pet-state' });

let mainWindow = null;
let tray = null;

const W = 210;
const H = 380;
const GAP_BOTTOM = 20;

function createWindow() {
  const display = screen.getPrimaryDisplay();
  const { width, height } = display.workAreaSize;
  let saved = store.get('windowOrigin');
  let x, y;
  if (Array.isArray(saved) && saved.length === 2) {
    x = saved[0]; y = saved[1];
  } else {
    x = width - W - GAP_BOTTOM;
    y = height - H - GAP_BOTTOM;
  }

  mainWindow = new BrowserWindow({
    x, y, width: W, height: H,
    frame: false,
    transparent: true,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    movable: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  mainWindow.setAlwaysOnTop(true, 'screen-saver');
  mainWindow.setIgnoreMouseEvents(false, { forward: true });

  mainWindow.loadFile(path.join(__dirname, '../src/renderer/index.html'));
  mainWindow.once('ready-to-show', () => mainWindow.show());

  let dragging = false, offset = null;
  mainWindow.on('movable-by-window-background', () => { /* no-op */ });

  // 拖拽：renderer 发事件来切换鼠标事件忽略
  ipcMain.handle('drag:start', (e, { mx, my }) => {
    dragging = true;
    const [wx, wy] = mainWindow.getPosition();
    offset = { x: mx - wx, y: my - wy };
  });
  ipcMain.handle('drag:move', (e, { mx, my }) => {
    if (!dragging || !offset) return;
    const nx = mx - offset.x;
    const ny = my - offset.y;
    mainWindow.setPosition(nx, ny);
  });
  ipcMain.handle('drag:end', () => {
    if (dragging) {
      const [x, y] = mainWindow.getPosition();
      store.set('windowOrigin', [x, y]);
    }
    dragging = false;
    offset = null;
  });
}

function buildMenu() {
  const menu = Menu.buildFromTemplate([
    { label: '专注中 · 00:00', enabled: false, id: 'status' },
    { type: 'separator' },
    { label: '开始专注', click: () => mainWindow.webContents.send('action:toggleSession') },
    { label: '重置计时', click: () => mainWindow.webContents.send('action:resetSession') },
    { label: '喂饭团', click: () => mainWindow.webContents.send('action:feed') },
    { label: '饭团图鉴', click: () => mainWindow.webContents.send('action:showRecipe') },
    { type: 'separator' },
    { label: '跑步面板…', click: () => mainWindow.webContents.send('action:openRunning') },
    { label: '心情打卡', submenu: [
      { label: '🤩 开心', click: () => mainWindow.webContents.send('action:mood', 'happy') },
      { label: '🙂 平静', click: () => mainWindow.webContents.send('action:mood', 'calm') },
      { label: '😴 疲惫', click: () => mainWindow.webContents.send('action:mood', 'tired') },
      { label: '😣 烦躁', click: () => mainWindow.webContents.send('action:mood', 'annoyed') },
    ]},
    { type: 'separator' },
    { label: '开机自启', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => { app.setLoginItemSettings({ openAtLogin: item.checked }); },
    { label: '退出', click: () => { app.isQuiting = true; app.quit(); } },
  ]);
  return menu;
}

function createTray() {
  const iconPath = path.join(__dirname, '../assets/tray.png');
  try { tray = new Tray(iconPath); } catch {
    tray = new Tray(path.join(__dirname, '../assets/'); // fallback: 必须存在，否则报错
  }
  tray.setToolTip('麻薯');
  tray.setContextMenu(buildMenu());
  // 定时刷新状态行
  setInterval(() => {
    if (!tray) return;
    const menu = buildMenu();
    const state = store.get('state') || {};
    const running = state.sessionRunning;
    const remaining = state.sessionRemaining;
    const mm = Math.floor(remaining / 60);
    const ss = remaining % 60;
    const status = menu.items.find(i => i.id === 'status');
    if (status) status.label = `${running ? '专注中' : '休息中'} · ${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
    tray.setContextMenu(menu);
  }, 5000);
}

app.whenReady().then(() => {
  createWindow();
  createTray();
});

app.on('window-all-closed', (e) => {
  // 托盘模式不退出
  e.preventDefault();
});

app.on('before-quit', () => {
  try { store.set('state', mainWindow?.webContents ? null : null); } catch {}
});

// renderer 请求打开/隐藏
ipcMain.handle('window:hide', () => mainWindow.hide());
ipcMain.handle('window:show', () => mainWindow.show());
ipcMain.handle('state:get', () => store.get('state'));
ipcMain.handle('state:set', (e, v) => { store.set('state', v); });
ipcMain.handle('coros:tokens', () => store.get('corosTokens'));
ipcMain.handle('coros:setTokens', (e, v) => store.set('corosTokens', v));
ipcMain.handle('open-external', (e, url) => shell.openExternal(url));
