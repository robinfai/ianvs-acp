import { useMemo, useState } from "react";
import {
  MdAdd,
  MdAutoAwesome,
  MdBookmarkBorder,
  MdCheck,
  MdCheckCircle,
  MdClose,
  MdDesktopMac,
  MdExpandLess,
  MdExpandMore,
  MdEdit,
  MdFolderOpen,
  MdHub,
  MdInbox,
  MdManageAccounts,
  MdMoreHoriz,
  MdOpenInNew,
  MdOutlineBolt,
  MdOutlineFolder,
  MdOutlineHourglassEmpty,
  MdOutlineInsertDriveFile,
  MdOutlineSchedule,
  MdOutlineSend,
  MdOutlineSmartToy,
  MdOutlineTimer,
  MdPlayArrow,
  MdPlayCircleOutline,
  MdRefresh,
  MdTaskAlt,
  MdWorkspaces,
} from "react-icons/md";
import { CircularProgressbar, buildStyles } from "react-circular-progressbar";
import "react-circular-progressbar/dist/styles.css";

const initialTasks = [
  {
    id: "auth",
    group: "waiting",
    title: "Update authentication flow",
    status: "Paused for input",
    elapsed: "6m 18s",
    flowState: "paused",
    answer: "",
    savedNotice: "",
  },
  {
    id: "session",
    group: "running",
    title: "Refactor session manager",
    status: "Running",
    phase: "Write changes",
    elapsed: "4m 12s",
    progress: 68,
  },
  {
    id: "audit",
    group: "running",
    title: "Add audit logging",
    status: "Running",
    phase: "Execute tests",
    elapsed: "2m 47s",
    progress: 32,
  },
  {
    id: "errors",
    group: "queued",
    title: "Improve error messages",
    status: "Queued",
  },
  {
    id: "passwordless",
    group: "queued",
    title: "Add passwordless login",
    status: "Queued",
  },
  {
    id: "docs",
    group: "queued",
    title: "Update documentation",
    status: "Queued",
  },
  {
    id: "cleanup",
    group: "queued",
    title: "Clean up deprecated APIs",
    status: "Queued",
  },
];

const choices = [
  {
    id: "keychain",
    title: "Use Keychain on macOS (Recommended)",
    detail: "Most secure, preserves current behavior",
  },
  {
    id: "encrypted",
    title: "Use encrypted file storage everywhere",
    detail: "Consistent across platforms",
  },
  {
    id: "setup",
    title: "Keep both and ask users during setup",
    detail: "More choice, adds onboarding",
  },
];

