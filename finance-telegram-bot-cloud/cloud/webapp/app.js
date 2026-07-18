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

// ---- Lokal ma'lumot: hozircha faqat Qarz / Jamg'arma / Kredit kalkulyatori ----
const localStoreKey = `my-finance-other-${userId}`;
const initialLocalStore = { entries: [] };

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
  const prefix = type;
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

    Object.keys(filters).forEach((key) => {
      if (!filters[key]) delete filters[key];
    });

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
let cardController;
let creditController;// ---- Kredit karta: alohida bo'lim, to'liq API orqali (Boshqa'dagi localStorage emas) ----

function makeCardController() {
  const listEl = document.querySelector("#cardList");
  const form = document.querySelector("#cardForm");
  const idInput = document.querySelector("#cardId");
  const cancelBtn = document.querySelector("#cardCancelEdit");
  const submitBtn = document.querySelector("#cardSubmit");

  let cachedCards = [];

  async function fetchData() {
    const params = new URLSearchParams({ userId });
    return apiGet(`/api/cards?${params.toString()}`);
  }

  function renderSummary(summary) {
    document.querySelector("#cardTotalUsed").textContent = formatMoney(summary.totalUsed);
    document.querySelector("#cardTotalLimit").textContent = formatMoney(summary.totalLimit);
    document.querySelector("#cardUtilization").textContent = `${summary.utilization}%`;
    document.querySelector("#cardUsed").textContent = formatMoney(summary.totalUsed);
  }

  function renderList(cards) {
    if (!cards.length) {
      listEl.innerHTML = `<p class="empty">Hali kredit karta qo'shilmagan.</p>`;
      return;
    }

    listEl.innerHTML = cards.map((card) => {
      const utilization = card.limit > 0 ? Math.round((card.used / card.limit) * 100) : 0;
      const dueText = card.dueDate ? `<small>Keyingi to'lov: ${new Date(card.dueDate).toLocaleDateString("uz-UZ")}</small>` : "";

      return `
        <div class="entry-item" data-id="${card.id}">
          <div>
            <strong>${escapeHtml(card.bank)} ${escapeHtml(card.name)}</strong>
            <small>${formatMoney(card.used)} / ${formatMoney(card.limit)} (${utilization}%)</small>
            ${dueText}
            ${card.note ? `<small>${escapeHtml(card.note)}</small>` : ""}
            <div class="bar"><i style="--w:${Math.min(100, Math.max(4, utilization))}%"></i></div>
          </div>
          <div class="entry-right">
            <div class="entry-actions">
              <button type="button" class="icon-btn small pay-btn">To'lov</button>
              <button type="button" class="icon-btn small edit-btn">Tahrirlash</button>
              <button type="button" class="icon-btn small danger delete-btn">O'chirish</button>
            </div>
          </div>
        </div>
      `;
    }).join("");

    listEl.querySelectorAll(".edit-btn").forEach((btn) => {
      btn.addEventListener("click", (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        const card = cachedCards.find((item) => item.id === id);
        if (card) startEdit(card);
      });
    });

    listEl.querySelectorAll(".delete-btn").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        if (!confirm("Ushbu kartani o'chirishni tasdiqlaysizmi?")) return;
        await apiSend(`/api/cards/${id}?userId=${encodeURIComponent(userId)}`, "DELETE");
        await refresh();
        await renderDashboardAndStats();
        tg?.HapticFeedback?.notificationOccurred("success");
      });
    });

    listEl.querySelectorAll(".pay-btn").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        const raw = prompt("To'lov summasini kiriting:");
        if (!raw) return;

        let amount;
        try {
          amount = parseAmount(raw);
        } catch {
          alert("Summa noto'g'ri kiritildi.");
          return;
        }

        await apiSend(`/api/cards/${id}/payment`, "POST", { userId, amount });
        await refresh();
        await renderDashboardAndStats();
        tg?.HapticFeedback?.notificationOccurred("success");
      });
    });
  }

  function startEdit(card) {
    idInput.value = card.id;
    document.querySelector("#cardBank").value = card.bank;
    document.querySelector("#cardName").value = card.name;
    document.querySelector("#cardLimit").value = card.limit;
    document.querySelector("#cardUsedAmount").value = card.used;
    document.querySelector("#cardRate").value = card.annualRate || "";
    document.querySelector("#cardGrace").value = card.graceDays || "";
    document.querySelector("#cardDueDate").value = card.dueDate ? toDateInputValue(card.dueDate) : "";
    document.querySelector("#cardNote").value = card.note || "";
    submitBtn.textContent = "Saqlash (tahrirlash)";
    cancelBtn.hidden = false;
    document.querySelector("#cardView").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function resetForm() {
    form.reset();
    idInput.value = "";
    submitBtn.textContent = "Saqlash";
    cancelBtn.hidden = true;
  }

  cancelBtn.addEventListener("click", resetForm);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const payload = {
      userId,
      bank: document.querySelector("#cardBank").value.trim(),
      name: document.querySelector("#cardName").value.trim(),
      limit: parseAmount(document.querySelector("#cardLimit").value),
      used: parseAmount(document.querySelector("#cardUsedAmount").value),
      annualRate: document.querySelector("#cardRate").value ? parseAmount(document.querySelector("#cardRate").value) : 0,
      graceDays: document.querySelector("#cardGrace").value ? Number(document.querySelector("#cardGrace").value) : 0,
      dueDate: document.querySelector("#cardDueDate").value ? `${document.querySelector("#cardDueDate").value}T00:00:00` : "",
      note: document.querySelector("#cardNote").value.trim()
    };

    try {
      if (idInput.value) {
        await apiSend(`/api/cards/${idInput.value}`, "PUT", payload);
      } else {
        await apiSend("/api/cards", "POST", payload);
      }

      resetForm();
      await refresh();
      await renderDashboardAndStats();
      tg?.HapticFeedback?.notificationOccurred("success");
    } catch (err) {
      alert(err.message);
    }
  });

  async function refresh() {
    try {
      const data = await fetchData();
      cachedCards = data.cards || [];
      renderSummary(data.summary || { totalUsed: 0, totalLimit: 0, utilization: 0 });
      renderList(cachedCards);
      return cachedCards;
    } catch (err) {
      console.error("Kartalar yuklanmadi", err);
      listEl.innerHTML = `<p class="empty">Yuklashda xatolik yuz berdi.</p>`;
      return [];
    }
  }

  resetForm();

  return { refresh, getCards: () => cachedCards };
}

