const tg = window.Telegram?.WebApp;
tg?.ready();
tg?.expand();

const money = new Intl.NumberFormat("uz-UZ", { maximumFractionDigits: 0 });

// ---- Foydalanuvchini aniqlash ----
// Telegram ichida ochilganda tg.initDataUnsafe.user.id bot ishlatadigan chat_id
// bilan bir xil bo'ladi (shaxsiy chatda chat_id === user_id), shuning uchun
// bot va Mini App bir xil data/<id>.json faylni ko'radi.
const telegramUser = tg?.initDataUnsafe?.user;
const userId = telegramUser ? String(telegramUser.id) : "demo-local";
if (!telegramUser) {
  document.querySelector("#demoBanner").hidden = false;
}

// ---- Lokal ma'lumot: hozircha faqat Qarz / Jamg'arma / Kredit karta / Kredit ----
const localStoreKey = `my-finance-other-${userId}`;
const initialLocalStore = { entries: [], credits: [] };

function cloneInitialLocalStore() {
  return JSON.parse(JSON.stringify(initialLocalStore));
}

function loadLocalStore() {
  try {
    return JSON.parse(localStorage.getItem(localStoreKey)) || cloneInitialLocalStore();
  } catch {
    return cloneInitialLocalStore();
  }
}

function saveLocalStore(store) {
  localStorage.setItem(localStoreKey, JSON.stringify(store));
}

// ---- API ----
async function apiGet(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`API xato: ${res.status}`);
  return res.json();
}

async function apiSend(path, method, body) {
  const res = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!res.ok) {
    const errBody = await res.json().catch(() => ({}));
    throw new Error(errBody.error || `API xato: ${res.status}`);
  }
  return res.json();
}

let meta = { incomeCategories: [], expenseCategories: [], accounts: [], currencies: [] };

async function loadMeta() {
  try {
    meta = await apiGet("/api/meta");
  } catch (err) {
    console.error("Meta yuklanmadi", err);
    return;
  }
  fillSelect("#incomeCategory", meta.incomeCategories);
  fillSelect("#expenseCategory", meta.expenseCategories);
  fillSelect("#incomeAccount", meta.accounts);
  fillSelect("#expenseAccount", meta.accounts);
  fillSelect("#incomeCurrency", meta.currencies);
  fillSelect("#expenseCurrency", meta.currencies);
}

function fillSelect(selector, values) {
  const select = document.querySelector(selector);
  select.innerHTML = values.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("");
}

function parseAmount(value) {
  const clean = String(value).replace(/[^\d.,-]/g, "").replace(",", ".");
  const amount = Number(clean);
  if (!Number.isFinite(amount)) throw new Error("Summa noto'g'ri");
  return amount;
}

function formatMoney(value) {
  return `${money.format(Math.round(value || 0))} so'm`;
}

function todayInputValue() {
  return new Date().toISOString().slice(0, 10);
}

function toDateInputValue(isoOrDate) {
  const date = new Date(isoOrDate);
  if (Number.isNaN(date.getTime())) return todayInputValue();
  return date.toISOString().slice(0, 10);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;"
  }[char]));
}

// ---- Daromad / Xarajat: umumiy ro'yxat + forma mantiqi ----

