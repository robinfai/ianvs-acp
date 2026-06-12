create table if not exists memory_items (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  kind text not null,
  scope text not null,
  text text not null,
  source text not null,
  source_session_id text,
  source_turn_id text,
  confidence real,
  status text not null default 'active',
  created_at integer not null,
  updated_at integer not null,
  deleted_at integer
);

create table if not exists memory_candidates (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  kind text not null,
  scope text not null,
  text text not null,
  reason text,
  confidence real,
  transcript_hash text,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);

create table if not exists memory_change_requests (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  action text not null,
  source text not null default 'user',
  target_memory_id text,
  target_memory_ids_json text,
  proposed_kind text,
  proposed_scope text,
  proposed_text text,
  reason text,
  confidence real,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);

create table if not exists memory_audit_log (
  id text primary key,
  actor text not null,
  action text not null,
  memory_id text,
  candidate_id text,
  change_request_id text,
  payload_json text not null,
  created_at integer not null
);

create table if not exists prompt_injections (
  id text primary key,
  session_id text not null,
  turn_id text not null,
  memory_ids_json text not null,
  injected_text_hash text not null,
  created_at integer not null
);

create index if not exists idx_memory_items_scope
on memory_items(user_id, workspace_id, repo_id, agent_id, session_id, kind, status);

create index if not exists idx_memory_candidates_status
on memory_candidates(user_id, workspace_id, repo_id, status, created_at);

create index if not exists idx_memory_change_requests_status
on memory_change_requests(user_id, workspace_id, repo_id, status, created_at);

create table if not exists vector_index_metadata (
  key text primary key,
  value text not null
);
