#!/bin/bash
# =============================================================
# ATHER REGISTER — Deploy Script
# Run as root on AEGServitorOptiplex
# Creates CT 103 (Supabase) and CT 104 (React frontend)
# Wires both into CT 100 (Nginx reverse proxy)
# =============================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# =============================================================
# CONFIGURATION — edit these if needed
# =============================================================
TEMPLATE="Main-Storage:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"
GATEWAY="192.168.1.1"
SUBNET="192.168.1.0/24"

CT_SUPABASE=103
IP_SUPABASE="192.168.1.103"

CT_FRONTEND=104
IP_FRONTEND="192.168.1.104"

CT_PROXY=100

DOMAIN="register.aetherguild.org"

# =============================================================
echo ""
echo "=================================================="
echo "  ATHER REGISTER — Infrastructure Deploy"
echo "=================================================="
echo ""

# =============================================================
# STEP 0 — Preflight checks
# =============================================================
info "Running preflight checks..."

# Must run on Optiplex
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" != "AEGServitorOptiplex" ]]; then
    warn "This script should run on AEGServitorOptiplex. Current host: $HOSTNAME"
    read -p "Continue anyway? (y/N): " confirm
    [[ "$confirm" == "y" ]] || fail "Aborted."
fi

# Check template exists
pvesm list Main-Storage | grep -q "debian-12-standard_12.12-1" || \
    fail "Template not found. Run: pveam download Main-Storage debian-12-standard_12.12-1_amd64.tar.zst"

# Check CTs don't already exist
pct status $CT_SUPABASE &>/dev/null && fail "CT $CT_SUPABASE already exists. Remove it first with: pct destroy $CT_SUPABASE"
pct status $CT_FRONTEND &>/dev/null && fail "CT $CT_FRONTEND already exists. Remove it first with: pct destroy $CT_FRONTEND"

log "Preflight checks passed"

# =============================================================
# STEP 1 — NAT fix on Optiplex host (idempotent)
# =============================================================
info "Checking NAT/bridge config on host..."

if ! iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE"; then
    info "Applying NAT fix..."
    modprobe br_netfilter
    echo 'net.bridge.bridge-nf-call-iptables=1' >> /etc/sysctl.d/99-bridge.conf
    sysctl -p /etc/sysctl.d/99-bridge.conf
    iptables -t nat -A POSTROUTING -s $SUBNET ! -d $SUBNET -j MASQUERADE
    apt-get install -y netfilter-persistent iptables-persistent
    netfilter-persistent save
    log "NAT fix applied and persisted"
else
    log "NAT fix already in place"
fi

# =============================================================
# STEP 2 — Create CT 103 (Supabase)
# =============================================================
info "Creating CT $CT_SUPABASE (Supabase) at $IP_SUPABASE..."

pct create $CT_SUPABASE $TEMPLATE \
    --hostname supabase \
    --memory 4096 \
    --cores 2 \
    --rootfs $STORAGE:32 \
    --net0 name=eth0,bridge=vmbr0,ip=${IP_SUPABASE}/24,gw=$GATEWAY \
    --unprivileged 0 \
    --features nesting=1 \
    --start 1

log "CT $CT_SUPABASE created and started"

info "Waiting for CT $CT_SUPABASE to boot..."
sleep 8

# =============================================================
# STEP 3 — Install Supabase in CT 103
# =============================================================
info "Installing dependencies in CT $CT_SUPABASE..."

pct exec $CT_SUPABASE -- bash -c "
    set -e
    apt-get update -qq
    apt-get install -y curl git docker.io docker-compose openssl
    systemctl enable docker
    systemctl start docker
"
log "Dependencies installed in CT $CT_SUPABASE"

info "Cloning Supabase..."
pct exec $CT_SUPABASE -- bash -c "
    set -e
    git clone --depth 1 https://github.com/supabase/supabase /opt/supabase
    cd /opt/supabase/docker
    cp .env.example .env
"
log "Supabase cloned"

info "Generating credentials..."

# Generate secrets on the host, inject into container
POSTGRES_PASSWORD=$(openssl rand -hex 20)
JWT_SECRET=$(openssl rand -hex 32)