function makeEntryController(type) {
  const prefix = type; // "income" | "expense"
  const listEl = document.querySelector(`#${prefix}List`);
  const form = document.querySelector(`#${prefix}Form`);
  const idInput = document.querySelector(`#${prefix}Id`);
  const cancelBtn = document.querySelector(`#${prefix}CancelEdit`);
  const submitBtn = document.querySelector(`#${prefix}Submit`);

  async function fetchList(filters = {}) {
    const params = new URLSearchParams({ userId, type, ...filters });
    const data = await apiGet(`/api/entries?${params.toString()}`);
    return data.entries || [];
  }

  function renderList(entries) {
    if (!entries.length) {
      listEl.innerHTML = `<p class="empty">Hali ma'lumot yo'q.</p>`;
      return;
    }
    listEl.innerHTML = entries.map((item) => `
      <div class="entry-item" data-id="${item.id}">
        <div>
          <strong>${escapeHtml(item.category)}</strong>
          <small>${escapeHtml(item.account || "")} • ${escapeHtml(item.currency || "UZS")} • ${new Date(item.date).toLocaleDateString("uz-UZ")}</small>
          ${item.note ? `<small>${escapeHtml(item.note)}</small>` : ""}
        </div>
        <div class="entry-right">
          <strong>${formatMoney(item.amount)}</strong>
          <div class="entry-actions">
            <button type="button" class="icon-btn small edit-btn">Tahrirlash</button>
            <button type="button" class="icon-btn small danger delete-btn">O'chirish</button>
          </div>
        </div>
      </div>
    `).join("");

    listEl.querySelectorAll(".edit-btn").forEach((btn) => {
      btn.addEventListener("click", (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        const entry = entries.find((item) => item.id === id);
        if (entry) startEdit(entry);
      });
    });
    listEl.querySelectorAll(".delete-btn").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        if (!confirm("Ushbu yozuvni o'chirishni tasdiqlaysizmi?")) return;
        await apiSend(`/api/entries/${id}?userId=${encodeURIComponent(userId)}&type=${type}`, "DELETE");
        await refresh();
        await renderDashboardAndStats();
        tg?.HapticFeedback?.notificationOccurred("success");
      });
    });
  }

  function startEdit(entry) {
    idInput.value = entry.id;
    document.querySelector(`#${prefix}Amount`).value = entry.amount;
    document.querySelector(`#${prefix}Category`).value = entry.category;
    document.querySelector(`#${prefix}Account`).value = entry.account;
    document.querySelector(`#${prefix}Currency`).value = entry.currency || "UZS";
    document.querySelector(`#${prefix}Date`).value = toDateInputValue(entry.date);
    document.querySelector(`#${prefix}Note`).value = entry.note || "";
    if (prefix === "income") {
      document.querySelector("#incomeRecurring").checked = !!entry.recurring;
    }
    submitBtn.textContent = "Saqlash (tahrirlash)";
    cancelBtn.hidden = false;
    document.querySelector(`#${prefix}View`).scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function resetForm() {
    form.reset();
    idInput.value = "";
    document.querySelector(`#${prefix}Date`).value = todayInputValue();
    submitBtn.textContent = "Saqlash";
    cancelBtn.hidden = true;
  }

  cancelBtn.addEventListener("click", resetForm);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const payload = {
      userId,
      type,
      amount: parseAmount(document.querySelector(`#${prefix}Amount`).value),
      category: document.querySelector(`#${prefix}Category`).value,
      account: document.querySelector(`#${prefix}Account`).value,
      currency: document.querySelector(`#${prefix}Currency`).value,
      note: document.querySelector(`#${prefix}Note`).value.trim(),
      date: `${document.querySelector(`#${prefix}Date`).value}T00:00:00`
    };
    if (prefix === "income") {
      payload.recurring = document.querySelector("#incomeRecurring").checked;
    }

    try {
      if (idInput.value) {
        await apiSend(`/api/entries/${idInput.value}`, "PUT", payload);
      } else {
        await apiSend("/api/entries", "POST", payload);
      }
      resetForm();
      await refresh();
      await renderDashboardAndStats();
      tg?.HapticFeedback?.notificationOccurred("success");
    } catch (err) {
      alert(err.message);
    }
  });

  document.querySelector(`#${prefix}FilterBtn`).addEventListener("click", () => refresh());
  document.querySelector(`#${prefix}FilterClear`).addEventListener("click", () => {
    document.querySelector(`#${prefix}Search`).value = "";
    document.querySelector(`#${prefix}From`).value = "";
    document.querySelector(`#${prefix}To`).value = "";
    refresh();
  });

  async function refresh() {
    const filters = {
      search: document.querySelector(`#${prefix}Search`).value.trim(),
      from: document.querySelector(`#${prefix}From`).value,
      to: document.querySelector(`#${prefix}To`).value
    };
    Object.keys(filters).forEach((key) => { if (!filters[key]) delete filters[key]; });
    try {
      const entries = await fetchList(filters);
      renderList(entries);
      return entries;
    } catch (err) {
      listEl.innerHTML = `<p class="empty">Yuklashda xatolik: ${escapeHtml(err.message)}</p>`;
      return [];
    }
  }

  resetForm();

  return { refresh };
}

let incomeController;
let expenseController;

// ---- Dashboard + Statistika ----

function annuityPayment(principal, annualRate, months) {
  const monthlyRate = annualRate / 100 / 12;
  if (!monthlyRate) return principal / months;
  return principal * (monthlyRate * Math.pow(1 + monthlyRate, months)) / (Math.pow(1 + monthlyRate, months) - 1);
}

