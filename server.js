const express = require('express');
const mysql2 = require('mysql2/promise');
const cors = require('cors');
const path = require('path');

// Load environment variables from .env file
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json());

// ── Serve frontend static files ──────────────────────────────────────────────
app.use(express.static(path.join(__dirname)));

// ── DB CONFIG ───────────────────────────────────────────────────────────────
const dbConfig = {
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASS || '',
  database: 'BloodBankDB',
  waitForConnections: true,
  connectionLimit: 10
};

let pool;
async function getPool() {
  if (!pool) pool = mysql2.createPool(dbConfig);
  return pool;
}

async function query(sql, params = []) {
  const p = await getPool();
  const [rows] = await p.execute(sql, params);
  return rows;
}

async function callProc(sql, params = []) {
  const p = await getPool();
  const [results] = await p.query(sql, params);
  return results;
}

// ── HELPER ──────────────────────────────────────────────────────────────────
const wrap = fn => async (req, res) => {
  try { await fn(req, res); }
  catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
};

// ══════════════════════════════════════════════════════════════════════════════
//  DASHBOARD STATS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/stats', wrap(async (req, res) => {
  const [donors]    = await query('SELECT COUNT(*) AS n FROM DONOR');
  const [units]     = await query("SELECT COUNT(*) AS n FROM BLOOD_UNIT WHERE status='Available' AND expiry_date >= CURDATE()");
  const [requests]  = await query('SELECT COUNT(*) AS n FROM REQUEST');
  const [pending]   = await query("SELECT COUNT(*) AS n FROM REQUEST WHERE status='Pending'");
  const [hospitals] = await query('SELECT COUNT(*) AS n FROM HOSPITAL');
  const [banks]     = await query('SELECT COUNT(*) AS n FROM BLOOD_BANK');
  const [expired]   = await query("SELECT COUNT(*) AS n FROM BLOOD_UNIT WHERE status='Expired'");
  const [used]      = await query("SELECT COUNT(*) AS n FROM BLOOD_UNIT WHERE status='Used'");
  const [notifs]    = await query('SELECT COUNT(*) AS n FROM NOTIFICATION_LOG');
  res.json({
    donors: donors.n, availableUnits: units.n, totalRequests: requests.n,
    pendingRequests: pending.n, hospitals: hospitals.n, banks: banks.n,
    expiredUnits: expired.n, usedUnits: used.n, notifications: notifs.n
  });
}));

// Blood group distribution
app.get('/api/stats/blood-groups', wrap(async (req, res) => {
  const rows = await query(
    "SELECT blood_group, COUNT(*) AS count FROM BLOOD_UNIT WHERE status='Available' AND expiry_date >= CURDATE() GROUP BY blood_group ORDER BY blood_group"
  );
  res.json(rows);
}));