function AppIconButton({ label, children, onClick, tone = "plain" }) {
  return (
    <button
      className={`icon-button icon-button--${tone}`}
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

function TaskRow({ task, selected, onSelect }) {
  const icon =
    task.group === "waiting" ? (
      <MdOutlineHourglassEmpty />
    ) : task.group === "queued" ? (
      <MdOutlineSchedule />
    ) : null;

  return (
    <button
      type="button"
      className={`task-row task-row--${task.group}${selected ? " is-selected" : ""}`}
      aria-current={selected ? "true" : undefined}
      aria-label={`${task.title} — ${task.status}${task.phase ? `, ${task.phase}` : ""}${task.elapsed ? `, ${task.elapsed}` : ""}`}
      onClick={() => onSelect(task.id)}
    >
      <span className="task-row__visual" aria-hidden="true">
        {task.group === "running" ? (
          <span className="task-progress">
            <CircularProgressbar
              value={task.progress}
              text={`${task.progress}%`}
              styles={buildStyles({
                pathColor: "#5b36e8",
                trailColor: "#eceafd",
                textColor: "#344054",
                textSize: "25px",
                strokeLinecap: "round",
              })}
            />
          </span>
        ) : (
          icon
        )}
      </span>
      <span className="task-row__copy">
        <strong>{task.title}</strong>
        <span>
          <em>{task.status}</em>
          {task.phase ? ` · ${task.phase}` : ""}
        </span>
      </span>
      {task.elapsed ? <time>{task.elapsed}</time> : null}
    </button>
  );
}

function Sidebar({ tasks, selectedId, onSelect, onNewTask, activeTab, onTab }) {
  const groups = useMemo(
    () => ({
      waiting: tasks.filter((task) => task.group === "waiting"),
      running: tasks.filter((task) => task.group === "running"),
      queued: tasks.filter((task) => task.group === "queued"),
    }),
    [tasks],
  );

  return (
    <aside className="sidebar">
      <div className="segmented" role="tablist" aria-label="Primary navigation">
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === "workspaces"}
          className={activeTab === "workspaces" ? "is-active" : ""}
          onClick={() => onTab("workspaces")}
        >
          <MdWorkspaces /> Workspaces
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === "inbox"}
          className={activeTab === "inbox" ? "is-active" : ""}
          onClick={() => onTab("inbox")}
        >
          <MdInbox /> Inbox
        </button>
      </div>

      {activeTab === "workspaces" ? (
        <div className="workspace-view">
          <div className="sidebar-heading">
            <h2>Workspaces</h2>
          </div>
          <button type="button" className="workspace-row" onClick={() => onTab("inbox")}>
            <MdFolderOpen />
            <span>
              <strong>ianvs-acp</strong>
              <small>/Users/robinfai/flutter_projects/ianvs-acp</small>
            </span>
            <b>7</b>
          </button>
          <p className="workspace-hint">Open Inbox to review autonomous task activity.</p>
        </div>
      ) : (
        <>
          <div className="sidebar-heading">
            <div>
              <h2>Inbox</h2>
              <p><MdAutoAwesome /> Automatic execution</p>
            </div>
            <div className="sidebar-actions">
              <AppIconButton label="More inbox actions"><MdMoreHoriz /></AppIconButton>
              <AppIconButton label="New task" tone="outlined" onClick={onNewTask}><MdTaskAlt /></AppIconButton>
            </div>
          </div>
          <div className="queue-summary" aria-label="Queue summary">
            <span className="queue-summary__waiting">{groups.waiting.length} waiting</span>
            <i>·</i>
            <span className="queue-summary__running">{groups.running.length} running</span>
            <i>·</i>
            <span>{groups.queued.length} queued</span>
          </div>
          <div className="task-list">
            <section>
              <h3>WAITING ({groups.waiting.length})</h3>
              {groups.waiting.map((task) => (
                <TaskRow key={task.id} task={task} selected={selectedId === task.id} onSelect={onSelect} />
              ))}
            </section>
            <section>
              <h3>RUNNING ({groups.running.length})</h3>
              {groups.running.map((task) => (
                <TaskRow key={task.id} task={task} selected={selectedId === task.id} onSelect={onSelect} />
              ))}
            </section>
            <section>
              <h3>QUEUED ({groups.queued.length})</h3>
              {groups.queued.map((task) => (
                <TaskRow key={task.id} task={task} selected={selectedId === task.id} onSelect={onSelect} />
              ))}
            </section>
          </div>
        </>
      )}
    </aside>
  );
}

