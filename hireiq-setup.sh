#!/bin/bash
# HireIQ - Full Project Setup Script
# Paste this entire script into Replit Shell to build the project

set -e
echo "🚀 Setting up HireIQ..."

# ── Root package.json ──────────────────────────────────────────────
cat > package.json << 'PKGJSON'
{
  "name": "hireiq",
  "version": "1.0.0",
  "main": "server/index.js",
  "scripts": {
    "start": "node server/index.js",
    "dev": "concurrently \"nodemon server/index.js\" \"cd client && npm start\"",
    "build": "cd client && npm run build",
    "install-all": "npm install && cd client && npm install"
  },
  "dependencies": {
    "@anthropic-ai/sdk": "^0.24.0",
    "bcryptjs": "^2.4.3",
    "better-sqlite3": "^9.4.3",
    "connect-sqlite3": "^0.9.13",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "express-session": "^1.17.3",
    "multer": "^1.4.5-lts.1",
    "pdf-parse": "^1.1.1",
    "uuid": "^9.0.0"
  },
  "devDependencies": {
    "concurrently": "^8.2.2",
    "nodemon": "^3.1.0"
  }
}
PKGJSON

# ── .replit ────────────────────────────────────────────────────────
cat > .replit << 'REPLITCFG'
modules = ["nodejs-20", "web"]
run = "npm run start"

[nix]
channel = "stable-24_05"

[deployment]
run = ["sh", "-c", "npm run start"]
build = ["sh", "-c", "npm run build"]

[[ports]]
localPort = 5000
externalPort = 80

[env]
PORT = "5000"
NODE_ENV = "production"
REPLITCFG

# ── Directory structure ────────────────────────────────────────────
mkdir -p server/routes server/services
mkdir -p client/public client/src/components client/src/pages client/src/hooks client/src/utils

# ══════════════════════════════════════════════════════════════════
# SERVER FILES
# ══════════════════════════════════════════════════════════════════

# ── server/database.js ────────────────────────────────────────────
cat > server/database.js << 'EOF'
const Database = require('better-sqlite3');
const path = require('path');
const DB_PATH = path.join(__dirname, '../hireiq.db');
let db;
function getDb() {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    initializeSchema();
  }
  return db;
}
function initializeSchema() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL, company_name TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS jobs (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL, title TEXT NOT NULL,
      department TEXT, jd_content TEXT, status TEXT DEFAULT 'draft',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (user_id) REFERENCES users(id)
    );
    CREATE TABLE IF NOT EXISTS candidates (
      id TEXT PRIMARY KEY, job_id TEXT NOT NULL, name TEXT, email TEXT,
      phone TEXT, current_role TEXT, experience_years INTEGER,
      resume_text TEXT, resume_filename TEXT, stage TEXT DEFAULT 'applied',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (job_id) REFERENCES jobs(id)
    );
    CREATE TABLE IF NOT EXISTS resume_scores (
      id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL, job_id TEXT NOT NULL,
      fit_score INTEGER, fit_summary TEXT, strengths TEXT, concerns TEXT,
      recommended_action TEXT,
      FOREIGN KEY (candidate_id) REFERENCES candidates(id),
      FOREIGN KEY (job_id) REFERENCES jobs(id)
    );
    CREATE TABLE IF NOT EXISTS interviews (
      id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL, job_id TEXT NOT NULL,
      scheduled_datetime TEXT, interviewer_name TEXT, meeting_link TEXT,
      interview_round TEXT, email_content TEXT, email_sent INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (candidate_id) REFERENCES candidates(id),
      FOREIGN KEY (job_id) REFERENCES jobs(id)
    );
  `);
}
module.exports = { getDb };
EOF

# ── server/services/claude.js ─────────────────────────────────────
cat > server/services/claude.js << 'EOF'
const Anthropic = require('@anthropic-ai/sdk');
const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const MODEL = 'claude-sonnet-4-20250514';

async function generateJD({ title, department, responsibilities, must_have, nice_to_have, team_size, work_mode }) {
  const r = await client.messages.create({
    model: MODEL, max_tokens: 1500,
    messages: [{ role: 'user', content: `You are an expert HR professional. Create a compelling job description.