# Generate Supabase JWTs (using Python since it's available on Debian)
ANON_KEY=$(pct exec $CT_SUPABASE -- bash -c "
    python3 -c \"
import json, base64, hmac, hashlib, time

def b64url(s):
    return base64.urlsafe_b64encode(s).rstrip(b'=').decode()

header = b64url(json.dumps({'alg':'HS256','typ':'JWT'}).encode())
payload = b64url(json.dumps({'role':'anon','iss':'supabase','iat':int(time.time()),'exp':int(time.time())+315360000}).encode())
sig = b64url(hmac.new('${JWT_SECRET}'.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
print(f'{header}.{payload}.{sig}')
\"
")

SERVICE_KEY=$(pct exec $CT_SUPABASE -- bash -c "
    python3 -c \"
import json, base64, hmac, hashlib, time

def b64url(s):
    return base64.urlsafe_b64encode(s).rstrip(b'=').decode()

header = b64url(json.dumps({'alg':'HS256','typ':'JWT'}).encode())
payload = b64url(json.dumps({'role':'service_role','iss':'supabase','iat':int(time.time()),'exp':int(time.time())+315360000}).encode())
sig = b64url(hmac.new('${JWT_SECRET}'.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
print(f'{header}.{payload}.{sig}')
\"
")

log "Credentials generated"

# Write credentials file to Optiplex for safekeeping
cat > /root/ather-register-credentials.txt << EOF
# ATHER REGISTER — Supabase Credentials
# Generated: $(date)
# KEEP THIS FILE SAFE

SUPABASE_URL=http://${IP_SUPABASE}:8000
PUBLIC_URL=https://${DOMAIN}

POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_KEY}
EOF
chmod 600 /root/ather-register-credentials.txt
log "Credentials saved to /root/ather-register-credentials.txt"

# Inject credentials into Supabase .env
pct exec $CT_SUPABASE -- bash -c "
    set -e
    cd /opt/supabase/docker
    sed -i 's|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|' .env
    sed -i 's|JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|' .env
    sed -i 's|ANON_KEY=.*|ANON_KEY=${ANON_KEY}|' .env
    sed -i 's|SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_KEY}|' .env
    sed -i 's|SITE_URL=.*|SITE_URL=https://${DOMAIN}|' .env
    sed -i 's|API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://${DOMAIN}|' .env
"
log "Supabase .env configured"

info "Starting Supabase (this takes 2-3 minutes)..."
pct exec $CT_SUPABASE -- bash -c "
    cd /opt/supabase/docker
    docker-compose up -d
"

# Wait for Supabase to be healthy
info "Waiting for Supabase to become healthy..."
for i in {1..30}; do
    STATUS=$(pct exec $CT_SUPABASE -- bash -c "
        curl -sf http://localhost:8000/rest/v1/ \
        -H 'apikey: ${ANON_KEY}' \
        -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000
    ")
    if [[ "$STATUS" == "200" ]]; then
        log "Supabase is healthy"
        break
    fi
    if [[ $i -eq 30 ]]; then
        fail "Supabase didn't start after 5 minutes. Check: pct enter $CT_SUPABASE && cd /opt/supabase/docker && docker-compose ps"
    fi
    echo -n "."
    sleep 10
done

# =============================================================
# STEP 4 — Run database schema
# =============================================================
info "Running database schema..."

pct exec $CT_SUPABASE -- bash -c "
docker exec supabase-db-1 psql -U postgres -d postgres << 'SQLEOF'
CREATE EXTENSION IF NOT EXISTS postgis;

DO \$\$ BEGIN
    CREATE TYPE phenomenon_type AS ENUM ('residual_haunting','intelligent_haunting','cryptid','extraterrestrial','psychic','physical_anomaly','evp_audio','other');
EXCEPTION WHEN duplicate_object THEN NULL;
END \$\$;

DO \$\$ BEGIN
    CREATE TYPE privacy_level AS ENUM ('public','community','confidential','private');
EXCEPTION WHEN duplicate_object THEN NULL;
END \$\$;

CREATE TABLE IF NOT EXISTS reports (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at                  timestamptz NOT NULL DEFAULT now(),
    phenomenon_type             phenomenon_type NOT NULL DEFAULT 'other',
    lat                         double precision,
    lng                         double precision,
    location_display            text,
    occurred_at                 timestamptz,
    title                       text NOT NULL,
    description                 text,
    privacy_level               privacy_level NOT NULL DEFAULT 'public',
    reporter_name               text,
    reporter_email              text,
    environment                 jsonb,
    sensor_data                 jsonb,
    duration_minutes            integer,
    physical_sensations         text,
    prior_experiences           text,
    mundane_explanations        text,
    media_urls                  text[],
    credibility_score           float,
    verified_scientist_endorsed boolean DEFAULT false,
    device_id                   text
);

CREATE INDEX IF NOT EXISTS idx_reports_type     ON reports (phenomenon_type);
CREATE INDEX IF NOT EXISTS idx_reports_privacy  ON reports (privacy_level);
CREATE INDEX IF NOT EXISTS idx_reports_created  ON reports (created_at DESC);

ALTER TABLE reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS \"Public reports readable by all\" ON reports;
CREATE POLICY \"Public reports readable by all\" ON reports FOR SELECT USING (privacy_level = 'public');

DROP POLICY IF EXISTS \"Anyone can submit\" ON reports;
CREATE POLICY \"Anyone can submit\" ON reports FOR INSERT WITH CHECK (true);

INSERT INTO reports (phenomenon_type, title, description, lat, lng, location_display, occurred_at, privacy_level) VALUES
('intelligent_haunting','Repeated knocking in empty hallway','Three-knock pattern heard three nights in a row between 2-3am. No structural explanation found.',51.5074,-0.1278,'London, UK',now() - interval '3 days','public'),
('evp_audio','Unexplained voice on recorder','Digital recorder captured a clear female voice in an empty room. No one else present.',40.7128,-74.006,'New York, NY',now() - interval '7 days','public'),
('cryptid','Large bipedal figure in tree line','Estimated 7-8 feet tall. Moved with unusual gait before disappearing.',47.6062,-122.3321,'Pacific Northwest, WA',now() - interval '14 days','public'),
('extraterrestrial','Silent triangular craft, low altitude','Three white lights, stationary 4 minutes then instant acceleration.',35.0853,-106.6056,'Albuquerque, NM',now() - interval '2 days','public'),
('residual_haunting','Victorian woman apparition, same location daily','Seen by multiple staff at 6:47pm daily. Always same path, no interaction.',53.4808,-2.2426,'Manchester, UK',now() - interval '30 days','public'),
('physical_anomaly','Objects displaced overnight, locked building','14 items moved to geometric arrangement. Reproduced three times.',37.7749,-122.4194,'San Francisco, CA',now() - interval '5 days','public')
ON CONFLICT DO NOTHING;
SQLEOF
"
log "Database schema applied with seed data"

# =============================================================
# STEP 5 — Create CT 104 (React frontend)
# =============================================================
info "Creating CT $CT_FRONTEND (React frontend) at $IP_FRONTEND..."

pct create $CT_FRONTEND $TEMPLATE \
    --hostname ather-register \
    --memory 1024 \
    --cores 1 \
    --rootfs $STORAGE:8 \
    --net0 name=eth0,bridge=vmbr0,ip=${IP_FRONTEND}/24,gw=$GATEWAY \
    --unprivileged 1 \
    --start 1

log "CT $CT_FRONTEND created and started"
sleep 8

info "Installing Node.js and Nginx in CT $CT_FRONTEND..."
pct exec $CT_FRONTEND -- bash -c "
    set -e
    apt-get update -qq
    apt-get install -y nginx curl
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
"
log "Node.js and Nginx installed in CT $CT_FRONTEND"

info "Setting up React project..."
pct exec $CT_FRONTEND -- bash -c "
    set -e
    mkdir -p /opt/ather-register
    cd /opt/ather-register
    npm create vite@latest . -- --template react --yes 2>/dev/null || true
    npm install
    npm install leaflet
"
log "React project created"

# Write the App.jsx (main component) into CT 104
info "Writing frontend component..."
pct exec $CT_FRONTEND -- bash -c "cat > /opt/ather-register/src/App.jsx << 'APPEOF'
import { useState, useEffect, useRef } from 'react';

const SUPABASE_URL = 'http://${IP_SUPABASE}:8000';
const SUPABASE_ANON_KEY = '${ANON_KEY}';

const PHENOMENON_TYPES = [
  { id: 'residual_haunting',   label: 'Residual Haunting',           color: '#7C6FCD' },
  { id: 'intelligent_haunting',label: 'Intelligent Haunting',         color: '#C062A0' },
  { id: 'cryptid',             label: 'Cryptid',                      color: '#5A9E6A' },
  { id: 'extraterrestrial',    label: 'Extraterrestrial',             color: '#3A8FCC' },
  { id: 'psychic',             label: 'Psychic / Anomalous Cognition',color: '#A67CC5' },
  { id: 'physical_anomaly',    label: 'Physical Anomaly',             color: '#C09A3A' },
  { id: 'evp_audio',           label: 'EVP / Audio Anomaly',          color: '#5AABAA' },
  { id: 'other',               label: 'Other / Unclassified',         color: '#888880' },
];

const MAP_STYLES = [
  { id: 'dark',      label: 'Dark',      url: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png' },
  { id: 'satellite', label: 'Satellite', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}' },
  { id: 'light',     label: 'Light',     url: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png' },
  { id: 'terrain',   label: 'Terrain',   url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png' },
];

const PRIVACY_LEVELS = [
  { id: 'public',       label: 'Public',       desc: 'Visible to everyone' },
  { id: 'community',    label: 'Community',    desc: 'Registered users only' },
  { id: 'confidential', label: 'Confidential', desc: 'Location obscured, researchers only' },
  { id: 'private',      label: 'Private',      desc: 'Ather Guild researchers only' },
];

function getPh(id) { return PHENOMENON_TYPES.find(p => p.id === id) || PHENOMENON_TYPES[7]; }

export default function AtherRegister() {
  const mapRef      = useRef(null);
  const leafletMap  = useRef(null);
  const tileLayer   = useRef(null);
  const markersRef  = useRef([]);

  const [mapReady,       setMapReady]       = useState(false);
  const [mapStyle,       setMapStyle]       = useState('dark');
  const [reports,        setReports]        = useState([]);
  const [selected,       setSelected]       = useState(null);
  const [filterType,     setFilterType]     = useState(null);
  const [showForm,       setShowForm]       = useState(false);
  const [formMode,       setFormMode]       = useState('quick');
  const [submitting,     setSubmitting]     = useState(false);
  const [submitSuccess,  setSubmitSuccess]  = useState(false);
  const [locating,       setLocating]       = useState(false);

  const [form, setForm] = useState({
    phenomenon_type: 'other', title: '', description: '',
    occurred_at: new Date().toISOString().slice(0,16),
    privacy_level: 'public', reporter_name: '', reporter_email: '',
    lat: null, lng: null, location_display: '',
    environment: {}, duration_minutes: '',
    physical_sensations: '', prior_experiences: '', mundane_explanations: '',
  });

  const setField = (k, v) => setForm(f => ({ ...f, [k]: v }));
  const resetForm = () => {
    setForm({ phenomenon_type: 'other', title: '', description: '', occurred_at: new Date().toISOString().slice(0,16), privacy_level: 'public', reporter_name: '', reporter_email: '', lat: null, lng: null, location_display: '', environment: {}, duration_minutes: '', physical_sensations: '', prior_experiences: '', mundane_explanations: '' });
    setFormMode('quick');
  };

  useEffect(() => {
    const css = document.createElement('link');
    css.rel = 'stylesheet';
    css.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
    document.head.appendChild(css);
    const script = document.createElement('script');
    script.src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
    script.onload = () => setMapReady(true);
    document.head.appendChild(script);
  }, []);

  useEffect(() => {
    if (!mapReady || !mapRef.current || leafletMap.current) return;
    const L = window.L;
    const map = L.map(mapRef.current, { center: [30, 0], zoom: 2, zoomControl: false });
    L.control.zoom({ position: 'bottomright' }).addTo(map);
    tileLayer.current = L.tileLayer(MAP_STYLES[0].url, { maxZoom: 19 }).addTo(map);
    map.on('click', e => {
      setField('lat', parseFloat(e.latlng.lat.toFixed(5)));
      setField('lng', parseFloat(e.latlng.lng.toFixed(5)));
      setField('location_display', e.latlng.lat.toFixed(4) + ', ' + e.latlng.lng.toFixed(4));
      setShowForm(true);
    });
    leafletMap.current = map;
  }, [mapReady]);

  useEffect(() => {
    if (!mapReady || !leafletMap.current) return;
    const style = MAP_STYLES.find(s => s.id === mapStyle);
    if (tileLayer.current) leafletMap.current.removeLayer(tileLayer.current);
    tileLayer.current = window.L.tileLayer(style.url, { maxZoom: 19 }).addTo(leafletMap.current);
  }, [mapStyle, mapReady]);

  useEffect(() => {
    if (!mapReady || !leafletMap.current) return;
    const L = window.L;
    markersRef.current.forEach(m => leafletMap.current.removeLayer(m));
    markersRef.current = [];
    const filtered = filterType ? reports.filter(r => r.phenomenon_type === filterType) : reports;
    filtered.forEach(r => {
      if (!r.lat || !r.lng) return;
      const ph = getPh(r.phenomenon_type);
      const el = document.createElement('div');
      el.style.cssText = 'width:13px;height:13px;border-radius:50%;background:' + ph.color + ';border:1.5px solid rgba(255,255,255,0.4);cursor:pointer;box-shadow:0 0 7px ' + ph.color + '99;';
      const marker = L.marker([r.lat, r.lng], {
        icon: L.divIcon({ html: el.outerHTML, className: '', iconSize: [13,13], iconAnchor: [6,6] })
      }).addTo(leafletMap.current);
      marker.on('click', () => setSelected(r));
      markersRef.current.push(marker);
    });
  }, [reports, filterType, mapReady]);

  useEffect(() => {
    fetch(SUPABASE_URL + '/rest/v1/reports?select=*&privacy_level=eq.public&order=created_at.desc&limit=500', {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY }
    }).then(r => r.json()).then(setReports).catch(console.error);
  }, []);

  const getGPS = () => {
    setLocating(true);
    navigator.geolocation?.getCurrentPosition(pos => {
      const lat = parseFloat(pos.coords.latitude.toFixed(5));
      const lng = parseFloat(pos.coords.longitude.toFixed(5));
      setField('lat', lat); setField('lng', lng);
      setField('location_display', lat + ', ' + lng);
      leafletMap.current?.setView([lat, lng], 13);
      setLocating(false);
    }, () => setLocating(false));
  };

  const handleSubmit = async () => {
    if (!form.title) return;
    setSubmitting(true);
    try {
      const res = await fetch(SUPABASE_URL + '/rest/v1/reports', {
        method: 'POST',
        headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY, 'Content-Type': 'application/json', Prefer: 'return=representation' },
        body: JSON.stringify({ ...form, duration_minutes: form.duration_minutes ? parseInt(form.duration_minutes) : null }),
      });
      const data = await res.json();
      if (data && data[0]) setReports(prev => [data[0], ...prev]);
      setSubmitSuccess(true);
      setTimeout(() => { setShowForm(false); setSubmitSuccess(false); resetForm(); }, 2000);
    } catch(e) { alert('Submission failed.'); }
    finally { setSubmitting(false); }
  };

  const S = { input: { width:'100%', background:'rgba(255,255,255,0.05)', border:'0.5px solid rgba(255,255,255,0.15)', borderRadius:6, color:'#e8e8f0', padding:'7px 10px', fontSize:13, boxSizing:'border-box', outline:'none', marginBottom:10 }, label: { color:'rgba(255,255,255,0.45)', fontSize:10, textTransform:'uppercase', letterSpacing:'0.07em', display:'block', marginBottom:4 } };

  return (
    <div style={{ position:'fixed', inset:0, background:'#0d0d12', fontFamily:'system-ui,sans-serif' }}>
      <div ref={mapRef} style={{ position:'absolute', inset:0 }} />

      <div style={{ position:'absolute', top:12, left:12, zIndex:1000, background:'rgba(10,10,18,0.92)', border:'0.5px solid rgba(255,255,255,0.12)', borderRadius:8, padding:'8px 14px', display:'flex', alignItems:'center', gap:10 }}>
        <div style={{ width:8, height:8, borderRadius:'50%', background:'#7C6FCD', boxShadow:'0 0 8px #7C6FCD' }} />
        <span style={{ color:'#e8e8f0', fontWeight:600, fontSize:15 }}>Ather Register</span>
        <span style={{ color:'rgba(255,255,255,0.3)', fontSize:12 }}>{filterType ? reports.filter(r=>r.phenomenon_type===filterType).length : reports.length} reports</span>
      </div>

      <div style={{ position:'absolute', top:12, right:12, zIndex:1000, display:'flex', gap:5 }}>
        {MAP_STYLES.map(s => (
          <button key={s.id} onClick={() => setMapStyle(s.id)} style={{ background: mapStyle===s.id ? 'rgba(124,111,205,0.9)' : 'rgba(10,10,18,0.85)', border:'0.5px solid rgba(255,255,255,0.15)', color: mapStyle===s.id ? '#fff' : 'rgba(255,255,255,0.55)', padding:'5px 10px', borderRadius:5, cursor:'pointer', fontSize:11, fontWeight: mapStyle===s.id ? 600 : 400 }}>{s.label}</button>
        ))}
      </div>

      <div style={{ position:'absolute', bottom:48, left:12, zIndex:1000, background:'rgba(10,10,18,0.9)', border:'0.5px solid rgba(255,255,255,0.1)', borderRadius:8, padding:'7px 6px' }}>
        {PHENOMENON_TYPES.map(ph => (
          <button key={ph.id} onClick={() => setFilterType(filterType===ph.id ? null : ph.id)} style={{ display:'flex', alignItems:'center', gap:6, padding:'4px 8px', borderRadius:5, cursor:'pointer', border: filterType===ph.id ? '0.5px solid '+ph.color+'55' : '0.5px solid transparent', background: filterType===ph.id ? ph.color+'18' : 'transparent', width:'100%' }}>
            <div style={{ width:7, height:7, borderRadius:'50%', background:ph.color, flexShrink:0, boxShadow:'0 0 4px '+ph.color }} />
            <span style={{ fontSize:11, color: filterType===ph.id ? ph.color : 'rgba(255,255,255,0.5)', whiteSpace:'nowrap' }}>{ph.label}</span>
          </button>
        ))}
      </div>

      <button onClick={() => setShowForm(true)} style={{ position:'absolute', bottom:48, right:52, zIndex:1000, background:'rgba(124,111,205,0.92)', border:'none', color:'#fff', padding:'10px 18px', borderRadius:8, cursor:'pointer', fontWeight:600, fontSize:14, display:'flex', alignItems:'center', gap:7, boxShadow:'0 4px 20px rgba(124,111,205,0.4)' }}>
        <span style={{ fontSize:18 }}>+</span> Add report
      </button>

      {selected && !showForm && (
        <div style={{ position:'absolute', bottom:48, left:'50%', transform:'translateX(-50%)', zIndex:1001, background:'rgba(10,10,18,0.97)', border:'0.5px solid rgba(255,255,255,0.15)', borderRadius:10, padding:'14px 18px', minWidth:280, maxWidth:380 }}>
          <div style={{ display:'flex', justifyContent:'space-between', marginBottom:8 }}>
            <span style={{ fontSize:11, color:getPh(selected.phenomenon_type).color, textTransform:'uppercase', letterSpacing:'0.08em', fontWeight:600 }}>{getPh(selected.phenomenon_type).label}</span>
            <button onClick={() => setSelected(null)} style={{ background:'none', border:'none', color:'rgba(255,255,255,0.4)', cursor:'pointer', fontSize:20 }}>×</button>
          </div>
          <div style={{ color:'#e8e8f0', fontWeight:600, fontSize:15, marginBottom:6 }}>{selected.title}</div>
          {selected.description && <div style={{ color:'rgba(255,255,255,0.6)', fontSize:13, lineHeight:1.5, marginBottom:8 }}>{selected.description}</div>}
          <div style={{ color:'rgba(255,255,255,0.3)', fontSize:11 }}>{selected.location_display || 'Location hidden'}</div>
        </div>
      )}

      {showForm && (
        <div style={{ position:'absolute', inset:0, zIndex:2000, background:'rgba(0,0,0,0.65)', display:'flex', alignItems:'center', justifyContent:'center' }}>
          <div style={{ background:'#0f0f18', border:'0.5px solid rgba(255,255,255,0.13)', borderRadius:12, width:460, maxHeight:'90vh', overflowY:'auto', padding:22 }}>
            {submitSuccess ? (
              <div style={{ textAlign:'center', padding:'32px 0' }}>
                <div style={{ fontSize:36 }}>✓</div>
                <div style={{ color:'#7C6FCD', fontSize:18, fontWeight:600, marginTop:10 }}>Report submitted</div>
              </div>
            ) : (
              <>
                <div style={{ display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:18 }}>
                  <div style={{ color:'#e8e8f0', fontWeight:600, fontSize:16 }}>Report a phenomenon</div>
                  <button onClick={() => { setShowForm(false); resetForm(); }} style={{ background:'none', border:'none', color:'rgba(255,255,255,0.4)', cursor:'pointer', fontSize:22 }}>×</button>
                </div>

                <div style={{ display:'flex', gap:5, marginBottom:14 }}>
                  {['quick','full'].map(m => (
                    <button key={m} onClick={() => setFormMode(m)} style={{ flex:1, padding:'6px 0', borderRadius:5, fontSize:12, border: formMode===m ? '0.5px solid #7C6FCD' : '0.5px solid rgba(255,255,255,0.13)', background: formMode===m ? 'rgba(124,111,205,0.18)' : 'transparent', color: formMode===m ? '#a99fe0' : 'rgba(255,255,255,0.4)', fontWeight: formMode===m ? 600 : 400, cursor:'pointer' }}>
                      {m === 'quick' ? 'Quick report (30s)' : 'Full report'}
                    </button>
                  ))}
                </div>

                <span style={S.label}>Phenomenon type</span>
                <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:4, marginBottom:10 }}>
                  {PHENOMENON_TYPES.map(ph => (
                    <button key={ph.id} onClick={() => setField('phenomenon_type', ph.id)} style={{ display:'flex', alignItems:'center', gap:7, padding:'6px 9px', borderRadius:5, cursor:'pointer', border: form.phenomenon_type===ph.id ? '0.5px solid '+ph.color : '0.5px solid rgba(255,255,255,0.1)', background: form.phenomenon_type===ph.id ? ph.color+'18' : 'transparent', textAlign:'left' }}>
                      <div style={{ width:7, height:7, borderRadius:'50%', background:ph.color, flexShrink:0 }} />
                      <span style={{ fontSize:11, color: form.phenomenon_type===ph.id ? ph.color : 'rgba(255,255,255,0.55)' }}>{ph.label}</span>
                    </button>
                  ))}
                </div>

                <span style={S.label}>Title *</span>
                <input value={form.title} onChange={e => setField('title', e.target.value)} placeholder="Brief description" style={S.input} />

                <span style={S.label}>Location</span>
                <div style={{ display:'flex', gap:6, marginBottom:10 }}>
                  <input value={form.location_display} onChange={e => setField('location_display', e.target.value)} placeholder="Address or coordinates, or click map" style={{ ...S.input, flex:1, marginBottom:0 }} />
                  <button onClick={getGPS} style={{ background:'rgba(255,255,255,0.07)', border:'0.5px solid rgba(255,255,255,0.15)', color:'rgba(255,255,255,0.7)', padding:'7px 11px', borderRadius:6, cursor:'pointer', fontSize:12, whiteSpace:'nowrap' }}>{locating ? '...' : '📍 GPS'}</button>
                </div>

                <span style={S.label}>Date & time</span>
                <input type="datetime-local" value={form.occurred_at} onChange={e => setField('occurred_at', e.target.value)} style={{ ...S.input, colorScheme:'dark' }} />

                <span style={S.label}>What happened</span>
                <textarea value={form.description} onChange={e => setField('description', e.target.value)} placeholder="Describe what you experienced..." rows={3} style={{ ...S.input, resize:'vertical' }} />

                {formMode === 'full' && (
                  <>
                    <div style={{ borderTop:'0.5px solid rgba(255,255,255,0.08)', paddingTop:10, marginBottom:10, color:'rgba(255,255,255,0.35)', fontSize:10, textTransform:'uppercase', letterSpacing:'0.06em' }}>Environment</div>
                    <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:8, marginBottom:10 }}>
                      <div>
                        <span style={S.label}>Setting</span>
                        <select onChange={e => setField('environment', {...form.environment, setting: e.target.value})} style={{ ...S.input, marginBottom:0 }}>
                          <option value="">Select</option><option>Indoor</option><option>Outdoor</option><option>Vehicle</option>
                        </select>
                      </div>
                      <div>
                        <span style={S.label}>Witnesses</span>
                        <select onChange={e => setField('environment', {...form.environment, witnesses: e.target.value})} style={{ ...S.input, marginBottom:0 }}>
                          <option value="">Select</option><option>Alone</option><option>2-3 people</option><option>4-10 people</option><option>10+</option>
                        </select>
                      </div>
                    </div>
                    <span style={S.label}>Physical sensations</span>
                    <textarea value={form.physical_sensations} onChange={e => setField('physical_sensations', e.target.value)} placeholder="Temperature changes, pressure, tingling..." rows={2} style={{ ...S.input, resize:'vertical' }} />
                    <span style={S.label}>Possible mundane explanations considered</span>
                    <textarea value={form.mundane_explanations} onChange={e => setField('mundane_explanations', e.target.value)} placeholder="What have you ruled out? (improves research quality)" rows={2} style={{ ...S.input, resize:'vertical' }} />
                    <span style={S.label}>Prior experiences at this location</span>
                    <textarea value={form.prior_experiences} onChange={e => setField('prior_experiences', e.target.value)} placeholder="Have others reported experiences here?" rows={2} style={{ ...S.input, resize:'vertical' }} />
                    <span style={S.label}>Duration (minutes)</span>
                    <input type="number" value={form.duration_minutes} onChange={e => setField('duration_minutes', e.target.value)} placeholder="Estimated duration" style={S.input} />
                  </>
                )}

                <div style={{ borderTop:'0.5px solid rgba(255,255,255,0.08)', paddingTop:10, marginBottom:10 }}>
                  <span style={S.label}>Privacy</span>
                  {PRIVACY_LEVELS.map(p => (
                    <button key={p.id} onClick={() => setField('privacy_level', p.id)} style={{ display:'flex', justifyContent:'space-between', alignItems:'center', width:'100%', padding:'7px 10px', borderRadius:5, cursor:'pointer', border: form.privacy_level===p.id ? '0.5px solid rgba(124,111,205,0.6)' : '0.5px solid rgba(255,255,255,0.09)', background: form.privacy_level===p.id ? 'rgba(124,111,205,0.12)' : 'transparent', marginBottom:4 }}>
                      <span style={{ fontSize:12, fontWeight:500, color: form.privacy_level===p.id ? '#a99fe0' : 'rgba(255,255,255,0.7)' }}>{p.label}</span>
                      <span style={{ fontSize:10, color:'rgba(255,255,255,0.3)' }}>{p.desc}</span>
                    </button>
                  ))}
                </div>

                <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:8, marginBottom:10 }}>
                  <div><span style={S.label}>Name (optional)</span><input value={form.reporter_name} onChange={e => setField('reporter_name', e.target.value)} placeholder="Anonymous" style={{ ...S.input, marginBottom:0 }} /></div>
                  <div><span style={S.label}>Email (optional)</span><input type="email" value={form.reporter_email} onChange={e => setField('reporter_email', e.target.value)} placeholder="For follow-up only" style={{ ...S.input, marginBottom:0 }} /></div>
                </div>

                <button onClick={handleSubmit} disabled={submitting || !form.title} style={{ width:'100%', background: !form.title ? 'rgba(124,111,205,0.3)' : 'rgba(124,111,205,0.9)', border:'none', color:'#fff', padding:12, borderRadius:7, cursor: !form.title ? 'not-allowed' : 'pointer', fontWeight:600, fontSize:14, opacity: submitting ? 0.7 : 1 }}>
                  {submitting ? 'Submitting...' : 'Submit report'}
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
APPEOF
"
log "App.jsx written"

info "Building React app..."
pct exec $CT_FRONTEND -- bash -c "
    cd /opt/ather-register
    npm run build
    mkdir -p /var/www/ather-register
    cp -r dist/* /var/www/ather-register/
"
log "React app built and copied"

info "Configuring Nginx in CT $CT_FRONTEND..."
pct exec $CT_FRONTEND -- bash -c "
    cat > /etc/nginx/sites-available/ather-register << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/ather-register;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/ather-register /etc/nginx/sites-enabled/
    nginx -t && systemctl enable nginx && systemctl restart nginx
"
log "Nginx configured in CT $CT_FRONTEND"

# =============================================================
# STEP 6 — Update CT 100 (reverse proxy)
# =============================================================
info "Adding register.aetherguild.org to CT $CT_PROXY (reverse proxy)..."

pct exec $CT_PROXY -- bash -c "
    cat > /etc/nginx/sites-available/register.aetherguild.org << 'EOF'
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        proxy_pass http://${IP_FRONTEND}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/register.aetherguild.org /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
"
log "Reverse proxy updated"

# =============================================================
# STEP 7 — Verification
# =============================================================
echo ""
info "Running verification checks..."

# Check Supabase API
STATUS=$(pct exec $CT_SUPABASE -- bash -c "curl -sf http://localhost:8000/rest/v1/reports -H 'apikey: ${ANON_KEY}' -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000")
if [[ "$STATUS" == "200" ]]; then log "Supabase API: OK (HTTP 200)"; else warn "Supabase API: HTTP $STATUS — may still be starting"; fi

# Check frontend
STATUS=$(pct exec $CT_FRONTEND -- bash -c "curl -sf http://localhost:80 -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000")
if [[ "$STATUS" == "200" ]]; then log "Frontend: OK (HTTP 200)"; else warn "Frontend: HTTP $STATUS"; fi

# Check reverse proxy routing
STATUS=$(pct exec $CT_PROXY -- bash -c "curl -sf http://localhost:80 -H 'Host: ${DOMAIN}' -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000")
if [[ "$STATUS" == "200" ]]; then log "Reverse proxy routing: OK (HTTP 200)"; else warn "Reverse proxy: HTTP $STATUS"; fi

# =============================================================
# DONE
# =============================================================
echo ""
echo "=================================================="
echo -e "  ${GREEN}ATHER REGISTER DEPLOY COMPLETE${NC}"
echo "=================================================="
echo ""
echo "Infrastructure:"
echo "  CT 103 Supabase   → http://${IP_SUPABASE}:8000"
echo "  CT 104 Frontend   → http://${IP_FRONTEND}:80"
echo "  CT 100 Proxy      → routes ${DOMAIN}"
echo ""
echo "Credentials saved to: /root/ather-register-credentials.txt"
echo ""
echo -e "${YELLOW}ONE MANUAL STEP REMAINING:${NC}"
echo ""
echo "Add the Cloudflare tunnel public hostname:"
echo "  1. Go to dash.cloudflare.com"
echo "  2. Zero Trust → Networks → Tunnels"
echo "  3. Find your tunnel → Edit → Public Hostnames → Add"
echo "  4. Subdomain: register"
echo "  5. Domain: aetherguild.org"
echo "  6. Type: HTTP"
echo "  7. URL: 192.168.1.100:80"
echo "  8. Save"
echo ""
echo "Site will be live at https://${DOMAIN} within 60 seconds."
echo ""
