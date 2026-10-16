// RoadSafe - small UI helpers
document.addEventListener('DOMContentLoaded', () => {
  // confirm dialogs: <form data-confirm="Are you sure?">
  document.querySelectorAll('form[data-confirm]').forEach(f =>
    f.addEventListener('submit', e => { if (!confirm(f.dataset.confirm)) e.preventDefault(); }));
  // auto-dismiss flash messages
  document.querySelectorAll('.alert-auto').forEach(a => setTimeout(() => {
    bootstrap.Alert.getOrCreateInstance(a).close(); }, 6000));
  // auto-refresh live tracking pages
  const live = document.querySelector('[data-autorefresh]');
  if (live) setTimeout(() => location.reload(), parseInt(live.dataset.autorefresh, 10) * 1000);
});

// Chart.js shortcut with the RoadSafe palette
const RS_COLORS = ['#0f5a46', '#f4c430', '#3a86c8', '#c0392b', '#8e6bd1', '#e67e22', '#2aa198', '#7f8c8d'];
function rsChart(id, type, labels, datasets, opts = {}) {
  const el = document.getElementById(id);
  if (!el || typeof Chart === 'undefined') return;
  const circular = ['doughnut', 'pie'].includes(type);
  datasets.forEach((d, i) => {
    if (circular) d.backgroundColor = d.backgroundColor || RS_COLORS;
    else { d.backgroundColor = d.backgroundColor || RS_COLORS[i % RS_COLORS.length]; d.borderColor = d.borderColor || RS_COLORS[i % RS_COLORS.length]; }
  });
  return new Chart(el, { type, data: { labels, datasets }, options: Object.assign({
    responsive: true, maintainAspectRatio: false,
    plugins: { legend: { display: circular || datasets.length > 1, position: 'bottom' } },
    scales: circular ? {} : { y: { beginAtZero: true, grid: { color: '#eef1ee' } }, x: { grid: { display: false } } }
  }, opts) });
}