function CompletedStep({ number, title, detail }) {
  return (
    <div className="timeline-step timeline-step--complete">
      <MdCheckCircle className="timeline-step__marker" aria-hidden="true" />
      <div className="timeline-step__copy">
        <strong><span>{number}.</span> {title}</strong>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function PendingStep({ number, title, detail }) {
  return (
    <div className="timeline-step timeline-step--pending">
      <span className="timeline-step__pending-marker">{number}</span>
      <div className="timeline-step__copy">
        <strong><span>{number}.</span> {title}</strong>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function BackgroundEvidence({ expanded, onToggle }) {
  const [showAllFiles, setShowAllFiles] = useState(false);
  const [linkedSessionOpen, setLinkedSessionOpen] = useState(false);

  return (
    <section className={`evidence${expanded ? " is-expanded" : ""}`}>
      <button type="button" className="evidence__header" onClick={onToggle} aria-expanded={expanded}>
        <strong>Background &amp; evidence</strong>
        {expanded ? <MdExpandLess /> : <MdExpandMore />}
      </button>
      {expanded ? (
        <div className="evidence__grid">
          <div>
            <h4><MdOutlineInsertDriveFile /> Source files</h4>
            <p>auth/storage.ts</p>
            <p>platform/macos/keychain.ts</p>
            <p>platform/fs/encrypted.ts</p>
            {showAllFiles ? (
              <div className="evidence__more-files">
                <p>auth/token_repository.ts</p>
                <p>auth/migration.ts</p>
                <p>platform/storage_adapter.ts</p>
                <p>test/auth/storage_test.ts</p>
                <p>test/auth/migration_test.ts</p>
                <p>docs/security.md</p>
              </div>
            ) : null}
            <button type="button" className="text-link" onClick={() => setShowAllFiles((value) => !value)}>
              {showAllFiles ? "Show fewer" : "+ 6 more"}
            </button>
          </div>
          <div>
            <h4>Relevant constraints</h4>
            <ul>
              <li>Security baseline: High</li>
              <li>Backwards compatibility required</li>
              <li>Cross-platform parity goal</li>
            </ul>
          </div>
          <div>
            <h4>Proposed next steps</h4>
            <p>Implement chosen storage as default, add migration if needed, update tests.</p>
            <button type="button" className="text-link" onClick={() => setLinkedSessionOpen((value) => !value)}>
              {linkedSessionOpen ? "Hide linked session" : "View linked session"} <MdOpenInNew />
            </button>
            {linkedSessionOpen ? <p className="linked-session">Session auth-storage-review · 42 tests passed</p> : null}
          </div>
        </div>
      ) : null}
    </section>
  );
}

function Checkpoint({ onResume, onKeepPaused, savedNotice, isResuming }) {
  const [choice, setChoice] = useState("keychain");
  const [custom, setCustom] = useState("");
  const [evidenceExpanded, setEvidenceExpanded] = useState(true);
  const answer = custom.trim() || choices.find((item) => item.id === choice)?.title;

  return (
    <section className="checkpoint">
      <div className="checkpoint__heading">
        <span className="active-step-marker">4</span>
        <h3><span>4.</span> Human checkpoint</h3>
        <span className="input-badge">Needs your input</span>
      </div>
      <div className="checkpoint__body">
        <h4>The app supports two token storage strategies. Which should become the default?</h4>
        <div className="checkpoint__context">
          <p><strong>Why this matters:</strong> changing the default affects existing users on their next sign-in.</p>
          <p><strong>Current state:</strong> Keychain is used on macOS, encrypted file storage is the cross-platform fallback.</p>
          <p><strong>Safe to answer now:</strong> no files have been modified.</p>
        </div>
        <fieldset className="answer-list">
          <legend className="sr-only">Choose a token storage strategy</legend>
          {choices.map((item) => (
            <label key={item.id} className={choice === item.id && !custom ? "is-selected" : ""}>
              <input
                type="radio"
                name="answer"
                value={item.id}
                checked={choice === item.id && !custom}
                disabled={isResuming}
                onChange={() => {
                  setChoice(item.id);
                  setCustom("");
                }}
              />
              <span><strong>{item.title}</strong><small>{item.detail}</small></span>
            </label>
          ))}
        </fieldset>
        <label className="custom-answer">
          <span>Write another answer</span>
          <div>
            <input
              value={custom}
              onChange={(event) => setCustom(event.target.value)}
              placeholder="Explain the behavior you want…"
              disabled={isResuming}
            />
            <MdEdit aria-hidden="true" />
          </div>
        </label>
        <div className="checkpoint__actions">
          <button type="button" className={`primary-button${isResuming ? " is-busy" : ""}`} disabled={isResuming} onClick={() => onResume(answer)}>
            {isResuming ? <MdRefresh /> : <MdOutlineSend />}
            {isResuming ? "Resuming automatically…" : "Answer & resume"}
          </button>
          <button type="button" className="secondary-button" disabled={isResuming} onClick={() => onKeepPaused(answer)}>
            <MdBookmarkBorder /> Save answer, keep paused
          </button>
        </div>
        {savedNotice ? <div className="inline-notice" role="status"><MdCheck /> {savedNotice}</div> : null}
        <BackgroundEvidence
          expanded={evidenceExpanded}
          onToggle={() => setEvidenceExpanded((value) => !value)}
        />
      </div>
    </section>
  );
}

function ResumedCheckpoint({ answer }) {
  return (
    <div className="timeline-step timeline-step--complete timeline-step--answer">
      <MdCheckCircle className="timeline-step__marker" aria-hidden="true" />
      <div className="timeline-step__copy">
        <strong><span>4.</span> Human checkpoint</strong>
        <p>Answered: {answer}</p>
      </div>
      <span className="resumed-badge">Resumed automatically</span>
    </div>
  );
}

function TaskDetail({ task, onUpdateTask }) {
  const [evidenceExpanded, setEvidenceExpanded] = useState(true);

  if (!task || task.id !== "auth") {
    return (
      <main className="detail detail--summary">
        <div className="summary-state">
          <MdOutlineBolt />
          <h2>{task?.title ?? "Select a task"}</h2>
          <p>{task?.instructions || (task?.status === "Queued" ? "This task will start automatically when an agent is available." : "The agent is working autonomously on this task.")}</p>
          {task?.progress ? <strong>{task.progress}% complete · {task.phase}</strong> : <strong>Waiting in the automatic queue</strong>}
        </div>
      </main>
    );
  }

  const flowState = task.flowState || (task.group === "running" ? "running" : "paused");
  const answer = task.answer || "";
  const savedNotice = task.savedNotice || "";
  const implementationSummary = answer ? `Applying decision: ${answer}` : "Applying the selected decision";

  const resume = (selectedAnswer) => {
    onUpdateTask(task.id, {
      answer: selectedAnswer,
      savedNotice: "",
      flowState: "resuming",
      status: "Resuming…",
    });
    window.setTimeout(() => {
      onUpdateTask(task.id, {
        flowState: "running",
        group: "running",
        status: "Running",
        phase: "Apply changes",
        progress: 72,
        elapsed: "6m 22s",
      });
    }, 900);
  };

  return (
    <main className="detail">
      <header className="detail-header">
        <span className={`detail-header__icon${flowState === "running" ? " is-running" : ""}${flowState === "resuming" ? " is-resuming" : ""}`}>
          {flowState === "running" ? <MdPlayArrow /> : flowState === "resuming" ? <MdRefresh /> : <MdOutlineHourglassEmpty />}
        </span>
        <div>
          <div className="detail-header__title">
            <h2>Update authentication flow</h2>
            <span className={flowState === "running" ? "running-badge" : flowState === "resuming" ? "resuming-badge" : "paused-badge"}>
              {flowState === "running" ? "Running" : flowState === "resuming" ? "Resuming…" : "Paused for input"}
            </span>
          </div>
          <p className="detail-header__meta">
            <span><MdOutlineFolder /> ianvs-acp</span>
            <span><MdOutlineSmartToy /> Codex Spark</span>
            <span><MdOutlineTimer /> {flowState === "running" ? "6m 22s" : "6m 18s"}</span>
          </p>
        </div>
        <span className="auto-resume"><MdRefresh /> {flowState === "running" ? "Resumed automatically" : flowState === "resuming" ? "Applying your answer…" : "Auto-resumes after answer"}</span>
      </header>

      <div className="timeline">
        <CompletedStep number="1" title="Understand request" detail="Mapped the existing login and token refresh flow" />
        <CompletedStep number="2" title="Inspect implementation" detail="Read 12 files, found 2 auth entry points" />
        <CompletedStep number="3" title="Run verification" detail="42 tests passed" />
        {flowState === "running" ? (
          <>
            <ResumedCheckpoint answer={answer} />
            <div className="timeline-step timeline-step--active-work">
              <span className="active-step-marker">5</span>
              <div className="timeline-step__copy">
                <strong><span>5.</span> Apply changes</strong>
                <p>{implementationSummary}</p>
              </div>
              <span className="working-indicator"><MdRefresh /> Working</span>
            </div>
            <PendingStep number="6" title="Final verification" detail="Pending" />
            <BackgroundEvidence expanded={evidenceExpanded} onToggle={() => setEvidenceExpanded((value) => !value)} />
          </>
        ) : (
          <>
            <Checkpoint
              onResume={resume}
              onKeepPaused={(selectedAnswer) => {
                onUpdateTask(task.id, {
                  answer: selectedAnswer,
                  savedNotice: "Answer saved. The task remains paused.",
                });
              }}
              savedNotice={savedNotice}
              isResuming={flowState === "resuming"}
            />
            <PendingStep number="5" title="Apply changes" detail="Pending" />
            <PendingStep number="6" title="Final verification" detail="Pending" />
          </>
        )}
      </div>
    </main>
  );
}

function NewTaskDialog({ onClose, onCreate }) {
  const [title, setTitle] = useState("");
  const [instructions, setInstructions] = useState("");
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <div
        className="new-task-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-task-title"
        onMouseDown={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            onClose();
            return;
          }
          if (event.key !== "Tab") return;
          const focusable = Array.from(event.currentTarget.querySelectorAll("button:not([disabled]), input:not([disabled]), textarea:not([disabled])"));
          const first = focusable[0];
          const last = focusable[focusable.length - 1];
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last?.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first?.focus();
          }
        }}
      >
        <form
          className="new-task-form"
          onSubmit={(event) => {
            event.preventDefault();
            if (title.trim()) onCreate({ title: title.trim(), instructions: instructions.trim() });
          }}
        >
          <div className="dialog-header">
            <div>
              <span className="dialog-icon"><MdAutoAwesome /></span>
              <div><h2 id="new-task-title">New automatic task</h2><p>It will start as soon as an agent is available.</p></div>
            </div>
            <AppIconButton label="Close dialog" onClick={onClose}><MdClose /></AppIconButton>
          </div>
          <label>Task title<input autoFocus value={title} onChange={(event) => setTitle(event.target.value)} placeholder="What should the agent accomplish?" /></label>
          <label>Instructions<textarea value={instructions} onChange={(event) => setInstructions(event.target.value)} placeholder="Add constraints, context, and a clear definition of done." /></label>
          <div className="dialog-context"><MdOutlineFolder /> ianvs-acp <span>·</span> <MdOutlineSmartToy /> Codex Spark</div>
          <div className="dialog-footer">
            <button type="button" className="secondary-button" onClick={onClose}>Cancel</button>
            <button type="submit" className="primary-button" disabled={!title.trim()}><MdPlayArrow /> Create &amp; run</button>
          </div>
        </form>
      </div>
    </div>
  );
}

