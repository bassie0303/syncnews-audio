// SyncNews Audio 拡張ポップアップ。
// 初回はメール＋パスワードでログイン（セッションは chrome.storage.local に保存）。
// 「登録」で現在タブの URL ＋ ページHTML を POST /api/articles に JWT 付きで送る。
// HTML を送るので有料会員ページ（閲覧権を持つ本文）も処理できる。

const $ = (id) => document.getElementById(id);
const setStatus = (msg, cls) => {
  $("status").className = "status " + (cls || "");
  $("status").textContent = msg || "";
};

// ---- セッション（chrome.storage.local）----
async function getSession() {
  const { session } = await chrome.storage.local.get("session");
  return session || null;
}
async function setSession(s) {
  await chrome.storage.local.set({ session: s });
}
async function clearSession() {
  await chrome.storage.local.remove("session");
}

// ---- Supabase Auth (GoTrue REST) ----
async function authFetch(grant, body) {
  const res = await fetch(
    `${CONFIG.SUPABASE_URL}/auth/v1/token?grant_type=${grant}`,
    {
      method: "POST",
      headers: { apikey: CONFIG.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error_description || data.msg || data.error || `HTTP ${res.status}`);
  }
  return data;
}

async function login(email, password) {
  const s = await authFetch("password", { email, password });
  await setSession(s);
  return s;
}

// 有効なアクセストークンを返す（期限切れなら refresh）。無効なら null。
async function freshToken() {
  const s = await getSession();
  if (!s || !s.access_token) return null;
  const now = Math.floor(Date.now() / 1000);
  if (s.expires_at && s.expires_at - 60 > now) return s.access_token;
  try {
    const ns = await authFetch("refresh_token", { refresh_token: s.refresh_token });
    await setSession(ns);
    return ns.access_token;
  } catch (e) {
    await clearSession();
    return null;
  }
}

// ---- 画面切替 ----
function showLogin() {
  $("login").classList.remove("hidden");
  $("main").classList.add("hidden");
}
async function showMain() {
  $("login").classList.add("hidden");
  $("main").classList.remove("hidden");
  const s = await getSession();
  $("who").textContent = s && s.user ? s.user.email || "" : "";
}

// ---- 登録 ----
async function register() {
  const token = await freshToken();
  if (!token) {
    setStatus("ログインが必要です", "err");
    showLogin();
    return;
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https?:\/\//i.test(tab.url || "")) {
    setStatus("このページは登録できません", "err");
    return;
  }
  $("registerbtn").disabled = true;
  setStatus("ページを取得中…");

  // 現在タブの URL と HTML（有料会員ページの本文対応）を取得。
  let url = tab.url;
  let html = null;
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({ url: location.href, html: document.documentElement.outerHTML }),
    });
    if (r && r.result) {
      url = r.result.url || url;
      html = r.result.html || null;
    }
  } catch (e) {
    // 一部ページはスクリプト注入不可。その場合は URL のみ送る。
  }

  setStatus("登録中…");
  try {
    const res = await fetch(`${CONFIG.API_BASE}/api/articles`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
      body: JSON.stringify(html ? { url, html } : { url }),
    });
    if (res.ok) {
      setStatus("✅ 登録しました！変換を開始しました。", "ok");
    } else if (res.status === 401) {
      await clearSession();
      setStatus("セッションが切れました。再ログインしてください。", "err");
      showLogin();
    } else {
      setStatus("登録に失敗: " + res.status + " " + (await res.text()), "err");
    }
  } catch (e) {
    setStatus("通信に失敗しました: " + e, "err");
  } finally {
    $("registerbtn").disabled = false;
  }
}

// ---- 起動 ----
(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  $("url").textContent = (tab && tab.url) || "";

  $("loginbtn").onclick = async () => {
    setStatus("ログイン中…");
    $("loginbtn").disabled = true;
    try {
      await login($("email").value.trim(), $("password").value);
      await showMain();
      setStatus("ログインしました。「この記事を登録」を押してください。", "ok");
    } catch (e) {
      setStatus("ログイン失敗: " + e.message, "err");
    } finally {
      $("loginbtn").disabled = false;
    }
  };
  $("registerbtn").onclick = register;
  $("logout").onclick = async () => {
    await clearSession();
    setStatus("ログアウトしました");
    showLogin();
  };

  // セッションがあればメイン、なければログイン。
  const token = await freshToken();
  if (token) {
    await showMain();
  } else {
    showLogin();
  }
})();
