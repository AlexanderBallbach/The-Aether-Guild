import { useState, useEffect, useRef } from 'react';

const SUPABASE_URL = 'http://192.168.1.103:8000';
const SUPABASE_ANON_KEY = 'eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9.eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3ODI1MDI0NTksICJleHAiOiAyMDk3ODYyNDU5fQ.I8ufpOapQ_rUvlgW3c4vdG2TvMt4i_61HJATljd-DFg';

const PHENOMENON_TYPES = [
  { id: 'residual_haunting', label: 'Residual Haunting', color: '#7C6FCD' },
  { id: 'intelligent_haunting', label: 'Intelligent Haunting', color: '#C062A0' },
  { id: 'cryptid', label: 'Cryptid', color: '#5A9E6A' },
  { id: 'extraterrestrial', label: 'Extraterrestrial', color: '#3A8FCC' },
  { id: 'psychic', label: 'Psychic / Anomalous Cognition', color: '#A67CC5' },
  { id: 'physical_anomaly', label: 'Physical Anomaly', color: '#C09A3A' },
  { id: 'evp_audio', label: 'EVP / Audio Anomaly', color: '#5AABAA' },
  { id: 'other', label: 'Other / Unclassified', color: '#888880' },
];

const MAP_STYLES = [
  { id: 'dark', label: 'Dark', url: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png' },
  { id: 'satellite', label: 'Satellite', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}' },
  { id: 'light', label: 'Light', url: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png' },
  { id: 'terrain', label: 'Terrain', url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png' },
];

const PRIVACY_LEVELS = [
  { id: 'public', label: 'Public', desc: 'Visible to everyone' },
  { id: 'community', label: 'Community', desc: 'Registered users only' },
  { id: 'confidential', label: 'Confidential', desc: 'Location obscured' },
  { id: 'private', label: 'Private', desc: 'Researchers only' },
];

function getPh(id) { return PHENOMENON_TYPES.find(p => p.id === id) || PHENOMENON_TYPES[7]; }

export default function AtherRegister() {
  const mapRef = useRef(null);
  const leafletMap = useRef(null);
  const tileLayer = useRef(null);
  const markersRef = useRef([]);
  const [mapReady, setMapReady] = useState(false);
  const [mapStyle, setMapStyle] = useState('dark');
  const [reports, setReports] = useState([]);
  const [selected, setSelected] = useState(null);
  const [filterType, setFilterType] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [formMode, setFormMode] = useState('quick');
  const [submitting, setSubmitting] = useState(false);
  const [submitSuccess, setSubmitSuccess] = useState(false);
  const [locating, setLocating] = useState(false);
  const [form, setForm] = useState({
    phenomenon_type: 'other', title: '', description: '',
    occurred_at: new Date().toISOString().slice(0,16),
    privacy_level: 'public', reporter_name: '', reporter_email: '',
    lat: null, lng: null, location_display: '',
    environment: {}, duration_minutes: '',
    physical_sensations: '', prior_experiences: '', mundane_explanations: '',
  });

  const setField = (k, v) => setForm(f => ({ ...f, [k]: v }));
  const resetForm = () => setForm({ phenomenon_type: 'other', title: '', description: '', occurred_at: new Date().toISOString().slice(0,16), privacy_level: 'public', reporter_name: '', reporter_email: '', lat: null, lng: null, location_display: '', environment: {}, duration_minutes: '', physical_sensations: '', prior_experiences: '', mundane_explanations: '' });

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

  const inp = { width:'100%', background:'rgba(255,255,255,0.05)', border:'0.5px solid rgba(255,255,255,0.15)', borderRadius:6, color:'#e8e8f0', padding:'7px 10px', fontSize:13, boxSizing:'border-box', outline:'none', marginBottom:10 };
  const lbl = { color:'rgba(255,255,255,0.45)', fontSize:10, textTransform:'uppercase', letterSpacing:'0.07em', display:'block', marginBottom:4 };

  return (
    <div style={{ position:'fixed', inset:0, background:'#0d0d12', fontFamily:'system-ui,sans-serif' }}>
      <div ref={mapRef} style={{ position:'absolute', inset:0 }} />
      <div style={{ position:'absolute', top:12, left:12, zIndex:1000, background:'rgba(10,10,18,0.92)', border:'0.5px solid rgba(255,255,255,0.12)', borderRadius:8, padding:'8px 14px', display:'flex', alignItems:'center', gap:10 }}>
        <div style={{ width:8, height:8, borderRadius:'50%', background:'#7C6FCD', boxShadow:'0 0 8px #7C6FCD' }} />
        <span style={{ color:'#e8e8f0', fontWeight:600, fontSize:15 }}>Ather Register</span>
        <span style={{ color:'rgba(255,255,255,0.3)', fontSize:12 }}>{(filterType ? reports.filter(r=>r.phenomenon_type===filterType) : reports).length} reports</span>
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
                <span style={lbl}>Phenomenon type</span>
                <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:4, marginBottom:10 }}>
                  {PHENOMENON_TYPES.map(ph => (
                    <button key={ph.id} onClick={() => setField('phenomenon_type', ph.id)} style={{ display:'flex', alignItems:'center', gap:7, padding:'6px 9px', borderRadius:5, cursor:'pointer', border: form.phenomenon_type===ph.id ? '0.5px solid '+ph.color : '0.5px solid rgba(255,255,255,0.1)', background: form.phenomenon_type===ph.id ? ph.color+'18' : 'transparent', textAlign:'left' }}>
                      <div style={{ width:7, height:7, borderRadius:'50%', background:ph.color, flexShrink:0 }} />
                      <span style={{ fontSize:11, color: form.phenomenon_type===ph.id ? ph.color : 'rgba(255,255,255,0.55)' }}>{ph.label}</span>
                    </button>
                  ))}
                </div>
                <span style={lbl}>Title *</span>
                <input value={form.title} onChange={e => setField('title', e.target.value)} placeholder="Brief description" style={inp} />
                <span style={lbl}>Location</span>
                <div style={{ display:'flex', gap:6, marginBottom:10 }}>
                  <input value={form.location_display} onChange={e => setField('location_display', e.target.value)} placeholder="Address or coordinates, or click map" style={{ ...inp, flex:1, marginBottom:0 }} />
                  <button onClick={getGPS} style={{ background:'rgba(255,255,255,0.07)', border:'0.5px solid rgba(255,255,255,0.15)', color:'rgba(255,255,255,0.7)', padding:'7px 11px', borderRadius:6, cursor:'pointer', fontSize:12, whiteSpace:'nowrap' }}>{locating ? '...' : '📍 GPS'}</button>
                </div>
                <span style={lbl}>Date & time</span>
                <input type="datetime-local" value={form.occurred_at} onChange={e => setField('occurred_at', e.target.value)} style={{ ...inp, colorScheme:'dark' }} />
                <span style={lbl}>What happened</span>
                <textarea value={form.description} onChange={e => setField('description', e.target.value)} placeholder="Describe what you experienced..." rows={3} style={{ ...inp, resize:'vertical' }} />
                {formMode === 'full' && (
                  <>
                    <div style={{ borderTop:'0.5px solid rgba(255,255,255,0.08)', paddingTop:10, marginBottom:10, color:'rgba(255,255,255,0.35)', fontSize:10, textTransform:'uppercase', letterSpacing:'0.06em' }}>Environment</div>
                    <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:8, marginBottom:10 }}>
                      <div><span style={lbl}>Setting</span><select onChange={e => setField('environment', {...form.environment, setting: e.target.value})} style={{ ...inp, marginBottom:0 }}><option value="">Select</option><option>Indoor</option><option>Outdoor</option><option>Vehicle</option></select></div>
                      <div><span style={lbl}>Witnesses</span><select onChange={e => setField('environment', {...form.environment, witnesses: e.target.value})} style={{ ...inp, marginBottom:0 }}><option value="">Select</option><option>Alone</option><option>2-3 people</option><option>4-10 people</option><option>10+</option></select></div>
                    </div>
                    <span style={lbl}>Physical sensations</span>
                    <textarea value={form.physical_sensations} onChange={e => setField('physical_sensations', e.target.value)} placeholder="Temperature, pressure, tingling..." rows={2} style={{ ...inp, resize:'vertical' }} />
                    <span style={lbl}>Mundane explanations considered</span>
                    <textarea value={form.mundane_explanations} onChange={e => setField('mundane_explanations', e.target.value)} placeholder="What have you ruled out?" rows={2} style={{ ...inp, resize:'vertical' }} />
                    <span style={lbl}>Prior experiences at this location</span>
                    <textarea value={form.prior_experiences} onChange={e => setField('prior_experiences', e.target.value)} placeholder="Have others reported experiences here?" rows={2} style={{ ...inp, resize:'vertical' }} />
                    <span style={lbl}>Duration (minutes)</span>
                    <input type="number" value={form.duration_minutes} onChange={e => setField('duration_minutes', e.target.value)} placeholder="Estimated duration" style={inp} />
                  </>
                )}
                <div style={{ borderTop:'0.5px solid rgba(255,255,255,0.08)', paddingTop:10, marginBottom:10 }}>
                  <span style={lbl}>Privacy</span>
                  {PRIVACY_LEVELS.map(p => (
                    <button key={p.id} onClick={() => setField('privacy_level', p.id)} style={{ display:'flex', justifyContent:'space-between', alignItems:'center', width:'100%', padding:'7px 10px', borderRadius:5, cursor:'pointer', border: form.privacy_level===p.id ? '0.5px solid rgba(124,111,205,0.6)' : '0.5px solid rgba(255,255,255,0.09)', background: form.privacy_level===p.id ? 'rgba(124,111,205,0.12)' : 'transparent', marginBottom:4 }}>
                      <span style={{ fontSize:12, fontWeight:500, color: form.privacy_level===p.id ? '#a99fe0' : 'rgba(255,255,255,0.7)' }}>{p.label}</span>
                      <span style={{ fontSize:10, color:'rgba(255,255,255,0.3)' }}>{p.desc}</span>
                    </button>
                  ))}
                </div>
                <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:8, marginBottom:10 }}>
                  <div><span style={lbl}>Name (optional)</span><input value={form.reporter_name} onChange={e => setField('reporter_name', e.target.value)} placeholder="Anonymous" style={{ ...inp, marginBottom:0 }} /></div>
                  <div><span style={lbl}>Email (optional)</span><input type="email" value={form.reporter_email} onChange={e => setField('reporter_email', e.target.value)} placeholder="For follow-up only" style={{ ...inp, marginBottom:0 }} /></div>
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
EOF
"
