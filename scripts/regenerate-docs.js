// 把 n8n_templates/workflows/ 底下用workflow id命名的json，依照workflow名稱的
// "分類:名稱" 慣例（例如「獲取:Fabric Authrozation」）鏡射成 docs/nodes/分類/名稱.json，
// 純粹是給人看好認的檔名，內容跟n8n_templates/workflows/一模一樣，不要手動編輯這裡的檔案。
const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, '..', 'n8n_templates', 'workflows');
const destBase = path.join(__dirname, '..', 'docs', 'nodes');

fs.rmSync(destBase, { recursive: true, force: true });

const files = fs.readdirSync(srcDir).filter((f) => f.endsWith('.json'));
for (const f of files) {
  const data = JSON.parse(fs.readFileSync(path.join(srcDir, f), 'utf8'));
  const name = data.name;
  const sepIdx = name.search(/[:：]/);
  let category, label;
  if (sepIdx === -1) {
    category = '其他';
    label = name;
  } else {
    category = name.slice(0, sepIdx).trim();
    label = name.slice(sepIdx + 1).trim();
  }
  const safeLabel = label.replace(/[\\/:*?"<>|]/g, '_');
  const destDir = path.join(destBase, category);
  fs.mkdirSync(destDir, { recursive: true });
  fs.copyFileSync(path.join(srcDir, f), path.join(destDir, safeLabel + '.json'));
}

console.log(`已依 ${files.length} 個workflow重新產生 docs/nodes/`);
