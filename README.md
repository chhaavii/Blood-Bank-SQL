# 🩸 BloodBank.io — Full Stack Blood Management System

A production-grade blood bank management system with an Express.js backend API and a rich, interactive frontend.

---

## 📁 Project Structure

```
bloodbank/
├── server.js       ← Express API backend
├── index.html      ← Frontend (open in browser)
├── package.json
└── README.md
```

---

## 🚀 Setup Instructions

### 1. MySQL Database
```bash
mysql -u root -p < bloodbank.sql
```
This creates the `BloodBankDB` database with all tables, triggers, procedures, functions, and sample data.

### 2. Configure DB credentials (if needed)
Edit `server.js` top section, or use environment variables:
```bash
export DB_HOST=localhost
export DB_USER=root
export DB_PASS=yourpassword
```

### 3. Install & Start Backend
```bash
cd bloodbank
npm install
node server.js
```
Server runs at **http://localhost:3001**

### 4. Open Frontend
With `npm start` running, open your browser and navigate to:
```
http://localhost:3001
```
The Express server now serves `index.html` automatically, so the frontend and backend are fully connected on the same origin.

---

## 🔌 API Endpoints

### Dashboard
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stats` | All dashboard statistics |
| GET | `/api/stats/blood-groups` | Available units by blood group |
| GET | `/api/stats/stock-levels` | Stock levels by bank |

### Donors
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/donors` | All donors with tier & rewards |
| GET | `/api/donors/:id` | Single donor profile + history |
| POST | `/api/donors` | Register new donor |

### Donations
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/donations` | All donations |
| POST | `/api/donations` | Record donation → **triggers `after_donation_insert`** auto-creates blood unit |

### Blood Units
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/blood-units` | All units (filterable by status/blood_group) |
| GET | `/api/blood-units/expiring-soon` | Units expiring within 7 days |

### Requests
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/requests` | All requests with priority |
| POST | `/api/requests` | New request → **triggers `before_request_insert` + `after_request_insert`** |

### Stored Procedures
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/procedures/emergency-request` | `Process_Emergency_Request()` |
| POST | `/api/procedures/redistribute` | `Redistribute_Stock_Between_Banks()` |
| POST | `/api/procedures/expire-units` | `Auto_Remove_Expiring_Units()` |
| POST | `/api/procedures/reward-donor` | `Reward_Active_Donor()` |
| POST | `/api/procedures/donation-drive` | `Schedule_Donation_Drive()` |

### Other
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/compatibility?donor=X&recipient=Y` | Check compatibility + available units |
| GET | `/api/compatibility/matrix` | Full compatibility matrix |
| GET | `/api/banks/:id/stock` | Stock levels per blood group for a bank |
| POST | `/api/temperature-logs` | Log temperature → auto-alerts if out of 2–6°C range |
| GET | `/api/notifications` | All notification logs |

---

## ⚡ DB Triggers in Action

| Trigger | When | Effect |
|---------|------|--------|
| `after_donation_insert` | POST /api/donations | Auto-creates BLOOD_UNIT (42-day expiry) |
| `before_request_insert` | POST /api/requests | Auto-sets status to Completed/Pending |
| `after_request_insert` | POST /api/requests | Marks N units as Used (FEFO policy) |
| `emergency_match` | POST /api/procedures/emergency-request | Logs notification |

---

## 🧬 DB Functions Used

- `fn_Days_To_Expiry(unit_id)` — days remaining
- `fn_Critical_Stock_Level(bank_id, blood_group)` — SAFE/LOW/CRITICAL
- `fn_Donor_Loyalty_Tier(donor_id)` — New/Regular/Hero/Lifesaver
- `fn_Request_Priority(request_id)` — Normal/Urgent/Emergency
- `fn_Is_Compatible(donor, recipient)` — Compatible/Not Compatible
