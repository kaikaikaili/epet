// Ollama / OpenAI 兼容聊天客户端，走标准 /v1/chat/completions
class ChatClient {
  constructor() {
    const saved = JSON.parse(localStorage.getItem('chatSettings') || '{}');
    this.base = saved.base || 'http://127.0.0.1:11434/v1';
    this.key  = saved.key  || '';
    this.model= saved.model || 'qwen2.5:0.5b';
  }
  saveSettings({ base, key, model }) {
    if (base) this.base = base.replace(/\/$/, '');
    if (key !== undefined) this.key = key;
    if (model) this.model = model;
    localStorage.setItem('chatSettings', JSON.stringify({ base: this.base, key: this.key, model: this.model }));
  }
  async chat(messages) {
    const url = `${this.base}/chat/completions`;
    const headers = { 'Content-Type':'application/json' };
    if (this.key) headers['Authorization'] = `Bearer ${this.key}`;
    const res = await fetch(url, {
      method:'POST', headers,
      body: JSON.stringify({ model: this.model, messages, temperature: 0.7 }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    const data = await res.json();
    return data?.choices?.[0]?.message?.content || '';
  }
  async ollamaReady() {
    try {
      const res = await fetch(`${this.base.replace(/\/v1$/, '')}/api/tags`);
      return res.ok;
    } catch { return false; }
  }
}

module.exports = ChatClient;
