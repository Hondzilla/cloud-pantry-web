const $ = (selector) => document.querySelector(selector);

const storeKey = 'cloudPantryWebConfig';
const DEFAULT_URL = 'https://goxegmqibodfmzgcvykn.supabase.co';
const DEFAULT_KEY = 'sb_publishable_xSXYc9RW2aOFbBVD7-P7uQ_PmYU8WmC';
const AUTH_REDIRECT = 'https://hondzilla.github.io/cloud-pantry-web/';

let config = JSON.parse(localStorage.getItem(storeKey) || '{}');
if (!config.url) config.url = DEFAULT_URL;
if (!config.key) config.key = DEFAULT_KEY;

let session = config.session || null;
let household = config.household || null;
let state = null;
let revision = 0;

function status(message) {
  $('#status').textContent = message;
}

function save() {
  config = {
    url: $('#url').value.trim().replace(/\/+$/, ''),
    key: $('#key').value.trim(),
    email: $('#email').value.trim(),
    session,
    household
  };
  localStorage.setItem(storeKey, JSON.stringify(config));
}

function headers(auth = true) {
  const result = {
    apikey: config.key,
    'Content-Type': 'application/json'
  };
  if (auth && session?.access_token) {
    result.Authorization = `Bearer ${session.access_token}`;
  }
  return result;
}

async function request(method, path, body, auth = true) {
  const response = await fetch(config.url + path, {
    method,
    headers: headers(auth),
    body: body === undefined ? undefined : JSON.stringify(body)
  });

  let data = null;
  const raw = await response.text();
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch (error) {
      data = raw;
    }
  }

  if (!response.ok) {
    throw new Error(
      data?.message ||
      data?.error_description ||
      data?.hint ||
      data?.error ||
      `Request failed ${response.status}`
    );
  }
  return data;
}

function setConfigFields() {
  $('#url').value = config.url || '';
  $('#key').value = config.key || '';
  $('#email').value = config.email || '';
}

function clearAuthParameters() {
  history.replaceState({}, document.title, window.location.pathname);
}

async function consumeAuthRedirect() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const query = new URLSearchParams(window.location.search);
  const errorDescription = hash.get('error_description') || query.get('error_description');

  if (errorDescription) {
    clearAuthParameters();
    status(decodeURIComponent(errorDescription.replace(/\+/g, ' ')));
    return false;
  }

  const accessToken = hash.get('access_token');
  if (!accessToken) return false;

  session = {
    access_token: accessToken,
    refresh_token: hash.get('refresh_token') || '',
    token_type: hash.get('token_type') || 'bearer',
    expires_in: Number(hash.get('expires_in')) || 3600,
    expires_at: Number(hash.get('expires_at')) || 0
  };
  save();
  clearAuthParameters();
  status('Email confirmed. Signed in.');

  try {
    await loadHouseholds();
  } catch (error) {
    status(error.message);
  }
  return true;
}

async function signUp() {
  save();
  const password = $('#password').value;
  if (!config.email || password.length < 6) {
    throw new Error('Enter an email and a password of at least 6 characters.');
  }

  const path = `/auth/v1/signup?redirect_to=${encodeURIComponent(AUTH_REDIRECT)}`;
  const data = await request('POST', path, {
    email: config.email,
    password
  }, false);

  if (data?.access_token) {
    session = data;
    save();
    await loadHouseholds();
    status('Account created and signed in.');
  } else {
    status('Account created. Check your email and open the confirmation link.');
  }
}

async function resendConfirmation() {
  save();
  if (!config.email) throw new Error('Enter your email first.');

  const path = `/auth/v1/resend?redirect_to=${encodeURIComponent(AUTH_REDIRECT)}`;
  await request('POST', path, {
    type: 'signup',
    email: config.email
  }, false);
  status('A new confirmation email was sent.');
}

async function signIn() {
  save();
  const data = await request(
    'POST',
    '/auth/v1/token?grant_type=password',
    {
      email: config.email,
      password: $('#password').value
    },
    false
  );
  session = data;
  save();
  await loadHouseholds();
  status('Signed in.');
}

function signOut() {
  session = null;
  household = null;
  state = null;
  save();
  $('#workspace').hidden = true;
  $('#inviteCode').textContent = '—';
  status('Signed out.');
}

async function loadHouseholds() {
  if (!session?.access_token) throw new Error('Sign in first.');
  const rows = await request('POST', '/rest/v1/rpc/list_cloud_pantry_households', {});
  if (rows.length) {
    household = rows[0];
    revision = Number(household.revision) || 0;
    save();
    $('#inviteCode').textContent = household.invite_code;
    await pull();
  } else {
    household = null;
    state = null;
    save();
    $('#workspace').hidden = true;
    status('Signed in. Create or join a household.');
  }
}

async function createHousehold() {
  const name = $('#householdName').value.trim() || 'My Household';
  const rows = await request(
    'POST',
    '/rest/v1/rpc/create_cloud_pantry_household',
    { p_name: name }
  );

  household = {
    household_id: rows[0].household_id,
    household_name: name,
    invite_code: rows[0].invite_code
  };
  revision = 0;
  save();
  $('#inviteCode').textContent = household.invite_code;
  state = defaultState();
  state.profile.household = name;
  await push();
  render();
  status('Household created.');
}

