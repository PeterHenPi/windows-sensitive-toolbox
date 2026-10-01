const state = {
  currentScanTaskId: null,
  currentLabelPreviewTaskId: null,
  currentLabelApplyTaskId: null,
  pendingRollbackTaskId: null,
  selectedRows: new Set(),
  previewRows: []
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function showView(viewId) {
  $$(".view").forEach((view) => view.classList.toggle("active", view.id === viewId));
  $$(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.view === viewId));
  if (location.hash !== `#${viewId}`) {
    history.replaceState(null, "", `#${viewId}`);
  }
  if (viewId === "history" || viewId === "home") loadHistory();
}

function setStatus(target, html) {
  target.innerHTML = `<div class="status-line">${html}</div>`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || data.message || "请求失败");
  }
  return data;
}

function rowsFromTextarea(id) {
  return $(id).value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function renderMetrics(target, metrics) {
  target.innerHTML = metrics
    .map((item) => `
      <div class="metric">
        <span>${escapeHtml(item.label)}</span>
        <strong>${escapeHtml(item.value)}</strong>
      </div>
    `)
    .join("");
}

function statusBadge(text) {
  let type = "";
  if (["可处理", "成功", "completed"].includes(text)) type = "ok";
  if (["已含标签", "目标已存在", "跳过", "running", "canceled"].includes(text)) type = "warn";
  if (["失败", "failed"].includes(text)) type = "fail";
  return `<span class="badge ${type}">${escapeHtml(text)}</span>`;
}

function checkBadge(status) {
  const label = status === "ok" ? "正常" : status === "fail" ? "失败" : "提醒";
  return `<span class="badge ${status === "ok" ? "ok" : status === "fail" ? "fail" : "warn"}">${label}</span>`;
}

async function pickPath(kind, targetId) {
  try {
    const data = await api(`/api/path/pick?kind=${encodeURIComponent(kind)}`);
    if (data.path) $(`#${targetId}`).value = data.path;
  } catch (error) {
    alert(`无法打开选择窗口：${error.message}\n也可以直接手动输入路径。`);
  }
}

async function openPath(path) {
  if (!path) {
    alert("当前还没有可打开的任务目录。");
    return;
  }
  await api("/api/path/open", {
    method: "POST",
    body: JSON.stringify({ path })
  });
}

function pollTask(taskId, onUpdate) {
  const timer = setInterval(async () => {
    try {
      const task = await api(`/api/task?id=${encodeURIComponent(taskId)}`);
      onUpdate(task);
      if (["completed", "failed", "canceled"].includes(task.state)) {
        clearInterval(timer);
        loadHistory();
      }
    } catch (error) {
      clearInterval(timer);
      onUpdate({ state: "failed", message: error.message });
    }
  }, 1200);
}

function getScanMode() {
  return $("input[name='scanMode']:checked")?.value || "filename";
}

function parseContentExtensions() {
  return $("#contentExtensions").value
    .split(/[,\s;，；]+/)
    .map((item) => item.trim().replace(/^\./, ""))
    .filter(Boolean);
}

function parsePositiveInt(selector, fallback) {
  const value = Number.parseInt($(selector).value, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function toggleContentOptions() {
  $("#contentOptions").classList.toggle("hidden", getScanMode() !== "content");
}

async function startScan() {
  const button = $("#startScan");
  const payload = {
    scanMode: getScanMode(),
    scanPath: $("#scanPath").value.trim(),
    configPath: $("#configPath").value.trim(),
    recurse: $("#scanRecurse").checked,
    excludePaths: rowsFromTextarea("#excludePaths"),
    contentExtensions: parseContentExtensions(),
    maxContentFileSizeMB: parsePositiveInt("#maxContentFileSizeMB", 50),
    extractionTimeoutSeconds: parsePositiveInt("#extractionTimeoutSeconds", 60),
    incremental: $("#scanIncremental").checked
  };

  if (!payload.scanPath || !payload.configPath) {
    alert("请填写扫描目录和规则文件。");
    return;
  }

  button.disabled = true;
  $("#cancelScan").disabled = true;
  $("#scanSummary").innerHTML = "";
  $("#scanSamples").innerHTML = "";
  setStatus($("#scanStatus"), payload.scanMode === "content" ? "正在提交深度扫描任务..." : "正在提交快速扫描任务...");

  try {
    const data = await api("/api/scan/start", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    state.currentScanTaskId = data.taskId;
    $("#cancelScan").disabled = false;
    pollTask(data.taskId, renderScanTask);
  } catch (error) {
    setStatus($("#scanStatus"), statusBadge("失败") + ` ${escapeHtml(error.message)}`);
    button.disabled = false;
    $("#cancelScan").disabled = true;
  }
}

function renderScanTask(task) {
  $("#startScan").disabled = task.state === "running";
  $("#cancelScan").disabled = task.state !== "running";
  const isContent = task.scanMode === "content";
  const label = task.state === "running"
    ? (isContent ? "正在深度扫描" : "正在快速扫描")
    : task.state === "completed"
      ? (isContent ? "深度扫描完成" : "扫描完成")
      : task.state === "canceled"
        ? "扫描已取消"
        : "扫描失败";
  setStatus($("#scanStatus"), `${statusBadge(task.state)} <strong>${label}</strong> ${escapeHtml(task.message || "")}`);

  if (task.state !== "completed") return;

  const levelCounts = task.levelCounts || {};
  const levelText = Object.keys(levelCounts).length
    ? Object.entries(levelCounts).map(([key, value]) => `${key}: ${value}`).join("，")
    : "无";

  const metrics = [
    { label: "命中文件", value: task.matchedCount ?? 0 },
    { label: "密级统计", value: levelText },
    { label: "任务 ID", value: task.id }
  ];

  if (isContent) {
    const estimate = task.estimate || {};
    metrics.splice(1, 0,
      { label: "预计总文件", value: estimate.totalFiles ?? "-" },
      { label: "可深度扫描", value: estimate.contentEligibleFiles ?? "-" },
      { label: "跳过/失败", value: `${task.skippedCount ?? 0}/${task.failedCount ?? 0}` }
    );
  } else {
    metrics.splice(2, 0, { label: "结果文件", value: "已生成" });
  }

  renderMetrics($("#scanSummary"), metrics);

  const rows = task.samples || [];
  if (isContent) {
    $("#scanSamples").innerHTML = rows.length ? `
      <table>
        <thead>
          <tr>
            <th>文件名</th>
            <th>密级</th>
            <th>范围</th>
            <th>关键词</th>
            <th>片段</th>
            <th>状态</th>
            <th>路径</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td>${escapeHtml(row.FileName)}</td>
              <td>${escapeHtml(row.SensitiveLevel)}</td>
              <td>${escapeHtml(row.MatchScope)}</td>
              <td>${escapeHtml(row.MatchedKeywords)}</td>
              <td>${escapeHtml(row.MatchedSnippet)}</td>
              <td>${escapeHtml(row.ScanStatus || row.SkipReason || "")}</td>
              <td class="path">${escapeHtml(row.FilePath)}</td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    ` : "按当前规则未发现命中文件。完整跳过和失败信息已写入任务目录。";
    return;
  }

  $("#scanSamples").innerHTML = rows.length ? `
    <table>
      <thead>
        <tr>
          <th>文件名</th>
          <th>密级</th>
          <th>关键词</th>
          <th>路径</th>
        </tr>
      </thead>
      <tbody>
        ${rows.map((row) => `
          <tr>
            <td>${escapeHtml(row.FileName)}</td>
            <td>${escapeHtml(row.SensitiveLevel)}</td>
            <td>${escapeHtml(row.MatchedKeywords)}</td>
            <td class="path">${escapeHtml(row.FilePath)}</td>
          </tr>
        `).join("")}
      </tbody>
    </table>
  ` : "未发现命中文件。";
}

async function cancelScan() {
  if (!state.currentScanTaskId) return;
  if (!confirm("确定要取消当前扫描任务吗？已生成的任务文件会保留在任务目录中。")) return;
  $("#cancelScan").disabled = true;
  try {
    await api("/api/task/cancel", {
      method: "POST",
      body: JSON.stringify({ taskId: state.currentScanTaskId })
    });
    setStatus($("#scanStatus"), `${statusBadge("canceled")} <strong>扫描已取消</strong>`);
    $("#startScan").disabled = false;
  } catch (error) {
    alert(`取消失败：${error.message}`);
  }
}

async function startPreview() {
  const button = $("#startPreview");
  const payload = {
    rootPath: $("#labelRoot").value.trim(),
    recurse: $("#labelRecurse").checked,
    includeFiles: $("#includeFiles").checked,
    includeFolders: $("#includeFolders").checked,
    labelStyle: $("#labelStyle").value,
    labelText: $("#labelText").value.trim() || "商密二级"
  };

  if (!payload.rootPath) {
    alert("请填写处理目录。");
    return;
  }

  if (!payload.includeFiles && !payload.includeFolders) {
    alert("请至少选择处理文件或处理文件夹。");
    return;
  }

  button.disabled = true;
  $("#applyLabel").disabled = true;
  $("#labelSummary").innerHTML = "";
  $("#labelPreview").innerHTML = "";
  state.previewRows = [];
  state.selectedRows.clear();
  setStatus($("#labelStatus"), "正在提交预览任务...");

  try {
    const data = await api("/api/label/preview", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    state.currentLabelPreviewTaskId = data.taskId;
    pollTask(data.taskId, renderLabelPreviewTask);
  } catch (error) {
    setStatus($("#labelStatus"), statusBadge("失败") + ` ${escapeHtml(error.message)}`);
    button.disabled = false;
  }
}

function renderLabelPreviewTask(task) {
  $("#startPreview").disabled = task.state === "running";
  const label = task.state === "running" ? "正在生成预览" : task.state === "completed" ? "预览完成" : "预览失败";
  setStatus($("#labelStatus"), `${statusBadge(task.state)} <strong>${label}</strong> ${escapeHtml(task.message || "")}`);

  if (task.state !== "completed") return;

  state.previewRows = task.samples || [];
  state.selectedRows = new Set(
    state.previewRows
      .filter((row) => row.Status === "可处理")
      .map((row) => String(row.Id))
  );

  renderMetrics($("#labelSummary"), [
    { label: "总项目", value: task.totalCount ?? 0 },
    { label: "可处理", value: task.processableCount ?? 0 },
    { label: "跳过", value: task.skippedCount ?? 0 },
    { label: "任务 ID", value: task.id }
  ]);

  renderPreviewTable();
  $("#applyLabel").disabled = state.selectedRows.size === 0;
}

function renderPreviewTable() {
  const rows = state.previewRows;
  if (!rows.length) {
    $("#labelPreview").innerHTML = "没有可显示的预览项。";
    return;
  }

  $("#labelPreview").innerHTML = `
    <table>
      <thead>
        <tr>
          <th>选择</th>
          <th>状态</th>
          <th>原文件名</th>
          <th>新文件名</th>
          <th>路径</th>
        </tr>
      </thead>
      <tbody>
        ${rows.map((row) => {
          const id = String(row.Id);
          const canSelect = row.Status === "可处理";
          return `
            <tr>
              <td>
                <input type="checkbox" data-row-id="${escapeHtml(id)}" ${state.selectedRows.has(id) ? "checked" : ""} ${canSelect ? "" : "disabled"}>
              </td>
              <td>${statusBadge(row.Status)}</td>
              <td>${escapeHtml(row.SourceName)}</td>
              <td>${escapeHtml(row.TargetName)}</td>
              <td class="path">${escapeHtml(row.SourcePath)}</td>
            </tr>
          `;
        }).join("")}
      </tbody>
    </table>
  `;

  $$("input[data-row-id]").forEach((checkbox) => {
    checkbox.addEventListener("change", () => {
      const id = checkbox.dataset.rowId;
      if (checkbox.checked) state.selectedRows.add(id);
      else state.selectedRows.delete(id);
      $("#applyLabel").disabled = state.selectedRows.size === 0;
    });
  });
}

function showApplyConfirm() {
  if (!state.currentLabelPreviewTaskId || state.selectedRows.size === 0) return;
  $("#confirmText").textContent = `即将重命名 ${state.selectedRows.size} 个项目。执行前请确认预览表中的新文件名无误。正式执行会保存回滚记录。`;
  $("#confirmModal").classList.remove("hidden");
}

async function applyLabel() {
  $("#confirmModal").classList.add("hidden");
  $("#applyLabel").disabled = true;
  setStatus($("#labelStatus"), "正在提交执行任务...");

  try {
    const data = await api("/api/label/apply", {
      method: "POST",
      body: JSON.stringify({
        previewTaskId: state.currentLabelPreviewTaskId,
        selectedIds: Array.from(state.selectedRows)
      })
    });
    state.currentLabelApplyTaskId = data.taskId;
    pollTask(data.taskId, renderLabelApplyTask);
  } catch (error) {
    setStatus($("#labelStatus"), statusBadge("失败") + ` ${escapeHtml(error.message)}`);
    $("#applyLabel").disabled = false;
  }
}

function renderLabelApplyTask(task) {
  const label = task.state === "running" ? "正在执行加标签" : task.state === "completed" ? "执行完成" : "执行失败";
  setStatus($("#labelStatus"), `${statusBadge(task.state)} <strong>${label}</strong> ${escapeHtml(task.message || "")}`);

  if (task.state !== "completed") return;

  renderMetrics($("#labelSummary"), [
    { label: "处理总数", value: task.totalCount ?? 0 },
    { label: "成功", value: task.successCount ?? 0 },
    { label: "跳过", value: task.skippedCount ?? 0 },
    { label: "失败", value: task.failedCount ?? 0 }
  ]);

  const rows = task.samples || [];
  $("#labelPreview").innerHTML = `
    <table>
      <thead>
        <tr>
          <th>状态</th>
          <th>原路径</th>
          <th>新路径</th>
          <th>说明</th>
        </tr>
      </thead>
      <tbody>
        ${rows.map((row) => `
          <tr>
            <td>${statusBadge(row.Status)}</td>
            <td class="path">${escapeHtml(row.SourcePath)}</td>
            <td class="path">${escapeHtml(row.TargetPath)}</td>
            <td>${escapeHtml(row.Message)}</td>
          </tr>
        `).join("")}
      </tbody>
    </table>
  `;
}

async function runRuleTest() {
  const payload = {
    configPath: $("#ruleTestConfigPath").value.trim(),
    inputText: $("#ruleTestText").value,
    scope: $("#ruleTestScope").value
  };

  if (!payload.configPath || !payload.inputText.trim()) {
    alert("请填写规则文件和测试文本。");
    return;
  }

  $("#ruleTestResults").textContent = "正在测试...";
  $("#ruleTestSummary").innerHTML = "";

  try {
    const result = await api("/api/rules/test", {
      method: "POST",
      body: JSON.stringify(payload)
    });

    renderMetrics($("#ruleTestSummary"), [
      { label: "规则总数", value: result.totalRules ?? 0 },
      { label: "启用规则", value: result.enabledRules ?? 0 },
      { label: "命中规则", value: result.matchedCount ?? 0 },
      { label: "测试范围", value: payload.scope }
    ]);

    const rows = result.matches || [];
    $("#ruleTestResults").innerHTML = rows.length ? `
      <table>
        <thead>
          <tr>
            <th>密级</th>
            <th>优先级</th>
            <th>范围</th>
            <th>方式</th>
            <th>关键词/类型</th>
            <th>原因</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td>${escapeHtml(row.Level)}</td>
              <td>${escapeHtml(row.Priority)}</td>
              <td>${escapeHtml(row.MatchScope)}</td>
              <td>${escapeHtml(row.MatchMode)}</td>
              <td>${escapeHtml(row.Keyword)}</td>
              <td>${escapeHtml(row.Reason)}</td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    ` : "没有命中规则。";
  } catch (error) {
    $("#ruleTestResults").innerHTML = `${statusBadge("失败")} ${escapeHtml(error.message)}`;
  }
}

async function runEnvironmentCheck() {
  $("#envResults").textContent = "正在检测...";
  try {
    const result = await api("/api/environment/check", { method: "GET" });
    const rows = result.items || [];
    $("#envResults").innerHTML = rows.length ? `
      <table>
        <thead>
          <tr>
            <th>项目</th>
            <th>状态</th>
            <th>说明</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td>${escapeHtml(row.name)}</td>
              <td>${checkBadge(row.status)}</td>
              <td class="path">${escapeHtml(row.detail)}</td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    ` : "没有检测结果。";
  } catch (error) {
    $("#envResults").innerHTML = `${statusBadge("失败")} ${escapeHtml(error.message)}`;
  }
}

function showRollbackConfirm(taskId) {
  state.pendingRollbackTaskId = taskId;
  $("#rollbackText").textContent = `即将根据任务 ${taskId} 的回滚记录，把已加标签的文件名恢复为原文件名。若原路径已存在，会自动跳过以避免覆盖。`;
  $("#rollbackModal").classList.remove("hidden");
}

async function confirmRollback() {
  const taskId = state.pendingRollbackTaskId;
  if (!taskId) return;
  $("#rollbackModal").classList.add("hidden");

  try {
    const data = await api("/api/label/rollback", {
      method: "POST",
      body: JSON.stringify({ taskId })
    });
    alert(`回滚任务已启动：${data.taskId}`);
    showView("history");
    pollTask(data.taskId, () => loadHistory());
  } catch (error) {
    alert(`回滚启动失败：${error.message}`);
  }
}

function taskTitle(task) {
  const map = {
    scan: "敏感文件扫描",
    "label-preview": "加标签预览",
    "label-apply": "加标签执行",
    "label-rollback": "加标签回滚"
  };
  return map[task.type] || task.type || "任务";
}

function taskPath(task) {
  return task.scanPath || task.rootPath || task.taskDir || "";
}

async function loadHistory() {
  try {
    const data = await api("/api/tasks");
    const tasks = data.tasks || [];
    const html = tasks.length ? tasks.map((task) => `
      <div class="history-item">
        <div>
          <strong>${escapeHtml(taskTitle(task))} ${statusBadge(task.state)}</strong>
          <small>${escapeHtml(task.id)} · ${escapeHtml(task.updatedAt || "")}</small>
          <small>${escapeHtml(taskPath(task))}</small>
          <small>${escapeHtml(task.message || "")}</small>
        </div>
        <div class="history-actions">
          ${task.type === "label-apply" && task.state === "completed" ? `<button class="danger small" data-rollback-task="${escapeHtml(task.id)}">回滚</button>` : ""}
          <button class="secondary small" data-open-task="${escapeHtml(task.taskDir || "")}">打开</button>
        </div>
      </div>
    `).join("") : "暂无任务记录";

    $("#historyList").classList.toggle("empty", !tasks.length);
    $("#historyList").innerHTML = html;
    $("#recentTasks").classList.toggle("empty", !tasks.length);
    $("#recentTasks").innerHTML = tasks.length ? html : "暂无任务记录";
    $$("[data-open-task]").forEach((button) => {
      button.addEventListener("click", () => openPath(button.dataset.openTask));
    });
    $$("[data-rollback-task]").forEach((button) => {
      button.addEventListener("click", () => showRollbackConfirm(button.dataset.rollbackTask));
    });
  } catch (error) {
    $("#historyList").innerHTML = `无法读取历史记录：${escapeHtml(error.message)}`;
  }
}

function bindEvents() {
  $$(".nav-item").forEach((item) => item.addEventListener("click", () => showView(item.dataset.view)));
  $$("[data-view-target]").forEach((item) => item.addEventListener("click", () => showView(item.dataset.viewTarget)));
  $$("[data-pick]").forEach((button) => {
    button.addEventListener("click", () => pickPath(button.dataset.pick, button.dataset.target));
  });
  $$("[data-refresh-history]").forEach((button) => button.addEventListener("click", loadHistory));

  $("#startScan").addEventListener("click", startScan);
  $("#cancelScan").addEventListener("click", cancelScan);
  $$("input[name='scanMode']").forEach((radio) => radio.addEventListener("change", toggleContentOptions));
  $("#startPreview").addEventListener("click", startPreview);
  $("#applyLabel").addEventListener("click", showApplyConfirm);
  $("#cancelApply").addEventListener("click", () => $("#confirmModal").classList.add("hidden"));
  $("#confirmApply").addEventListener("click", applyLabel);
  $("#cancelRollback").addEventListener("click", () => $("#rollbackModal").classList.add("hidden"));
  $("#confirmRollback").addEventListener("click", confirmRollback);
  $("#runRuleTest").addEventListener("click", runRuleTest);
  $("#runEnvCheck").addEventListener("click", runEnvironmentCheck);

  $("#selectAllRows").addEventListener("click", () => {
    state.previewRows.filter((row) => row.Status === "可处理").forEach((row) => state.selectedRows.add(String(row.Id)));
    renderPreviewTable();
    $("#applyLabel").disabled = state.selectedRows.size === 0;
  });

  $("#clearRows").addEventListener("click", () => {
    state.selectedRows.clear();
    renderPreviewTable();
    $("#applyLabel").disabled = true;
  });

  $$("[data-open-current]").forEach((button) => {
    button.addEventListener("click", async () => {
      const kind = button.dataset.openCurrent;
      let taskId = kind === "scan" ? state.currentScanTaskId : (state.currentLabelApplyTaskId || state.currentLabelPreviewTaskId);
      if (!taskId) {
        alert("当前还没有任务目录。");
        return;
      }
      const task = await api(`/api/task?id=${encodeURIComponent(taskId)}`);
      await openPath(task.taskDir);
    });
  });
}

bindEvents();
toggleContentOptions();
showView((location.hash || "#home").slice(1));