Job Title: ${title} | Department: ${department} | Work Mode: ${work_mode} | Team Size: ${team_size || 'N/A'}
Responsibilities: ${responsibilities}
Must-Have: ${must_have} | Nice-to-Have: ${nice_to_have}

Write a complete JD with sections: About the Role, What You'll Do (6-8 bullets), What We're Looking For, Why Join Us (3-4 culture bullets), Work Details. Make it human and genuine.` }]
  });
  return r.content[0].text;
}

async function screenResume(resumeText, jdContent, jobTitle) {
  const r = await client.messages.create({
    model: MODEL, max_tokens: 800,
    messages: [{ role: 'user', content: `You are an expert recruiter. Analyze this resume against the job description with human judgment, NOT keyword matching.

JOB: ${jobTitle}
JD: ${jdContent}
RESUME: ${resumeText.substring(0, 4000)}

Return ONLY valid JSON (no markdown):
{"name":"full name","email":"email or empty","current_role":"current title","experience_years":0,"fit_score":0,"fit_summary":"2 sentence assessment","strengths":["s1","s2","s3"],"concerns":["c1","c2"],"recommended_action":"Shortlist or Review Manually or Reject"}

Scoring: 80-100=strong fit, 60-79=good potential, 40-59=partial fit, <40=poor fit` }]
  });
  const text = r.content[0].text.trim().replace(/^```json|```$/g, '').trim();
  return JSON.parse(text);
}

async function generateInterviewEmail({ candidate_name, job_title, scheduled_datetime, interviewer_name, meeting_link, interview_round }) {
  const r = await client.messages.create({
    model: MODEL, max_tokens: 600,
    messages: [{ role: 'user', content: `Write a warm, professional interview invitation email body (no subject).