async function joinHousehold() {
  const code = $('#joinCode').value.trim().toUpperCase();
  if (!code) throw new Error('Enter the invite code.');

  const rows = await request(
    'POST',
    '/rest/v1/rpc/join_cloud_pantry_household',
    { p_invite_code: code }
  );
  household = rows[0];
  revision = Number(household.revision) || 0;
  save();
  $('#inviteCode').textContent = household.invite_code;
  await pull();
  status('Household joined.');
}

function defaultState() {
  return {
    version: 2,
    profile: {
      household: 'My Household',
      name: 'Friend'
    },
    shopping: {},
    inventoryStatus: {},
    favorites: [],
    neverRepeat: [],
    cooked: [],
    mealCalories: 0,
    calorieTarget: 2000,
    dashboard: {
      monthlySpend: 0,
      weeklyProduce: 0,
      monthlySupplies: 0
    },
    budget: {
      monthlyTarget: 0
    }
  };
}

async function pull() {
  if (!household) throw new Error('Choose a household first.');
  const rows = await request(
    'POST',
    '/rest/v1/rpc/pull_cloud_pantry_state',
    { p_household_id: household.household_id }
  );
  const row = rows[0];
  revision = Number(row.revision) || 0;
  state = row.state && Object.keys(row.state).length ? row.state : defaultState();
  household.household_name = row.household_name;
  household.invite_code = row.invite_code;
  save();
  render();
  status('Latest household loaded.');
}

async function push() {
  if (!state || !household) throw new Error('Load a household first.');
  const rows = await request(
    'POST',
    '/rest/v1/rpc/push_cloud_pantry_state',
    {
      p_household_id: household.household_id,
      p_state: state,
      p_base_revision: revision
    }
  );
  revision = Number(rows[0].revision) || revision;
  status('Changes uploaded.');
}

function money(value) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 0
  }).format(Number(value) || 0);
}

function render() {
  if (!state) return;
  $('#workspace').hidden = false;
  state.profile = state.profile || {};
  state.dashboard = state.dashboard || {};
  state.budget = state.budget || {};

  $('#personalName').value = state.profile.name || '';
  $('#profileHousehold').value = state.profile.household || '';
  $('#calorieInput').value = Number(state.mealCalories) || 0;
  $('#spendInput').value = Number(state.dashboard.monthlySpend) || 0;
  $('#produceInput').value = Number(state.dashboard.weeklyProduce) || 0;
  $('#suppliesInput').value = Number(state.dashboard.monthlySupplies) || 0;
  $('#budgetInput').value = Number(state.budget.monthlyTarget) || 0;

  $('#calories').textContent = (Number(state.mealCalories) || 0).toLocaleString();
  $('#spend').textContent = money(state.dashboard.monthlySpend);
  $('#budget').textContent = money(state.budget.monthlyTarget);

  const remaining =
    (Number(state.budget.monthlyTarget) || 0) -
    (Number(state.dashboard.monthlySpend) || 0);

  $('#advice').textContent = remaining >= 0
    ? `${money(remaining)} remains. Buy low-stock items first and delay bulk restocks that are still marked Plenty.`
    : `You are ${money(Math.abs(remaining))} over the target. Focus on pantry meals and postpone optional household supplies.`;

  const rows = Object.entries(state.shopping || {})
    .filter(([, value]) => value.active !== false)
    .map(([id, value]) => `
      <div class="shop-row">
        <input type="checkbox" ${value.done ? 'checked' : ''} data-id="${id}">
        <span>${id.replaceAll('-', ' ')}</span>
        <b>qty ${value.qty || 1}</b>
      </div>
    `)
    .join('');

  $('#shopping').innerHTML = rows || '<p>No shopping items in this snapshot.</p>';
  document.querySelectorAll('.shop-row input').forEach((input) => {
    input.addEventListener('change', () => {
      state.shopping[input.dataset.id].done = input.checked;
    });
  });
}

function saveDashboard() {
  state.profile.name = $('#personalName').value.trim();
  state.profile.household = $('#profileHousehold').value.trim();
  state.mealCalories = Math.max(0, Number($('#calorieInput').value) || 0);
  state.dashboard = {
    monthlySpend: Math.max(0, Number($('#spendInput').value) || 0),
    weeklyProduce: Math.max(0, Number($('#produceInput').value) || 0),
    monthlySupplies: Math.max(0, Number($('#suppliesInput').value) || 0)
  };
  state.budget = {
    monthlyTarget: Math.max(0, Number($('#budgetInput').value) || 0)
  };
  render();
  status('Local changes are ready to push.');
}

function bind(selector, handler) {
  $(selector).addEventListener('click', () => {
    Promise.resolve(handler()).catch((error) => status(error.message));
  });
}

setConfigFields();
bind('#saveConfig', () => {
  save();
  status('Configuration saved.');
});
bind('#signUp', signUp);
bind('#resendConfirmation', resendConfirmation);
bind('#signIn', signIn);
bind('#signOut', signOut);
bind('#createHousehold', createHousehold);
bind('#joinHousehold', joinHousehold);
bind('#pull', pull);
bind('#push', push);
bind('#saveDashboard', saveDashboard);
bind('#resetCalories', () => {
  if (!state) throw new Error('Load a household first.');
  state.mealCalories = 0;
  render();
  status('Calories reset locally—push to share.');
});

(async function initialize() {
  const handledRedirect = await consumeAuthRedirect();
  if (!handledRedirect && session && household) {
    loadHouseholds().catch((error) => status(error.message));
  }
})();