// ---- Kredit: annuitet/differensial, to'lov grafigi, oldindan to'lash kalkulyatori ----

function makeCreditController() {
  const listEl = document.querySelector("#creditList");
  const form = document.querySelector("#creditForm");
  const idInput = document.querySelector("#creditId");
  const cancelBtn = document.querySelector("#creditCancelEdit");
  const submitBtn = document.querySelector("#creditSubmit");
  const scheduleWrap = document.querySelector("#creditScheduleWrap");
  const scheduleTitle = document.querySelector("#creditScheduleTitle");
  const scheduleList = document.querySelector("#creditScheduleList");
  const payoffForm = document.querySelector("#creditPayoffForm");
  const payoffIdInput = document.querySelector("#creditPayoffId");
  const payoffResult = document.querySelector("#creditPayoffResult");

  let cachedLoans = [];

  async function fetchData() {
    const params = new URLSearchParams({ userId });
    return apiGet(`/api/credits?${params.toString()}`);
  }

  function renderSummary(summary) {
    document.querySelector("#creditTotalPrincipal").textContent = formatMoney(summary.totalPrincipal);
    document.querySelector("#creditRemaining").textContent = formatMoney(summary.remaining);
    document.querySelector("#creditMonthPayment").textContent = formatMoney(summary.currentMonthPayment);
  }

  function renderList(loans) {
    if (!loans.length) {
      listEl.innerHTML = `<p class="empty">Hali kredit qo'shilmagan.</p>`;
      return;
    }

    listEl.innerHTML = loans.map((loan) => {
      const progress = loan.termMonths > 0 ? Math.round((loan.monthsElapsed / loan.termMonths) * 100) : 0;
      const dueText = loan.nextDueDate ? `<small>Keyingi to'lov: ${new Date(loan.nextDueDate).toLocaleDateString("uz-UZ")}</small>` : "";

      return `
        <div class="entry-item" data-id="${loan.id}">
          <div>
            <strong>${escapeHtml(loan.bank)} — ${escapeHtml(loan.status)}</strong>
            <small>Qolgan qarz: ${formatMoney(loan.remaining)} / ${formatMoney(loan.principal)} (${loan.type === "differensial" ? "differensial" : "annuitet"})</small>
            <small>Shu oy to'lovi: ${formatMoney(loan.currentPayment)}</small>
            ${dueText}
            ${loan.note ? `<small>${escapeHtml(loan.note)}</small>` : ""}
            <div class="bar"><i style="--w:${Math.min(100, Math.max(4, progress))}%"></i></div>
          </div>
          <div class="entry-right">
            <div class="entry-actions">
              <button type="button" class="icon-btn small schedule-btn">Grafik</button>
              <button type="button" class="icon-btn small payoff-btn">Oldindan to'lash</button>
              <button type="button" class="icon-btn small edit-btn">Tahrirlash</button>
              <button type="button" class="icon-btn small danger delete-btn">O'chirish</button>
            </div>
          </div>
        </div>
      `;
    }).join("");

    listEl.querySelectorAll(".edit-btn").forEach((btn) => {
      btn.addEventListener("click", (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        const loan = cachedLoans.find((item) => item.id === id);
        if (loan) startEdit(loan);
      });
    });

    listEl.querySelectorAll(".delete-btn").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        if (!confirm("Ushbu kreditni o'chirishni tasdiqlaysizmi?")) return;
        await apiSend(`/api/credits/${id}?userId=${encodeURIComponent(userId)}`, "DELETE");
        await refresh();
        await renderDashboardAndStats();
        tg?.HapticFeedback?.notificationOccurred("success");
      });
    });

    listEl.querySelectorAll(".schedule-btn").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        const loan = cachedLoans.find((item) => item.id === id);
        const params = new URLSearchParams({ userId });
        const data = await apiGet(`/api/credits/${id}/schedule?${params.toString()}`);
        renderSchedule(loan, data.schedule || []);
      });
    });

    listEl.querySelectorAll(".payoff-btn").forEach((btn) => {
      btn.addEventListener("click", (event) => {
        const id = event.currentTarget.closest(".entry-item").dataset.id;
        payoffIdInput.value = id;
        payoffResult.textContent = "";
        payoffForm.hidden = false;
        payoffForm.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    });
  }  function renderSchedule(loan, schedule) {
    scheduleWrap.hidden = false;
    scheduleTitle.textContent = `${loan.bank} — to'lov grafigi`;
    scheduleList.innerHTML = schedule.map((row) => `
      <div class="entry-item">
        <div><strong>Oy ${row.month}</strong><small>To'lov: ${formatMoney(row.payment)}</small></div>
        <div class="entry-right"><strong>${formatMoney(row.remaining)}</strong><small>Foiz: ${formatMoney(row.interestPart)}</small></div>
      </div>
    `).join("");
    scheduleWrap.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  payoffForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const id = payoffIdInput.value;
    const amount = parseAmount(document.querySelector("#creditPayoffAmount").value);

    try {
      const estimate = await apiSend(`/api/credits/${id}/payoff`, "POST", { userId, extraAmount: amount });
      payoffResult.innerHTML = `Muddat <b>${estimate.monthsSaved} oyga</b> qisqaradi, foizdan <b>${formatMoney(estimate.interestSaved)}</b> tejaysiz.`;
    } catch (err) {
      alert(err.message);
    }
  });

  function startEdit(loan) {
    idInput.value = loan.id;
    document.querySelector("#creditBank").value = loan.bank;
    document.querySelector("#creditPrincipal").value = loan.principal;
    document.querySelector("#creditIssueDate").value = loan.issueDate ? toDateInputValue(loan.issueDate) : "";
    document.querySelector("#creditTermMonths").value = loan.termMonths;
    document.querySelector("#creditRate").value = loan.annualRate;
    document.querySelector("#creditType").value = loan.type || "annuitet";
    document.querySelector("#creditNote").value = loan.note || "";
    submitBtn.textContent = "Saqlash (tahrirlash)";
    cancelBtn.hidden = false;
    document.querySelector("#creditView").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function resetForm() {
    form.reset();
    idInput.value = "";
    submitBtn.textContent = "Saqlash";
    cancelBtn.hidden = true;
  }

  cancelBtn.addEventListener("click", resetForm);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const payload = {
      userId,
      bank: document.querySelector("#creditBank").value.trim(),
      principal: parseAmount(document.querySelector("#creditPrincipal").value),
      issueDate: document.querySelector("#creditIssueDate").value,
      termMonths: Number(document.querySelector("#creditTermMonths").value),
      annualRate: parseAmount(document.querySelector("#creditRate").value),
      type: document.querySelector("#creditType").value,
      note: document.querySelector("#creditNote").value.trim()
    };

    try {
      if (idInput.value) {
        await apiSend(`/api/credits/${idInput.value}`, "PUT", payload);
      } else {
        await apiSend("/api/credits", "POST", payload);
      }

      resetForm();
      await refresh();
      await renderDashboardAndStats();
      tg?.HapticFeedback?.notificationOccurred("success");
    } catch (err) {
      alert(err.message);
    }
  });

  async function refresh() {
    try {
      const data = await fetchData();
      cachedLoans = data.credits || [];
      renderSummary(data.summary || { totalPrincipal: 0, remaining: 0, currentMonthPayment: 0 });
      renderList(cachedLoans);
      return cachedLoans;
    } catch (err) {
      console.error("Kreditlar yuklanmadi", err);
      listEl.innerHTML = `<p class="empty">Yuklashda xatolik yuz berdi.</p>`;
      return [];
    }
  }

  resetForm();

  return { refresh, getLoans: () => cachedLoans };
}

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