Candidate: ${candidate_name} | Role: ${job_title} | Round: ${interview_round}
Date/Time: ${scheduled_datetime} | Interviewer: ${interviewer_name} | Link: ${meeting_link}
Include all details. End with a friendly closing asking them to confirm or reach out with questions.` }]
  });
  return r.content[0].text;
}

module.exports = { generateJD, screenResume, generateInterviewEmail };
EOF

# ── server/routes/auth.js ─────────────────────────────────────────
cat > server/routes/auth.js << 'EOF'
const express = require('express');
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../database');
const router = express.Router();

router.post('/register', async (req, res) => {
  const { email, password, company_name } = req.body;
  if (!email || !password || !company_name) return res.status(400).json({ error: 'All fields required' });
  try {
    const db = getDb();
    if (db.prepare('SELECT id FROM users WHERE email=?').get(email)) return res.status(409).json({ error: 'Email already registered' });
    const id = uuidv4();
    db.prepare('INSERT INTO users (id,email,password_hash,company_name) VALUES (?,?,?,?)').run(id, email, await bcrypt.hash(password, 10), company_name);
    req.session.userId = id; req.session.companyName = company_name;
    res.json({ id, email, company_name });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

router.post('/login', async (req, res) => {
  const { email, password } = req.body;
  if (!email || !password) return res.status(400).json({ error: 'Email and password required' });
  try {
    const db = getDb();
    const user = db.prepare('SELECT * FROM users WHERE email=?').get(email);
    if (!user || !(await bcrypt.compare(password, user.password_hash))) return res.status(401).json({ error: 'Invalid credentials' });
    req.session.userId = user.id; req.session.companyName = user.company_name;
    res.json({ id: user.id, email: user.email, company_name: user.company_name });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

router.post('/logout', (req, res) => { req.session.destroy(); res.json({ message: 'Logged out' }); });

router.get('/me', (req, res) => {
  if (!req.session.userId) return res.status(401).json({ error: 'Not authenticated' });
  const user = getDb().prepare('SELECT id,email,company_name FROM users WHERE id=?').get(req.session.userId);
  res.json(user);
});

module.exports = router;
EOF

# ── server/routes/jobs.js ─────────────────────────────────────────
cat > server/routes/jobs.js << 'EOF'
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../database');
const { generateJD } = require('../services/claude');
const router = express.Router();
const auth = (req, res, next) => { if (!req.session.userId) return res.status(401).json({ error: 'Unauthorized' }); next(); };

router.get('/', auth, (req, res) => {
  const jobs = getDb().prepare(`SELECT j.*,COUNT(c.id) as candidate_count,AVG(rs.fit_score) as avg_score FROM jobs j LEFT JOIN candidates c ON c.job_id=j.id LEFT JOIN resume_scores rs ON rs.job_id=j.id WHERE j.user_id=? GROUP BY j.id ORDER BY j.created_at DESC`).all(req.session.userId);
  res.json(jobs);
});

router.get('/:id', auth, (req, res) => {
  const job = getDb().prepare('SELECT * FROM jobs WHERE id=? AND user_id=?').get(req.params.id, req.session.userId);
  if (!job) return res.status(404).json({ error: 'Not found' });
  res.json(job);
});

router.post('/generate-jd', auth, async (req, res) => {
  try { res.json({ jd: await generateJD(req.body) }); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

router.post('/', auth, (req, res) => {
  const { title, department, jd_content } = req.body;
  if (!title) return res.status(400).json({ error: 'Title required' });
  const id = uuidv4();
  getDb().prepare('INSERT INTO jobs (id,user_id,title,department,jd_content,status) VALUES (?,?,?,?,?,?)').run(id, req.session.userId, title, department, jd_content, 'draft');
  res.json(getDb().prepare('SELECT * FROM jobs WHERE id=?').get(id));
});

router.put('/:id', auth, (req, res) => {
  const { title, department, jd_content, status } = req.body;
  getDb().prepare('UPDATE jobs SET title=?,department=?,jd_content=?,status=? WHERE id=? AND user_id=?').run(title, department, jd_content, status, req.params.id, req.session.userId);
  res.json(getDb().prepare('SELECT * FROM jobs WHERE id=?').get(req.params.id));
});

router.delete('/:id', auth, (req, res) => {
  getDb().prepare('DELETE FROM jobs WHERE id=? AND user_id=?').run(req.params.id, req.session.userId);
  res.json({ message: 'Deleted' });
});

module.exports = router;
EOF

# ── server/routes/candidates.js ───────────────────────────────────
cat > server/routes/candidates.js << 'EOF'
const express = require('express');
const multer = require('multer');
const pdf = require('pdf-parse');
const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../database');
const { screenResume } = require('../services/claude');
const router = express.Router();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });
const auth = (req, res, next) => { if (!req.session.userId) return res.status(401).json({ error: 'Unauthorized' }); next(); };

router.get('/job/:jobId', auth, (req, res) => {
  const rows = getDb().prepare(`SELECT c.*,rs.fit_score,rs.fit_summary,rs.strengths,rs.concerns,rs.recommended_action FROM candidates c LEFT JOIN resume_scores rs ON rs.candidate_id=c.id WHERE c.job_id=? ORDER BY rs.fit_score DESC`).all(req.params.jobId);
  res.json(rows.map(c => ({ ...c, strengths: c.strengths ? JSON.parse(c.strengths) : [], concerns: c.concerns ? JSON.parse(c.concerns) : [] })));
});

router.get('/:id', auth, (req, res) => {
  const c = getDb().prepare(`SELECT c.*,rs.fit_score,rs.fit_summary,rs.strengths,rs.concerns,rs.recommended_action FROM candidates c LEFT JOIN resume_scores rs ON rs.candidate_id=c.id WHERE c.id=?`).get(req.params.id);
  if (!c) return res.status(404).json({ error: 'Not found' });
  res.json({ ...c, strengths: c.strengths ? JSON.parse(c.strengths) : [], concerns: c.concerns ? JSON.parse(c.concerns) : [] });
});

router.post('/upload/:jobId', auth, upload.array('resumes', 20), async (req, res) => {
  const db = getDb();
  const job = db.prepare('SELECT * FROM jobs WHERE id=?').get(req.params.jobId);
  if (!job) return res.status(404).json({ error: 'Job not found' });
  const results = [];
  for (const file of req.files) {
    try {
      const { text } = await pdf(file.buffer);
      const s = await screenResume(text, job.jd_content, job.title);
      const cid = uuidv4();
      db.prepare('INSERT INTO candidates (id,job_id,name,email,current_role,experience_years,resume_text,resume_filename,stage) VALUES (?,?,?,?,?,?,?,?,?)').run(cid, job.id, s.name||'Unknown', s.email||'', s.current_role||'', s.experience_years||0, text, file.originalname, 'applied');
      db.prepare('INSERT INTO resume_scores (id,candidate_id,job_id,fit_score,fit_summary,strengths,concerns,recommended_action) VALUES (?,?,?,?,?,?,?,?)').run(uuidv4(), cid, job.id, s.fit_score, s.fit_summary, JSON.stringify(s.strengths), JSON.stringify(s.concerns), s.recommended_action);
      results.push({ filename: file.originalname, candidate_id: cid, fit_score: s.fit_score, name: s.name });
    } catch (e) { results.push({ filename: file.originalname, error: e.message }); }
  }
  res.json({ processed: results });
});

router.patch('/:id/stage', auth, (req, res) => {
  const valid = ['applied','screened','shortlisted','interview_scheduled','offer'];
  if (!valid.includes(req.body.stage)) return res.status(400).json({ error: 'Invalid stage' });
  getDb().prepare('UPDATE candidates SET stage=? WHERE id=?').run(req.body.stage, req.params.id);
  res.json({ success: true });
});

module.exports = router;
EOF

# ── server/routes/interviews.js ───────────────────────────────────
cat > server/routes/interviews.js << 'EOF'
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../database');
const { generateInterviewEmail } = require('../services/claude');
const router = express.Router();
const auth = (req, res, next) => { if (!req.session.userId) return res.status(401).json({ error: 'Unauthorized' }); next(); };

router.get('/', auth, (req, res) => {
  res.json(getDb().prepare(`SELECT i.*,c.name as candidate_name,c.email as candidate_email,j.title as job_title FROM interviews i JOIN candidates c ON c.id=i.candidate_id JOIN jobs j ON j.id=i.job_id WHERE j.user_id=? ORDER BY i.scheduled_datetime ASC`).all(req.session.userId));
});

router.post('/generate-email', auth, async (req, res) => {
  try { res.json({ email: await generateInterviewEmail(req.body) }); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

router.post('/', auth, (req, res) => {
  const { candidate_id, job_id, scheduled_datetime, interviewer_name, meeting_link, interview_round, email_content } = req.body;
  const id = uuidv4();
  getDb().prepare('INSERT INTO interviews (id,candidate_id,job_id,scheduled_datetime,interviewer_name,meeting_link,interview_round,email_content,email_sent) VALUES (?,?,?,?,?,?,?,?,1)').run(id, candidate_id, job_id, scheduled_datetime, interviewer_name, meeting_link, interview_round, email_content);
  getDb().prepare("UPDATE candidates SET stage='interview_scheduled' WHERE id=?").run(candidate_id);
  res.json(getDb().prepare('SELECT * FROM interviews WHERE id=?').get(id));
});

module.exports = router;
EOF

# ── server/routes/dashboard.js ────────────────────────────────────
cat > server/routes/dashboard.js << 'EOF'
const express = require('express');
const { getDb } = require('../database');
const router = express.Router();
const auth = (req, res, next) => { if (!req.session.userId) return res.status(401).json({ error: 'Unauthorized' }); next(); };

router.get('/', auth, (req, res) => {
  const db = getDb(); const uid = req.session.userId;
  res.json({
    stats: {
      total_jobs: db.prepare("SELECT COUNT(*) as c FROM jobs WHERE user_id=?").get(uid).c,
      candidates_this_month: db.prepare("SELECT COUNT(*) as c FROM candidates c JOIN jobs j ON j.id=c.job_id WHERE j.user_id=? AND c.created_at>=date('now','-30 days')").get(uid).c,
      interviews_this_week: db.prepare("SELECT COUNT(*) as c FROM interviews i JOIN jobs j ON j.id=i.job_id WHERE j.user_id=? AND i.scheduled_datetime>=date('now') AND i.scheduled_datetime<=date('now','+7 days')").get(uid).c,
      avg_fit_score: Math.round(db.prepare("SELECT AVG(rs.fit_score) as a FROM resume_scores rs JOIN jobs j ON j.id=rs.job_id WHERE j.user_id=?").get(uid).a || 0)
    },
    recent_jobs: db.prepare("SELECT j.*,COUNT(c.id) as candidate_count,MAX(rs.fit_score) as top_score FROM jobs j LEFT JOIN candidates c ON c.job_id=j.id LEFT JOIN resume_scores rs ON rs.job_id=j.id WHERE j.user_id=? GROUP BY j.id ORDER BY j.created_at DESC LIMIT 5").all(uid),
    upcoming_interviews: db.prepare("SELECT i.*,c.name as candidate_name,j.title as job_title FROM interviews i JOIN candidates c ON c.id=i.candidate_id JOIN jobs j ON j.id=i.job_id WHERE j.user_id=? AND i.scheduled_datetime>=date('now') ORDER BY i.scheduled_datetime ASC LIMIT 5").all(uid)
  });
});

module.exports = router;
EOF

# ── server/index.js ───────────────────────────────────────────────
cat > server/index.js << 'EOF'
const express = require('express');
const session = require('express-session');
const cors = require('cors');
const path = require('path');
const SQLiteStore = require('connect-sqlite3')(session);
const app = express();
const PORT = process.env.PORT || 5000;

app.use(cors({ origin: true, credentials: true }));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(session({
  store: new SQLiteStore({ db: 'sessions.db', dir: './' }),
  secret: process.env.SESSION_SECRET || 'hireiq-secret-2025',
  resave: false, saveUninitialized: false,
  cookie: { secure: false, httpOnly: true, maxAge: 7 * 24 * 60 * 60 * 1000 }
}));

app.use('/api/auth', require('./routes/auth'));
app.use('/api/jobs', require('./routes/jobs'));
app.use('/api/candidates', require('./routes/candidates'));
app.use('/api/interviews', require('./routes/interviews'));
app.use('/api/dashboard', require('./routes/dashboard'));

app.use(express.static(path.join(__dirname, '../client/build')));
app.get('*', (req, res) => res.sendFile(path.join(__dirname, '../client/build/index.html')));

app.listen(PORT, '0.0.0.0', () => console.log(`✅ HireIQ running on port ${PORT}`));
EOF

# ══════════════════════════════════════════════════════════════════
# CLIENT FILES
# ══════════════════════════════════════════════════════════════════

# ── client/package.json ───────────────────────────────────────────
cat > client/package.json << 'EOF'
{
  "name": "hireiq-client",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-router-dom": "^6.22.0",
    "react-scripts": "5.0.1",
    "axios": "^1.6.7",
    "react-hot-toast": "^2.4.1",
    "lucide-react": "^0.363.0",
    "date-fns": "^3.3.1"
  },
  "scripts": {
    "start": "PORT=3000 react-scripts start",
    "build": "react-scripts build"
  },
  "proxy": "http://localhost:5000",
  "browserslist": { "production": [">0.2%","not dead"], "development": ["last 1 chrome version"] }
}
EOF

# ── client/public/index.html ──────────────────────────────────────
cat > client/public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>HireIQ — AI Recruitment Assistant</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;500;600;700;800&family=DM+Sans:wght@300;400;500;600&display=swap" rel="stylesheet">
</head>
<body><div id="root"></div></body>
</html>
EOF

# ── client/src/utils/api.js ───────────────────────────────────────
cat > client/src/utils/api.js << 'EOF'
import axios from 'axios';
const api = axios.create({ baseURL: '/api', withCredentials: true });
api.interceptors.response.use(res => res, err => {
  if (err.response?.status === 401) window.location.href = '/login';
  return Promise.reject(err);
});
export default api;
EOF

# ── client/src/hooks/useAuth.js ───────────────────────────────────
cat > client/src/hooks/useAuth.js << 'EOF'
import { createContext, useContext, useState, useEffect } from 'react';
import api from '../utils/api';
const AuthContext = createContext(null);
export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => { api.get('/auth/me').then(r => setUser(r.data)).catch(() => setUser(null)).finally(() => setLoading(false)); }, []);
  const login = async (email, password) => { const r = await api.post('/auth/login', { email, password }); setUser(r.data); return r.data; };
  const register = async (email, password, company_name) => { const r = await api.post('/auth/register', { email, password, company_name }); setUser(r.data); return r.data; };
  const logout = async () => { await api.post('/auth/logout'); setUser(null); };
  return <AuthContext.Provider value={{ user, loading, login, register, logout }}>{children}</AuthContext.Provider>;
}
export const useAuth = () => useContext(AuthContext);
EOF

# ── client/src/index.js ───────────────────────────────────────────
cat > client/src/index.js << 'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import './index.css';
import App from './App';
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
EOF

# ── client/src/App.js ─────────────────────────────────────────────
cat > client/src/App.js << 'EOF'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { Toaster } from 'react-hot-toast';
import { AuthProvider, useAuth } from './hooks/useAuth';
import Layout from './components/Layout';
import Login from './pages/Login';
import Register from './pages/Register';
import Dashboard from './pages/Dashboard';
import Jobs from './pages/Jobs';
import NewJob from './pages/NewJob';
import JobDetail from './pages/JobDetail';
import CandidateProfile from './pages/CandidateProfile';
import Interviews from './pages/Interviews';

function ProtectedRoute({ children }) {
  const { user, loading } = useAuth();
  if (loading) return <div style={{display:'flex',alignItems:'center',justifyContent:'center',height:'100vh'}}><div className="spinner spinner-dark"></div></div>;
  return user ? children : <Navigate to="/login" replace />;
}
function PublicRoute({ children }) {
  const { user, loading } = useAuth();
  if (loading) return null;
  return !user ? children : <Navigate to="/dashboard" replace />;
}
export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Toaster position="top-right" toastOptions={{ duration: 3000, style: { fontFamily: 'DM Sans, sans-serif', fontSize: '14px' } }} />
        <Routes>
          <Route path="/login" element={<PublicRoute><Login /></PublicRoute>} />
          <Route path="/register" element={<PublicRoute><Register /></PublicRoute>} />
          <Route path="/" element={<ProtectedRoute><Layout /></ProtectedRoute>}>
            <Route index element={<Navigate to="/dashboard" replace />} />
            <Route path="dashboard" element={<Dashboard />} />
            <Route path="jobs" element={<Jobs />} />
            <Route path="jobs/new" element={<NewJob />} />
            <Route path="jobs/:id" element={<JobDetail />} />
            <Route path="candidates/:id" element={<CandidateProfile />} />
            <Route path="interviews" element={<Interviews />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}
EOF

echo "✅ All files created!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NEXT: Add ANTHROPIC_API_KEY to Secrets tab"
echo "THEN run: npm run install-all && npm run build && npm start"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Write large page files via Node to avoid heredoc escaping issues ──
node << 'NODESCRIPT'
const fs = require('fs');
const path = require('path');

const files = {};

files['client/src/index.css'] = fs.readFileSync('/home/claude/hireiq/client/src/index.css', 'utf8');
files['client/src/components/Layout.js'] = fs.readFileSync('/home/claude/hireiq/client/src/components/Layout.js', 'utf8');
files['client/src/pages/Login.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/Login.js', 'utf8');
files['client/src/pages/Register.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/Register.js', 'utf8');
files['client/src/pages/Dashboard.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/Dashboard.js', 'utf8');
files['client/src/pages/Jobs.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/Jobs.js', 'utf8');
files['client/src/pages/NewJob.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/NewJob.js', 'utf8');
files['client/src/pages/JobDetail.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/JobDetail.js', 'utf8');
files['client/src/pages/CandidateProfile.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/CandidateProfile.js', 'utf8');
files['client/src/pages/Interviews.js'] = fs.readFileSync('/home/claude/hireiq/client/src/pages/Interviews.js', 'utf8');

for (const [filePath, content] of Object.entries(files)) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
  console.log('✅ Written:', filePath);
}
NODESCRIPT

echo ""
echo "🎉 HireIQ fully set up!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Add ANTHROPIC_API_KEY in Secrets tab 🔒"
echo "2. Run: npm run install-all && npm run build && npm start"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