// Stock levels per bank per blood group
app.get('/api/stats/stock-levels', wrap(async (req, res) => {
  const rows = await query(
    `SELECT bb.name AS bank_name, bu.blood_group,
            COUNT(*) AS available,
            fn_Critical_Stock_Level(bu.bank_id, bu.blood_group) AS level
     FROM BLOOD_UNIT bu JOIN BLOOD_BANK bb ON bu.bank_id = bb.bank_id
     WHERE bu.status = 'Available' AND bu.expiry_date >= CURDATE()
     GROUP BY bu.bank_id, bu.blood_group, bb.name ORDER BY bb.name, bu.blood_group`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  DONORS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/donors', wrap(async (req, res) => {
  const rows = await query(
    `SELECT d.*, fn_Donor_Loyalty_Tier(d.donor_id) AS tier,
            COALESCE(dr.points,0) AS reward_points,
            COUNT(don.donation_id) AS total_donations
     FROM DONOR d
     LEFT JOIN DONOR_REWARD dr ON d.donor_id = dr.donor_id
     LEFT JOIN DONATION don ON d.donor_id = don.donor_id
     GROUP BY d.donor_id ORDER BY d.donor_id DESC`
  );
  res.json(rows);
}));

app.get('/api/donors/:id', wrap(async (req, res) => {
  const [donor] = await query(
    `SELECT d.*, fn_Donor_Loyalty_Tier(d.donor_id) AS tier, COALESCE(dr.points,0) AS reward_points
     FROM DONOR d LEFT JOIN DONOR_REWARD dr ON d.donor_id = dr.donor_id
     WHERE d.donor_id = ?`, [req.params.id]
  );
  const donations = await query(
    `SELECT don.*, bb.name AS bank_name FROM DONATION don
     JOIN BLOOD_BANK bb ON don.bank_id = bb.bank_id
     WHERE don.donor_id = ? ORDER BY don.donation_date DESC`, [req.params.id]
  );
  res.json({ ...donor, donations });
}));

app.post('/api/donors', wrap(async (req, res) => {
  const { name, age, blood_group, contact } = req.body;
  const result = await callProc(
    'INSERT INTO DONOR (name, age, blood_group, last_donation_date, contact) VALUES (?,?,?,NULL,?)',
    [name, age, blood_group, contact]
  );
  res.json({ donor_id: result.insertId, message: 'Donor registered successfully' });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  DONATIONS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/donations', wrap(async (req, res) => {
  const rows = await query(
    `SELECT don.*, d.name AS donor_name, d.blood_group, bb.name AS bank_name
     FROM DONATION don
     JOIN DONOR d ON don.donor_id = d.donor_id
     JOIN BLOOD_BANK bb ON don.bank_id = bb.bank_id
     ORDER BY don.donation_date DESC LIMIT 100`
  );
  res.json(rows);
}));

app.post('/api/donations', wrap(async (req, res) => {
  const { donor_id, bank_id } = req.body;
  // Check donor exists
  const [donor] = await query('SELECT * FROM DONOR WHERE donor_id = ?', [donor_id]);
  if (!donor) return res.status(404).json({ error: 'Donor not found' });

  const today = new Date().toISOString().slice(0, 10);
  const result = await callProc(
    'INSERT INTO DONATION (donor_id, bank_id, donation_date) VALUES (?,?,?)',
    [donor_id, bank_id, today]
  );
  // Update last_donation_date
  await callProc('UPDATE DONOR SET last_donation_date = ? WHERE donor_id = ?', [today, donor_id]);
  // Trigger fires automatically in DB creating BLOOD_UNIT

  res.json({ donation_id: result.insertId, message: `Donation recorded. Blood unit auto-created via DB trigger.` });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  BLOOD UNITS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/blood-units', wrap(async (req, res) => {
  const { bank_id, blood_group, status } = req.query;
  let sql = `SELECT bu.*, bb.name AS bank_name,
                    fn_Days_To_Expiry(bu.unit_id) AS days_to_expiry
             FROM BLOOD_UNIT bu JOIN BLOOD_BANK bb ON bu.bank_id = bb.bank_id
             WHERE 1=1`;
  const params = [];
  if (bank_id) { sql += ' AND bu.bank_id = ?'; params.push(bank_id); }
  if (blood_group) { sql += ' AND bu.blood_group = ?'; params.push(blood_group); }
  if (status) { sql += ' AND bu.status = ?'; params.push(status); }
  sql += ' ORDER BY bu.expiry_date ASC LIMIT 200';
  res.json(await query(sql, params));
}));

// Expiring soon (within 7 days)
app.get('/api/blood-units/expiring-soon', wrap(async (req, res) => {
  const rows = await query(
    `SELECT bu.*, bb.name AS bank_name, fn_Days_To_Expiry(bu.unit_id) AS days_to_expiry
     FROM BLOOD_UNIT bu JOIN BLOOD_BANK bb ON bu.bank_id = bb.bank_id
     WHERE bu.status = 'Available' AND bu.expiry_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 7 DAY)
     ORDER BY bu.expiry_date ASC`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  BLOOD BANKS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/banks', wrap(async (req, res) => {
  const rows = await query(
    `SELECT bb.*,
            COUNT(CASE WHEN bu.status='Available' AND bu.expiry_date >= CURDATE() THEN 1 END) AS available_units,
            COUNT(DISTINCT s.staff_id) AS staff_count
     FROM BLOOD_BANK bb
     LEFT JOIN BLOOD_UNIT bu ON bb.bank_id = bu.bank_id
     LEFT JOIN STAFF s ON bb.bank_id = s.bank_id
     GROUP BY bb.bank_id ORDER BY bb.bank_id`
  );
  res.json(rows);
}));

app.get('/api/banks/:id/stock', wrap(async (req, res) => {
  const rows = await query(
    `SELECT bu.blood_group,
            SUM(CASE WHEN bu.status='Available' AND bu.expiry_date >= CURDATE() THEN 1 ELSE 0 END) AS available,
            SUM(CASE WHEN bu.status='Used' THEN 1 ELSE 0 END) AS used,
            SUM(CASE WHEN bu.status='Expired' THEN 1 ELSE 0 END) AS expired,
            fn_Critical_Stock_Level(bu.bank_id, bu.blood_group) AS stock_level
     FROM BLOOD_UNIT bu
     WHERE bu.bank_id = ?
     GROUP BY bu.blood_group ORDER BY bu.blood_group`, [req.params.id]
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  REQUESTS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/requests', wrap(async (req, res) => {
  const rows = await query(
    `SELECT r.*, h.name AS hospital_name,
            fn_Request_Priority(r.request_id) AS priority
     FROM REQUEST r JOIN HOSPITAL h ON r.hospital_id = h.hospital_id
     ORDER BY r.request_date DESC, r.request_id DESC LIMIT 100`
  );
  res.json(rows);
}));

app.post('/api/requests', wrap(async (req, res) => {
  const { hospital_id, blood_group, units_required } = req.body;
  const today = new Date().toISOString().slice(0, 10);
  // Trigger before_request_insert will auto-set status; after_request_insert marks units Used
  const result = await callProc(
    'INSERT INTO REQUEST (hospital_id, blood_group, units_required, request_date) VALUES (?,?,?,?)',
    [hospital_id, blood_group, units_required, today]
  );
  const [req2] = await query(
    `SELECT r.*, fn_Request_Priority(r.request_id) AS priority
     FROM REQUEST r WHERE r.request_id = ?`, [result.insertId]
  );
  res.json({ request: req2, message: `Request ${req2.status === 'Completed' ? 'fulfilled — units auto-allocated by DB trigger' : 'queued as Pending — insufficient stock'}` });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  HOSPITALS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/hospitals', wrap(async (req, res) => {
  const rows = await query(
    `SELECT h.*, COUNT(r.request_id) AS total_requests,
            SUM(CASE WHEN r.status='Pending' THEN 1 ELSE 0 END) AS pending_requests
     FROM HOSPITAL h LEFT JOIN REQUEST r ON h.hospital_id = r.hospital_id
     GROUP BY h.hospital_id ORDER BY h.hospital_id`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  STAFF
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/staff', wrap(async (req, res) => {
  const rows = await query(
    `SELECT s.*, r.role_name, bb.name AS bank_name
     FROM STAFF s LEFT JOIN ROLE r ON s.role_id = r.role_id
     LEFT JOIN BLOOD_BANK bb ON s.bank_id = bb.bank_id
     ORDER BY s.bank_id, s.staff_id`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  COMPATIBILITY CHECKER
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/compatibility', wrap(async (req, res) => {
  const { donor, recipient } = req.query;
  if (!donor || !recipient) return res.status(400).json({ error: 'donor and recipient required' });
  const [row] = await query('SELECT fn_Is_Compatible(?,?) AS result', [donor, recipient]);
  const availableUnits = await query(
    `SELECT COUNT(*) AS count FROM BLOOD_UNIT bu
     JOIN COMPATIBILITY c ON bu.blood_group = c.donor_group
     WHERE c.recipient_group = ? AND bu.status = 'Available' AND bu.expiry_date >= CURDATE()`,
    [recipient]
  );
  res.json({ result: row.result, availableCompatibleUnits: availableUnits[0].count });
}));

// Full compatibility matrix
app.get('/api/compatibility/matrix', wrap(async (req, res) => {
  const rows = await query('SELECT * FROM COMPATIBILITY ORDER BY donor_group, recipient_group');
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  STORED PROCEDURES
// ══════════════════════════════════════════════════════════════════════════════

// Process Emergency Request
app.post('/api/procedures/emergency-request', wrap(async (req, res) => {
  const { location_id, blood_group, priority_level } = req.body;
  const results = await callProc('CALL Process_Emergency_Request(?,?,?)', [location_id, blood_group, priority_level]);
  const msg = results[0]?.[0]?.Message || 'Emergency request processed';
  // Fetch the inserted emergency request
  const emergencies = await query(
    'SELECT * FROM EMERGENCY_REQUEST ORDER BY req_id DESC LIMIT 1'
  );
  res.json({ message: msg, emergency: emergencies[0] });
}));

// Redistribute Stock
app.post('/api/procedures/redistribute', wrap(async (req, res) => {
  const { source_bank, destination_bank } = req.body;
  const results = await callProc('CALL Redistribute_Stock_Between_Banks(?,?)', [source_bank, destination_bank]);
  res.json({ message: results[0]?.[0]?.Message || 'Done' });
}));

// Auto Remove Expired Units
app.post('/api/procedures/expire-units', wrap(async (req, res) => {
  const results = await callProc('CALL Auto_Remove_Expiring_Units()');
  res.json({ message: results[0]?.[0]?.Message || 'Done' });
}));

// Reward Donor
app.post('/api/procedures/reward-donor', wrap(async (req, res) => {
  const { donor_id } = req.body;
  const results = await callProc('CALL Reward_Active_Donor(?)', [donor_id]);
  const [reward] = await query('SELECT * FROM DONOR_REWARD WHERE donor_id = ?', [donor_id]);
  res.json({ message: results[0]?.[0]?.Message || 'Done', reward });
}));

// Schedule Donation Drive
app.post('/api/procedures/donation-drive', wrap(async (req, res) => {
  const { blood_group } = req.body;
  const results = await callProc('CALL Schedule_Donation_Drive(?)', [blood_group]);
  res.json({ message: results[0]?.[0]?.Message || 'Done' });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  NOTIFICATIONS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/notifications', wrap(async (req, res) => {
  const rows = await query('SELECT * FROM NOTIFICATION_LOG ORDER BY created_at DESC LIMIT 50');
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  TEMPERATURE LOGS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/temperature-logs', wrap(async (req, res) => {
  const rows = await query(
    `SELECT tl.*, bu.blood_group, bb.name AS bank_name
     FROM TEMPERATURE_LOG tl
     JOIN BLOOD_UNIT bu ON tl.unit_id = bu.unit_id
     JOIN BLOOD_BANK bb ON bu.bank_id = bb.bank_id
     ORDER BY tl.recorded_at DESC LIMIT 50`
  );
  res.json(rows);
}));

app.post('/api/temperature-logs', wrap(async (req, res) => {
  const { unit_id, temperature } = req.body;
  const result = await callProc(
    'INSERT INTO TEMPERATURE_LOG (unit_id, temperature) VALUES (?,?)',
    [unit_id, temperature]
  );
  // Auto-alert if out of safe range (2-6°C for blood)
  let alert = null;
  if (temperature < 2 || temperature > 6) {
    alert = `⚠️ Temperature ${temperature}°C is outside safe range (2–6°C)!`;
    await callProc('INSERT INTO NOTIFICATION_LOG (message) VALUES (?)', [
      `TEMP ALERT: Unit ${unit_id} recorded ${temperature}°C — out of safe range`
    ]);
  }
  res.json({ log_id: result.insertId, alert });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  TRANSPORT
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/transport', wrap(async (req, res) => {
  const rows = await query(
    `SELECT t.*, bu.blood_group, bb.name AS source_bank_name
     FROM TRANSPORT t
     JOIN BLOOD_UNIT bu ON t.unit_id = bu.unit_id
     JOIN BLOOD_BANK bb ON t.source_bank = bb.bank_id
     ORDER BY t.transport_id DESC LIMIT 50`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  EMERGENCY REQUESTS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/emergency-requests', wrap(async (req, res) => {
  const rows = await query(
    `SELECT er.*, gl.city, gl.latitude, gl.longitude
     FROM EMERGENCY_REQUEST er
     LEFT JOIN GEO_LOCATION gl ON er.location_id = gl.location_id
     ORDER BY er.req_id DESC LIMIT 50`
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  GEO LOCATIONS
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/locations', wrap(async (req, res) => {
  res.json(await query('SELECT * FROM GEO_LOCATION ORDER BY city'));
}));

// ══════════════════════════════════════════════════════════════════════════════
//  HEALTH CHECK
// ══════════════════════════════════════════════════════════════════════════════

// Root route - serve index.html
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

app.get('/api/health', async (req, res) => {
  try {
    await query('SELECT 1');
    res.json({ status: 'ok', db: 'connected' });
  } catch (e) {
    res.status(503).json({ status: 'error', db: 'disconnected', error: e.message });
  }
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => console.log(`BloodBank API running on http://localhost:${PORT}`));