function renderBars(values) {
  const bars = document.querySelector("#bars");
  const rows = [
    ["Daromad", values.income],
    ["Xarajat", values.expense],
    ["Qarz", values.debt],
    ["Jamg'arma", values.saving],
    ["Kredit", values.credit],
    ["Karta", values.card]
  ];
  const max = Math.max(...rows.map((row) => row[1]), 1);
  bars.innerHTML = rows.map(([label, value]) => `
    <div class="bar-row">
      <header><span>${label}</span><strong>${formatMoney(value)}</strong></header>
      <div class="bar"><i style="--w:${Math.max(4, (value / max) * 100)}%"></i></div>
    </div>
  `).join("");
}

function renderActivity(recentIncome, recentExpense, credits) {
  const activity = document.querySelector("#activity");
  const items = [
    ...recentIncome.map((item) => ({ ...item, label: item.category, kind: "Daromad" })),
    ...recentExpense.map((item) => ({ ...item, label: item.category, kind: "Xarajat" })),
    ...credits.map((item) => ({ amount: item.monthlyPayment, label: "Kredit oylik to'lov", kind: "Kredit", date: item.date }))
  ].sort((a, b) => new Date(b.date) - new Date(a.date)).slice(0, 8);

  if (!items.length) {
    activity.innerHTML = `<p class="empty">Hali ma'lumot yo'q.</p>`;
    return;
  }

  activity.innerHTML = items.map((item) => `
    <div class="activity-item">
      <div>
        <strong>${escapeHtml(item.label)}</strong>
        <small>${escapeHtml(item.kind)} - ${new Date(item.date).toLocaleDateString("uz-UZ")}</small>
      </div>
      <strong>${formatMoney(item.amount)}</strong>
    </div>
  `).join("");
}

async function renderDashboardAndStats() {
  const localStore = loadLocalStore();
  const debts = localStore.entries.filter((item) => item.type === "debt");
  const savings = localStore.entries.filter((item) => item.type === "saving");
  const cards = localStore.entries.filter((item) => item.type === "card");
  const credits = localStore.credits;

  const debtTotal = debts.reduce((total, item) => total + Number(item.amount || 0), 0);
  const savingTotal = savings.reduce((total, item) => total + Number(item.amount || 0), 0);
  const cardUsed = cards.reduce((total, item) => total + Number(item.amount || 0), 0);
  const creditTotal = credits.reduce((total, item) => total + Number(item.principal || 0), 0);

  let summary = {
    monthIncome: 0, monthExpense: 0, todayExpense: 0, weekExpense: 0,
    lastMonthExpense: 0, expenseChangePercent: 0,
    topIncomeSource: null, topExpenseCategory: null, lastIncome: null,
    totalIncome: 0, totalExpense: 0
  };
  try {
    summary = await apiGet(`/api/summary?userId=${encodeURIComponent(userId)}`);
  } catch (err) {
    console.error("Summary yuklanmadi", err);
  }

  document.querySelector("#balance").textContent = formatMoney(summary.totalIncome - summary.totalExpense);
  document.querySelector("#monthExpense").textContent = formatMoney(summary.monthExpense);
  document.querySelector("#monthIncome").textContent = formatMoney(summary.monthIncome);
  document.querySelector("#debtTotal").textContent = formatMoney(debtTotal);
  document.querySelector("#savingTotal").textContent = formatMoney(savingTotal);
  document.querySelector("#creditTotal").textContent = formatMoney(creditTotal);
  document.querySelector("#cardUsed").textContent = formatMoney(cardUsed);

  renderBars({
    income: summary.totalIncome, expense: summary.totalExpense,
    debt: debtTotal, saving: savingTotal, credit: creditTotal, card: cardUsed
  });

  let recentIncome = [];
  let recentExpense = [];
  try {
    recentIncome = (await apiGet(`/api/entries?userId=${encodeURIComponent(userId)}&type=income`)).entries || [];
    recentExpense = (await apiGet(`/api/entries?userId=${encodeURIComponent(userId)}&type=expense`)).entries || [];
  } catch (err) {
    console.error(err);
  }
  renderActivity(recentIncome.slice(0, 5), recentExpense.slice(0, 5), credits);

  const incomeStats = document.querySelector("#incomeStats");
  incomeStats.innerHTML = `
    <div class="stat-row"><span>Shu oy jami</span><strong>${formatMoney(summary.monthIncome)}</strong></div>
    <div class="stat-row"><span>Eng katta manba</span><strong>${summary.topIncomeSource ? `${escapeHtml(summary.topIncomeSource.category)} — ${formatMoney(summary.topIncomeSource.amount)}` : "-"}</strong></div>
    <div class="stat-row"><span>Oxirgi kirim</span><strong>${summary.lastIncome ? formatMoney(summary.lastIncome.amount) : "-"}</strong></div>
  `;

  const expenseStats = document.querySelector("#expenseStats");
  const changeSign = summary.expenseChangePercent >= 0 ? "+" : "";
  expenseStats.innerHTML = `
    <div class="stat-row"><span>Bugungi</span><strong>${formatMoney(summary.todayExpense)}</strong></div>
    <div class="stat-row"><span>Haftalik</span><strong>${formatMoney(summary.weekExpense)}</strong></div>
    <div class="stat-row"><span>Shu oy jami</span><strong>${formatMoney(summary.monthExpense)}</strong></div>
    <div class="stat-row"><span>Eng ko'p ketgan</span><strong>${summary.topExpenseCategory ? `${escapeHtml(summary.topExpenseCategory.category)} — ${formatMoney(summary.topExpenseCategory.amount)}` : "-"}</strong></div>
    <div class="stat-row"><span>O'tgan oyga nisbatan</span><strong>${changeSign}${summary.expenseChangePercent}%</strong></div>
  `;
}