export function App() {
  const [tasks, setTasks] = useState(initialTasks);
  const [selectedId, setSelectedId] = useState("auth");
  const [activeTab, setActiveTab] = useState("inbox");
  const [showNewTask, setShowNewTask] = useState(false);
  const selectedTask = tasks.find((task) => task.id === selectedId);

  const updateTask = (id, patch) => {
    setTasks((current) => current.map((task) => (task.id === id ? { ...task, ...patch } : task)));
  };

  const createTask = ({ title, instructions }) => {
    const id = `task-${Date.now()}`;
    const task = {
      id,
      group: "running",
      title,
      status: "Running",
      phase: "Understand request",
      elapsed: "Just now",
      progress: 6,
      instructions,
    };
    setTasks((current) => [current[0], task, ...current.slice(1)]);
    setSelectedId(id);
    setActiveTab("inbox");
    setShowNewTask(false);
  };

  return (
    <div className="prototype-app">
      <div className="native-titlebar" role="region" aria-label="Window title"><span><MdDesktopMac /></span><strong>ACP Client</strong></div>
      <header className="app-toolbar" aria-label="Application toolbar">
        <div className="brand"><span><MdHub /></span><h1>ACP Client</h1></div>
        <div className="toolbar-actions">
          <AppIconButton label="Manage agents"><MdManageAccounts /></AppIconButton>
          <AppIconButton
            label="Run queue"
            onClick={() => {
              const runningTask = tasks.find((task) => task.group === "running");
              if (runningTask) setSelectedId(runningTask.id);
              setActiveTab("inbox");
            }}
          >
            <MdPlayCircleOutline />
          </AppIconButton>
          <AppIconButton label="New task" tone="primary" onClick={() => setShowNewTask(true)}><MdAdd /></AppIconButton>
        </div>
      </header>
      <div className="app-body">
        <Sidebar
          tasks={tasks}
          selectedId={selectedId}
          onSelect={(id) => { setSelectedId(id); setActiveTab("inbox"); }}
          onNewTask={() => setShowNewTask(true)}
          activeTab={activeTab}
          onTab={setActiveTab}
        />
        {activeTab === "inbox" ? <TaskDetail key={selectedId} task={selectedTask} onUpdateTask={updateTask} /> : <main className="detail detail--workspace"><MdFolderOpen /><h2>ianvs-acp</h2><p>7 task sessions · 2 running automatically</p><button className="primary-button" type="button" onClick={() => setActiveTab("inbox")}>Open Inbox</button></main>}
      </div>
      <footer className="statusbar">
        <span className="connected-dot"><i /> connected</span>
        <span><MdOutlineBolt /> idle</span>
        <span><MdOutlineTimer /> low latency ··</span>
        <span># no session</span>
        <span><MdOutlineFolder /> /Users/robinfai</span>
      </footer>
      {showNewTask ? <NewTaskDialog onClose={() => setShowNewTask(false)} onCreate={createTask} /> : null}
    </div>
  );
}