function renderActivity(recentIncome, recentExpense, loans) {
  const activity = document.querySelector("#activity");

  const items = [
    ...recentIncome.map((item) => ({ ...item, label: item.category, kind: "Daromad" })),
    ...recentExpense.map((item) => ({ ...item, label: item.category, kind: "Xarajat" })),
    ...loans.map((item) => ({ amount: item.currentPayment, label: `${item.bank} — kredit to'lovi`, kind: "Kredit", date: item.issueDate }))
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
  const loans = creditController?.getLoans() || [];

  const debtTotal = debts.reduce((total, item) => total + Number(item.amount || 0), 0);
  const savingTotal = savings.reduce((total, item) => total + Number(item.amount || 0), 0);
  const cardUsed = (cardController?.getCards() || []).reduce((total, item) => total + Number(item.used || 0), 0);
  const creditTotal = loans.reduce((total, item) => total + Number(item.remaining || 0), 0);

  let summary = {
    monthIncome: 0,
    monthExpense: 0,
    todayExpense: 0,
    weekExpense: 0,
    lastMonthExpense: 0,
    expenseChangePercent: 0,
    topIncomeSource: null,
    topExpenseCategory: null,
    lastIncome: null,
    totalIncome: 0,
    totalExpense: 0
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
    income: summary.totalIncome,
    expense: summary.totalExpense,
    debt: debtTotal,
    saving: savingTotal,
    credit: creditTotal,
    card: cardUsed
  });

  let recentIncome = [];
  let recentExpense = [];

  try {
    recentIncome = (await apiGet(`/api/entries?userId=${encodeURIComponent(userId)}&type=income`)).entries || [];
    recentExpense = (await apiGet(`/api/entries?userId=${encodeURIComponent(userId)}&type=expense`)).entries || [];
  } catch (err) {
    console.error(err);
  }

  renderActivity(recentIncome.slice(0, 5), recentExpense.slice(0, 5), loans);

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

document.querySelector("#clearData").addEventListener("click", () => {
  if (!confirm("Qarz / Jamg'arma ma'lumotlari (faqat shu qurilmada saqlangan) o'chirilsinmi? Daromad va xarajatlarga tegmaydi.")) return;
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
  cardController = makeCardController();
  creditController = makeCreditController();

  await Promise.all([
    incomeController.refresh(),
    expenseController.refresh(),
    cardController.refresh(),
    creditController.refresh()
  ]);

  await renderDashboardAndStats();
})();