// ---- Boshqa (Qarz / Jamg'arma / Kredit karta / Kredit) ----

document.querySelector("#entryForm").addEventListener("submit", (event) => {
  event.preventDefault();
  const store = loadLocalStore();
  const entry = {
    id: Date.now().toString(36),
    type: document.querySelector("#entryType").value,
    amount: parseAmount(document.querySelector("#amount").value),
    category: document.querySelector("#category").value.trim(),
    note: document.querySelector("#note").value.trim(),
    date: new Date().toISOString()
  };
  store.entries.push(entry);
  saveLocalStore(store);
  event.currentTarget.reset();
  tg?.HapticFeedback?.notificationOccurred("success");
  renderDashboardAndStats();
});

document.querySelector("#creditForm").addEventListener("submit", (event) => {
  event.preventDefault();
  const principal = parseAmount(document.querySelector("#creditAmount").value);
  const annualRate = parseAmount(document.querySelector("#creditRate").value);
  const months = Number(document.querySelector("#creditMonths").value);
  const monthlyPayment = annuityPayment(principal, annualRate, months);
  const total = monthlyPayment * months;
  const overpayment = total - principal;
  const store = loadLocalStore();
  store.credits.push({
    id: Date.now().toString(36),
    principal,
    annualRate,
    months,
    monthlyPayment,
    total,
    overpayment,
    date: new Date().toISOString()
  });
  saveLocalStore(store);
  document.querySelector("#creditResult").innerHTML = `
    <span>Oylik to'lov</span>
    <strong>${formatMoney(monthlyPayment)}</strong>
    <p>Foiz bilan jami: <b>${formatMoney(total)}</b><br>Ortiqcha to'lov: <b>${formatMoney(overpayment)}</b></p>
  `;
  tg?.HapticFeedback?.notificationOccurred("success");
  renderDashboardAndStats();
});

document.querySelector("#clearData").addEventListener("click", () => {
  if (!confirm("Qarz / Jamg'arma / Kredit karta / Kredit ma'lumotlari (faqat shu qurilmada saqlangan) o'chirilsinmi? Daromad va xarajatlarga tegmaydi.")) return;
  saveLocalStore(cloneInitialLocalStore());
  renderDashboardAndStats();
});

// ---- Tablar ----

document.querySelectorAll(".tab").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((item) => item.classList.remove("active"));
    document.querySelectorAll(".view").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    document.querySelector(`#${button.dataset.view}View`).classList.add("active");
  });
});

// ---- Ishga tushirish ----

(async function init() {
  await loadMeta();
  document.querySelector("#incomeDate").value = todayInputValue();
  document.querySelector("#expenseDate").value = todayInputValue();
  incomeController = makeEntryController("income");
  expenseController = makeEntryController("expense");
  await Promise.all([incomeController.refresh(), expenseController.refresh()]);
  await renderDashboardAndStats();
})();
